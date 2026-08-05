#!/usr/bin/env node
// Authoritative forge adapter for the PR review-conversation readiness gate.
//
// GitHub review threads are read through the GraphQL connection because the
// REST API does not expose thread resolution.
// The query requests every page through gh and validates the page sequence,
// total count, and every isResolved value before deciding readiness.
//
// GitLab merge request discussions are read through the paginated Discussions
// REST API because each note exposes resolvable and resolved booleans.
// glab combines every requested page into one JSON array, which is validated in
// full before any discussion is classified.
//
// A zero exit means the complete response proves zero unresolved review
// conversations.
// Any unresolved conversation, CLI/API failure, unsupported provider, malformed
// response, or pagination ambiguity exits nonzero with an actionable diagnostic.
//
// Usage:
//   fm-pr-review-conversations.mjs <github|gitlab> <host> <project-path> <number>

// This command is read-only and never resolves or otherwise changes a thread.

import { spawnSync } from "node:child_process";

const MAX_OUTPUT_BYTES = 32 * 1024 * 1024;
const QUERY_TIMEOUT_MS = 60_000;

function fail(message) {
  process.stderr.write(`error: ${message}\n`);
  process.exit(1);
}

function usage() {
  process.stdout.write(
    "Usage: fm-pr-review-conversations.mjs <github|gitlab> <host> <project-path> <number>\n",
  );
}

function plainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function commandOutput(command, args, label) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    env: { ...process.env, GH_PAGER: "cat", GLAB_PAGER: "cat" },
    maxBuffer: MAX_OUTPUT_BYTES,
    timeout: QUERY_TIMEOUT_MS,
  });
  if (result.error) {
    const reason = result.error.code === "ETIMEDOUT" ? "timed out" : result.error.message;
    fail(`${label} review conversation query failed: ${reason}`);
  }
  if (result.signal) fail(`${label} review conversation query failed: terminated by ${result.signal}`);
  if (result.status !== 0) {
    const detail = (result.stderr || "").trim().replace(/\s+/g, " ").slice(0, 500);
    fail(`${label} review conversation query failed${detail ? `: ${detail}` : ""}`);
  }
  return result.stdout;
}

function parseJson(raw, label) {
  try {
    return JSON.parse(raw);
  } catch {
    fail(`malformed ${label} review conversation response; expected valid JSON`);
  }
}

function githubUnresolved(owner, repo, number) {
  const query = `
query($owner: String!, $repo: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $endCursor) {
        totalCount
        nodes { id isResolved }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}`;
  const raw = commandOutput(
    "gh",
    [
      "api",
      "graphql",
      "--paginate",
      "--slurp",
      "-F",
      `owner=${owner}`,
      "-F",
      `repo=${repo}`,
      "-F",
      `number=${number}`,
      "-f",
      `query=${query}`,
    ],
    "GitHub",
  );
  const pages = parseJson(raw, "GitHub");
  if (!Array.isArray(pages) || pages.length === 0) {
    fail("malformed GitHub review conversation response; no GraphQL pages were returned");
  }

  let totalCount = null;
  let observedCount = 0;
  let unresolvedCount = 0;
  const cursors = new Set();
  const threadIds = new Set();
  let previousEndCursor = null;
  pages.forEach((page, pageIndex) => {
    if (!plainObject(page) || ("errors" in page && (!Array.isArray(page.errors) || page.errors.length > 0))) {
      fail("GitHub review conversation query returned API errors; verify PR access and GraphQL permissions");
    }
    const threads = page.data?.repository?.pullRequest?.reviewThreads;
    if (!plainObject(threads) || !Number.isSafeInteger(threads.totalCount) || threads.totalCount < 0
      || !Array.isArray(threads.nodes) || !plainObject(threads.pageInfo)
      || typeof threads.pageInfo.hasNextPage !== "boolean") {
      fail("malformed GitHub review conversation response; verify PR access and GraphQL permissions");
    }
    if (totalCount === null) totalCount = threads.totalCount;
    if (threads.totalCount !== totalCount) {
      fail("ambiguous GitHub review conversation pagination; totalCount changed between pages");
    }

    const isLast = pageIndex === pages.length - 1;
    const { hasNextPage, endCursor } = threads.pageInfo;
    if ((!isLast && !hasNextPage) || (isLast && hasNextPage)) {
      fail("ambiguous GitHub review conversation pagination; the returned page sequence was incomplete");
    }
    if (hasNextPage) {
      if (typeof endCursor !== "string" || endCursor.length === 0 || cursors.has(endCursor)) {
        fail("ambiguous GitHub review conversation pagination; the next-page cursor was invalid");
      }
    } else if (endCursor !== null && typeof endCursor !== "string") {
      fail("malformed GitHub review conversation response; endCursor had an unsupported value");
    }
    if (typeof endCursor === "string") {
      if (cursors.has(endCursor) || (previousEndCursor !== null && endCursor === previousEndCursor)) {
        fail("ambiguous GitHub review conversation pagination; the cursor did not advance");
      }
      cursors.add(endCursor);
      previousEndCursor = endCursor;
    }

    threads.nodes.forEach((thread) => {
      if (!plainObject(thread) || typeof thread.id !== "string" || thread.id.length === 0
        || typeof thread.isResolved !== "boolean") {
        fail("malformed GitHub review conversation response; id or isResolved was missing or unsupported");
      }
      if (threadIds.has(thread.id)) {
        fail("ambiguous GitHub review conversation pagination; a thread was returned more than once");
      }
      threadIds.add(thread.id);
      observedCount += 1;
      if (!thread.isResolved) unresolvedCount += 1;
    });
  });
  if (observedCount !== totalCount) {
    fail("ambiguous GitHub review conversation pagination; observed threads did not match totalCount");
  }
  return unresolvedCount;
}

function gitlabPages(raw) {
  const chunks = raw.trimStart().split(/\r?\n(?=HTTP\/)/);
  if (chunks.length === 0 || chunks.some((chunk) => !chunk.trim())) {
    fail("malformed GitLab review conversation response; paginated HTTP responses were incomplete");
  }
  const pages = chunks.map((chunk) => {
    const separator = chunk.search(/\r?\n\r?\n/);
    if (separator < 0) {
      fail("ambiguous GitLab review conversation pagination; response headers were missing");
    }
    const headerText = chunk.slice(0, separator);
    const body = chunk.slice(separator).replace(/^\r?\n\r?\n/, "").trim();
    const status = headerText.match(/^HTTP\/\S+\s+(\d{3})/);
    if (!status || !/^2\d\d$/.test(status[1])) {
      fail("GitLab review conversation query returned an API or permission error; verify MR access");
    }
    const headers = new Map();
    headerText.split(/\r?\n/).slice(1).forEach((line) => {
      const match = line.match(/^([^:]+):\s*(.*)$/);
      if (match) headers.set(match[1].toLowerCase(), match[2].trim());
    });
    const page = headers.get("x-page");
    const nextPage = headers.get("x-next-page");
    const totalPages = headers.get("x-total-pages");
    if (!/^\d+$/.test(page || "") || !/^\d+$/.test(totalPages || "")
      || (nextPage !== "" && !/^\d+$/.test(nextPage || ""))) {
      fail("ambiguous GitLab review conversation pagination; pagination headers were missing or invalid");
    }
    const discussions = parseJson(body, "GitLab");
    if (!Array.isArray(discussions)) {
      fail("malformed GitLab review conversation response; expected one array per paginated response");
    }
    return { page: Number(page), nextPage: nextPage === "" ? null : Number(nextPage), totalPages: Number(totalPages), discussions };
  });
  const totalPages = pages[0].totalPages;
  if (totalPages < 1 || pages.some((entry, index) => entry.totalPages !== totalPages
    || entry.page !== index + 1 || entry.page > totalPages
    || (index + 1 < pages.length && entry.nextPage !== entry.page + 1)
    || (index + 1 === pages.length && entry.nextPage !== null))) {
    fail("ambiguous GitLab review conversation pagination; page sequence was incomplete");
  }
  if (pages.length !== totalPages) {
    fail("ambiguous GitLab review conversation pagination; not every page was returned");
  }
  return pages.flatMap((entry) => entry.discussions);
}

function gitlabUnresolved(host, projectPath, number) {
  const encodedProject = encodeURIComponent(projectPath);
  const endpoint = `projects/${encodedProject}/merge_requests/${number}/discussions?per_page=100`;
  const raw = commandOutput(
    "glab",
    ["api", endpoint, "--hostname", host, "--paginate", "--include", "--output", "json"],
    "GitLab",
  );
  const discussions = gitlabPages(raw);

  let unresolvedCount = 0;
  const discussionIds = new Set();
  discussions.forEach((discussion) => {
    if (!plainObject(discussion) || typeof discussion.id !== "string" || discussion.id.length === 0
      || typeof discussion.individual_note !== "boolean" || !Array.isArray(discussion.notes)
      || discussion.notes.length === 0) {
      fail("malformed GitLab review conversation response; a discussion had an unsupported shape");
    }
    if (discussionIds.has(discussion.id)) {
      fail("ambiguous GitLab review conversation pagination; a discussion was returned more than once");
    }
    discussionIds.add(discussion.id);

    let unresolved = false;
    discussion.notes.forEach((note) => {
      if (!plainObject(note) || typeof note.resolvable !== "boolean" || typeof note.resolved !== "boolean"
        || (!note.resolvable && note.resolved)) {
        fail("malformed GitLab review conversation response; resolution fields were missing or unsupported");
      }
      if (note.resolvable && !note.resolved) unresolved = true;
    });
    if (unresolved) unresolvedCount += 1;
  });
  return unresolvedCount;
}

function githubIdentityValid(host, projectPath) {
  if (host !== "github.com") return false;
  const parts = projectPath.split("/");
  if (parts.length !== 2) return false;
  const [owner, repo] = parts;
  return /^(?:[A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]{0,37}[A-Za-z0-9])$/.test(owner)
    && !owner.includes("--")
    && /^[A-Za-z0-9._-]{1,100}$/.test(repo)
    && repo !== "."
    && repo !== "..";
}

function gitlabIdentityValid(host, projectPath) {
  if (host === "github.com" || host.length < 1 || host.length > 253
    || !/^[a-z0-9.-]+$/.test(host) || host.startsWith(".") || host.endsWith(".")
    || host.includes("..")) return false;
  const labels = host.split(".");
  if (labels.some((label) => label.length < 1 || label.length > 63
    || label.startsWith("-") || label.endsWith("-"))) return false;
  const parts = projectPath.split("/");
  return projectPath.length >= 3 && projectPath.length <= 1024
    && parts.length >= 2 && parts.length <= 20
    && parts.every((part) => part.length >= 1 && part.length <= 255
      && /^[A-Za-z0-9._-]+$/.test(part) && !part.startsWith("-")
      && part !== "." && part !== ".." && !part.endsWith(".git") && !part.endsWith(".atom"));
}

if (process.argv.length === 3 && ["--help", "-h"].includes(process.argv[2])) {
  usage();
  process.exit(0);
}
if (process.argv.length !== 6) fail("invalid review conversation check request");
const [provider, host, projectPath, number] = process.argv.slice(2);
if (!/^[1-9][0-9]*$/.test(number)) fail("invalid review conversation check request");

let unresolvedCount;
if (provider === "github" && githubIdentityValid(host, projectPath)) {
  const [owner, repo] = projectPath.split("/");
  unresolvedCount = githubUnresolved(owner, repo, number);
} else if (provider === "gitlab" && gitlabIdentityValid(host, projectPath)) {
  unresolvedCount = gitlabUnresolved(host, projectPath, number);
} else {
  fail("invalid or unsupported review conversation check request");
}

if (unresolvedCount > 0) {
  const noun = unresolvedCount === 1 ? "conversation" : "conversations";
  fail(`${unresolvedCount} unresolved review ${noun}; resolve every thread before readiness or merge`);
}
