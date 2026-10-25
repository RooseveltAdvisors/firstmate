#!/usr/bin/env python3
"""fm-jev-guard.py - dynamic delegation guardrail for Firstmate using Jev System One.

Prevents Firstmate and secondmates from falling into hands-on implementation and sysadmin
rabbit holes by intercepting commands, fast-passing legitimate supervisor tasks,
and querying Jev System One on ambiguous or mutating commands.

Deterministic scope contract; every clause is pinned in tests/fm-jev-guard.test.sh:

  fast-path   Supervisor allowlist only: fm-*.sh scripts, bd, tasks-axi, herdr, gh read
              verbs (pr view/status/list/checks/diff, run list/view), git read verbs
              (status/log/diff/rev-parse/show/ls-files/ls-remote), and bash/sh/zsh/dash
              payload forms with leading flags whose own command qualifies on that list.
              Only those four names take the payload fast path; ksh and ash stay
              deny-side. The fast path runs first, so an allowlisted spelling is allowed
              even when its paths lie under projects/ (git read verbs on a project repo).
  not-writes  Bare fd duplication (2>&1) and the literal dev-sink redirect targets
              /dev/null, /dev/stdout, /dev/stderr, /dev/fd/0, /dev/fd/1, /dev/fd/2 are
              not file writes; any other redirect target refuses the fast path.
  pre-deny    A command the fast path does not allow and whose operative paths - cwd, cd
              target, program, file operand, redirect target, find action or file-output
              operand, shell payload, assignment value - lie under projects/ or a
              treehouse worktree is denied require_delegation before any Jev query.
              Payload recursion covers bash, sh, zsh, dash, ksh and ash with leading flags.
  mentions    Pattern and predicate words (grep patterns, find -path/-name without a
              transforming action, echo/printf values, task payloads) are mentions, not
              operands: a mention on an allowlisted tool fast-passes with that tool, and
              every other mention reaches Jev instead of the pre-deny. A project-resolving
              assignment value is not a mention: it refuses the fast path and pre-denies.
  unparsable  Input that cannot be tokenized never fast-passes, and the pre-deny falls
              back to the project-path substring test.
  jev         Jev classifies everything else and project_worker always denies; outages
              admit only SUPERVISOR_ALLOWLIST and fail closed; allowed decisions are
              never cached.

Written amendment - wrapper peeling, deny side only: before the shell-name check, peel
the leading wrapper words nohup, env (including -i and -U forms), timeout, exec, nice,
setsid, xargs, time and command - these nine and only these; any future wrapper word
joins solely by a further written amendment. Peeling consumes each wrapper's own
arguments too: option flags and their values, timeout's duration, and env's -i,
-u, -U and -S forms; nohup carries none, while exec and command carry their flags.
After peeling, the remaining command runs
the existing recursion: the four commissioned shells including leading flags, then the
project-op pre-deny. Rationale: a command operating under projects/ hard-denies BEFORE
ANY QUERY - a deterministic guarantee independent of Jev's answer - and the
pinned-permissive-answer allow of `nohup bash -c 'rm projects/portal/x'` is precisely
the failure that clause exists to stop (a project file deleted while the guard stamps
supervisor approval). Peeling widens the deny side only and never makes anything newly
allowable.

Second written amendment - file-valued wrapper options, deny side only: when peeling
one of the nine wrapper words, a file-valued option's VALUE is an OPERAND - time -o and
time --output, xargs -a and xargs --arg-file - and it routes into operative_paths
exactly like a direct file operand, so it pre-denies when it points under projects/
IN ADDITION TO (never instead of) continuing the peel onward to the shell-payload
check. Consuming an option value may add a deny and may never remove or reroute one.
These four named option pairs are the complete list for this round; any further
file-valued option of the nine joins only by another written amendment. The earlier
consumption machinery exceeded its named mandate by covering file-valued options at
all; this amendment legitimizes and bounds that overreach.

Third written amendment - assignment values, deny side only: a leading NAME=value
assignment whose value resolves under projects/ refuses the fast path and reaches the
pre-deny before any query, the same operative-path rule the pre-deny uses for operands,
over every assignment prefix including env's forms and env -S/--split-string payloads.
An assignment-only segment executes nothing and stays out of the pre-deny; variable and
glob expansions remain unresolved parser input that reaches Jev. Strictly additive:
nothing becomes newly allowable.

The firstmate invariant: anything the deterministic layer does not positively classify for fast-path or pre-deny REACHES JEV and outage keeps fail-closed deny - no third outcome, no spelling may end in a silent allow.

Usage:
  fm-jev-guard.py [--command <cmd>] [--check-only] [--json] [--debug]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path

TS_BASE = os.environ.get("FM_JEV_TS_BASE", "https://api.typesafe.ai")
TS_MODEL = os.environ.get("FM_JEV_TS_MODEL", "jev-latest")
TS_TIMEOUT = float(os.environ.get("FM_JEV_GUARD_TIMEOUT", "3.0"))
DEFAULT_JEV_PROXY = "/opt/ra/infisical/bin/jev-proxy.sh"

CRITERIA_ACTION = {
    "allow_supervisor": (
        "Legitimate supervisory action for Firstmate in workspace w1: draining queues, reading status files, "
        "managing beads/backlog, checking local git status of firstmate, routing or steering workers via fm-send/fm-route."
    ),
    "require_delegation": (
        "Hands-on implementation, debugging, or sysadmin work that must be delegated to a Second Mate or worker: "
        "SSHing to remote hosts (srv-covenant-app, gpu, svc), running package managers (apt, pip, npm), direct service "
        "control (systemctl restart/enable), editing application/project code, building or testing project code (npm test, pytest)."
    ),
}

CRITERIA_DOMAIN = {
    "supervisor": "Benign supervisor action: keep in w1.",
    "gpu_ops": "GPU host operations, Ollama, STT, whisper, models, CUDA, host configs on gpu.",
    "svc_ops": "Service operations, systemd, web server configs, Redis, reverse proxy, portal infrastructure on srv-covenant-app or svc.",
    "project_worker": "Application code changes, git commits/tags to projects, running tests, project builds.",
    "monitor_sre": "Stack monitoring, health checks, uptime alerts.",
    "firstmate_upstream": "Upstream firstmate pull requests and framework changes.",
}

# One allowlist for fast-path supervision and Jev outages. Values constrain verbs.
SUPERVISOR_ALLOWLIST = {
    r"fm-[A-Za-z0-9_-]+\.sh": None,
    r"bd": None,
    r"tasks-axi": None,
    r"herdr": None,
    r"gh(?:-axi)?": {"pr view", "pr status", "pr list", "pr checks", "pr diff", "run list", "run view"},
    r"git": {"status", "log", "diff", "rev-parse", "show", "ls-files", "ls-remote"},
}

# Exact literal tokens only: these discard or duplicate standard streams rather
# than write a file. No /dev/fd/N for N>=3: an inherited fd may be a real file.
DEV_SINKS = {"/dev/null", "/dev/stdout", "/dev/stderr", "/dev/fd/0", "/dev/fd/1", "/dev/fd/2"}


def get_jev_proxy() -> Path | None:
    """Resolve the executable Infisical JEV proxy wrapper."""
    raw = os.environ.get("FM_JEV_PROXY_BIN", DEFAULT_JEV_PROXY).strip()
    if not raw:
        return None
    proxy = Path(raw)
    if proxy.is_file() and os.access(proxy, os.X_OK):
        return proxy
    return None


def post_jev_systemone(payload: dict, proxy_bin: Path | None = None) -> dict:
    """POST a System One request through the Infisical JEV proxy."""
    proxy = proxy_bin or get_jev_proxy()
    if not proxy:
        raise RuntimeError("Infisical JEV proxy unavailable")
    url = f"{TS_BASE.rstrip('/')}/v1/systemone"
    res = subprocess.run(
        [
            str(proxy),
            "-fsS",
            "--max-time",
            str(TS_TIMEOUT),
            "-X",
            "POST",
            url,
            "-H",
            "Content-Type: application/json",
            "--data-binary",
            "@-",
        ],
        input=json.dumps(payload).encode("utf-8"),
        capture_output=True,
        timeout=TS_TIMEOUT,
        check=False,
    )
    if res.returncode != 0:
        err = res.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"JEV proxy exited {res.returncode}: {err or 'request failed'}")
    data = json.loads(res.stdout.decode("utf-8"))
    if not isinstance(data, dict):
        raise RuntimeError("Malformed JEV response")
    return data


SHELL_NAMES = {"bash", "sh", "zsh", "dash", "ksh", "ash"}
FAST_PATH_SHELLS = {"bash", "sh", "zsh", "dash"}
SHELL_VALUE_OPTS = {"-o", "+o", "-O", "+O", "--rcfile", "--init-file"}
WRAPPER_WORDS = {"nohup", "env", "timeout", "exec", "nice", "setsid", "xargs", "time", "command"}
WRAPPER_FILE_OPTS = {
    "time": {"-o", "--output"},
    "xargs": {"-a", "--arg-file"},
}


def peel_wrappers(args: list[str]) -> tuple[list[str], list[str], list[str]]:
    """Strip leading wrapper words and their arguments.

    Returns the remaining args, the paths the peel consumed (wrapper programs and
    file-option values), and command payloads carried by env -S.
    """
    collected: list[str] = []
    payloads: list[str] = []
    while args and Path(args[0]).name in WRAPPER_WORDS:
        wrapper = Path(args[0]).name
        collected.append(args[0])
        args = args[1:]
        if wrapper == "nohup":
            continue
        if wrapper == "env":
            env_values: list[str] = []
            while args:
                if args[0] in ("-i", "--"):
                    args = args[1:]
                elif re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", args[0]):
                    env_values.append(args[0].split("=", 1)[1])
                    args = args[1:]
                elif args[0] in ("-u", "-U", "--unset") and len(args) > 1:
                    args = args[2:]
                elif args[0].startswith(("-u", "-U", "--unset=")):
                    args = args[1:]
                elif args[0] in ("-S", "--split-string") and len(args) > 1:
                    payloads.append(args[1])
                    args = args[2:]
                elif args[0].startswith("--split-string="):
                    payloads.append(args[0].split("=", 1)[1])
                    args = args[1:]
                else:
                    break
            if args or payloads:
                collected.extend(env_values)
            continue
        file_opts = WRAPPER_FILE_OPTS.get(wrapper, set())
        while args and args[0].startswith("-"):
            flag = args[0]
            name, sep, attached = flag.partition("=")
            if name in file_opts and sep:
                collected.append(attached)
                args = args[1:]
            elif len(flag) > 2 and not flag.startswith("--") and flag[:2] in file_opts:
                collected.append(flag[2:])
                args = args[1:]
            elif flag in file_opts and len(args) > 1:
                collected.append(args[1])
                args = args[2:]
            elif sep:
                args = args[1:]
            elif (len(args) > 1 and Path(args[1]).name not in WRAPPER_WORDS | SHELL_NAMES
                  and not PROJECT_PATH_RE.search(args[1])):
                args = args[2:]
            else:
                args = args[1:]
        if wrapper == "timeout" and len(args) > 1 and Path(args[1]).name in WRAPPER_WORDS | SHELL_NAMES:
            args = args[1:]
    return args, collected, payloads


def shell_payload(args: list[str], shells: set[str] = SHELL_NAMES) -> str | None:
    """The -c command string of a shell invocation, or None when args name a script file."""
    if not args or Path(args[0]).name not in shells:
        return None
    argv: list[str] = []
    skip = False
    for a in args:
        if skip:
            skip = False
        elif a and all(char in "<&>|" for char in a):
            skip = True
        elif not a.isdigit():
            argv.append(a)
    command = False
    i = 1
    while i < len(argv):
        a = argv[i]
        if a in SHELL_VALUE_OPTS:
            i += 2
        elif a.startswith("--"):
            if a == "--":
                return None
            i += 1
        elif a[:1] in ("-", "+") and len(a) > 1:
            if "c" in a[1:]:
                command = True
            i += 2 if a[-1] in ("o", "O") else 1
        elif command:
            return a
        else:
            return None
    return None


def is_whitelisted_command(cmd: str) -> bool:
    """Admit supervisor tools with opaque task payloads, refusing shell-substitution tokens."""
    try:
        cmd = cmd.strip()
        if cmd.startswith("(") and cmd.endswith(")"):
            return is_whitelisted_command(cmd[1:-1])
        lexer = shlex.shlex(cmd, posix=True, punctuation_chars=";&|<>\n")
        lexer.whitespace = " \t\r"
        lexer.whitespace_split = True
        lexer.commenters = ""
        parts: list[list[str]] = [[]]
        for token in lexer:
            if "$(" in token or "`" in token:
                return False
            if token and all(char in ";&|\n" for char in token):
                parts.append([])
            else:
                parts[-1].append(token)
        for args in parts:
            args, assigned = strip_assignments(args)
            if any(resolves_under_projects(value) for value in assigned):
                return False
            if not args:
                continue
            if args[0] == "env":
                args = args[1:]
                args, assigned = strip_assignments(args)
                if any(resolves_under_projects(value) for value in assigned):
                    return False
            if not args:
                return False
            # Do not let a tool fast-pass shell substitutions or file writes.
            for i, arg in enumerate(args):
                if not arg or any(char not in "<&>|" for char in arg):
                    continue
                target = args[i + 1] if i + 1 < len(args) else ""
                if arg in (">&", "<&") and target.isdigit():
                    continue
                if target in DEV_SINKS:
                    continue
                return False
            payload = shell_payload(args, FAST_PATH_SHELLS)
            if payload is not None:
                if not is_whitelisted_command(payload):
                    return False
                continue
            if Path(args[0]).name in FAST_PATH_SHELLS:
                args = args[1:]
            if not args:
                return False
            # Navigation only sets context; every following operation is checked.
            if args[0] == "cd" and len(args) <= 2:
                continue
            tool = Path(args[0]).name
            match = next((verbs for pattern, verbs in SUPERVISOR_ALLOWLIST.items()
                          if re.fullmatch(pattern, tool)), False)
            if match is False:
                return False
            if match is not None:
                rest = args[1:]
                while rest:
                    if rest[0] in ("-C", "--git-dir", "--work-tree") and len(rest) > 1:
                        rest = rest[2:]
                    elif rest[0] in ("--no-pager", "--no-optional-locks") or rest[0].startswith(("--git-dir=", "--work-tree=")):
                        rest = rest[1:]
                    else:
                        break
                verbs = {tuple(verb.split()) for verb in match}
                if not any(tuple(rest[:len(verb)]) == verb for verb in verbs):
                    return False
                if any(arg.startswith("--output") for arg in rest):
                    return False
        return True
    except ValueError as exc:
        print(f"Jev guard: cannot parse command: {exc}", file=sys.stderr)
        return False


def delegation_denial(reason: str, domain: str = "project_worker") -> dict:
    return {
        "decision": "deny",
        "code": "require_delegation",
        "reason": reason,
        "target_domain": domain,
        "suggested_command": get_suggested_dispatch("", domain),
    }


PROJECT_PATH_RE = re.compile(r"(?:^|[/\s=])projects(?:/|$)|(?:^|/)\.treehouse/")

# These tools open no file operand: their words are patterns or values, so a
# project path named there is a mention, not an operation on it.
NO_FILE_OPERAND_TOOLS = {"pgrep", "pkill", "echo", "printf"}
# These tools name a pattern or program first; the words after it are files.
PATTERN_FIRST_TOOLS = {"grep", "egrep", "fgrep", "rg", "ag", "ack", "awk", "sed"}
# find primaries that execute or transform what they match.
FIND_ACTIONS = ("-delete", "-exec", "-execdir", "-ok", "-okdir")


def is_file_operand(operand: str) -> bool:
    if not re.search(r"\s", operand):
        return True
    ancestor = Path(operand).expanduser()
    while not ancestor.exists() and ancestor != ancestor.parent:
        ancestor = ancestor.parent
    return bool(PROJECT_PATH_RE.search(str(ancestor)))


def strip_assignments(args: list[str]) -> tuple[list[str], list[str]]:
    values: list[str] = []
    while args and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", args[0]):
        values.append(args[0].split("=", 1)[1])
        args = args[1:]
    return args, values


def resolves_under_projects(value: str) -> bool:
    return is_file_operand(value) and bool(PROJECT_PATH_RE.search(value))


def operative_paths(cmd: str) -> list[str] | None:
    """The paths a command operates on: its program, cd targets, file operands,
    and redirection targets, recursing into bash -c strings.

    Returns None when the command cannot be parsed. Operative paths count even
    when they do not exist yet; a word that merely mentions a path (match
    pattern, task payload) is left out.
    """
    try:
        lexer = shlex.shlex(cmd, posix=True, punctuation_chars=";&|<>()\n")
        lexer.whitespace = " \t\r"
        lexer.whitespace_split = True
        lexer.commenters = ""
        segments: list[list[str]] = [[]]
        for token in lexer:
            if not token:
                continue
            if all(char in ";&|()\n" for char in token):
                segments.append([])
            else:
                segments[-1].append(token)
    except ValueError:
        return None
    merged: list[list[str]] = []
    for segment in segments:
        if not segment:
            continue
        if segment[0].startswith("-") and merged:
            merged[-1].extend(segment)
        else:
            merged.append(segment)
    paths: list[str] = []
    for args in merged:
        args, assigned = strip_assignments(args)
        args, peeled, carried = peel_wrappers(args)
        args, more_assigned = strip_assignments(args)
        assigned += more_assigned
        if args:
            paths.extend(value for value in assigned if is_file_operand(value))
        paths.extend(operand for operand in peeled if is_file_operand(operand))
        for command in carried:
            nested = operative_paths(command)
            if nested is None:
                return None
            paths.extend(nested)
        if not args:
            continue
        tool = Path(args[0]).name
        pattern_tool = tool in PATTERN_FIRST_TOOLS
        redirects: list[str] = []
        roots: list[str] = []
        words: list[str] = []
        values: list[str] = []
        pending = False
        expression = False
        take = ""
        pattern_source = False
        for a in args[1:]:
            if all(char in "<&>|" for char in a):
                pending = True
            elif pending:
                pending = False
                redirects.append(a)
            elif take:
                if take == "file":
                    values.append(a)
                take = ""
            elif a.startswith("-"):
                if a not in ("-H", "-L", "-P"):
                    expression = True
                if pattern_tool:
                    if a in ("-e", "--regexp"):
                        take, pattern_source = "pattern", True
                    elif a in ("-f", "--file"):
                        take, pattern_source = "file", True
                    elif a.startswith("--file="):
                        values.append(a.split("=", 1)[1])
                        pattern_source = True
                    elif a.startswith(("-e", "-f", "--regexp")):
                        pattern_source = True
                        if re.fullmatch(r"-f.+", a):
                            values.append(a[2:])
                elif tool == "find" and a in ("-fls", "-fprintf", "-fprint", "-fprint0"):
                    take = "file"
                elif "=" in a:
                    values.append(a.split("=", 1)[1])
                elif re.fullmatch(r"-[A-Za-z].+", a):
                    values.append(a[2:])
            else:
                words.append(a)
                if not expression:
                    roots.append(a)
        paths.extend(redirects)
        payload = shell_payload(args)
        if payload is not None:
            nested = operative_paths(payload)
            if nested is None:
                return None
            paths.extend(nested)
        if tool in ("cd", "pushd"):
            if words:
                paths.append(words[0])
            continue
        paths.append(args[0])
        if tool in NO_FILE_OPERAND_TOOLS:
            continue
        if tool == "find":
            for index, action in enumerate(args):
                if action not in FIND_ACTIONS:
                    continue
                executed = shell_payload(peel_wrappers(args[index + 1:])[0])
                if executed is not None:
                    nested = operative_paths(executed)
                    if nested is None:
                        return None
                    paths.extend(nested)
            words = words if any(a in FIND_ACTIONS for a in args) else roots
        elif pattern_tool and not pattern_source:
            words = words[1:]
        for operand in values + words:
            if is_file_operand(operand):
                paths.append(operand)
    return paths


def targets_project(cmd: str) -> bool:
    # The cwd counts too: a plain pytest inside a project carries no path in argv.
    if PROJECT_PATH_RE.search(str(Path.cwd().resolve())):
        return True
    paths = operative_paths(cmd)
    if paths is None:
        return bool(PROJECT_PATH_RE.search(cmd))
    return any(PROJECT_PATH_RE.search(path) for path in paths)


def get_suggested_dispatch(cmd: str, domain: str) -> str:
    if domain == "gpu_ops":
        return "bin/fm-send.sh gpu-ops '<task instructions>'"
    elif domain == "svc_ops":
        return "bin/fm-send.sh svc-ops '<task instructions>'"
    elif domain == "monitor_sre":
        return "bin/fm-send.sh monitor-sre '<task instructions>'"
    elif domain == "firstmate_upstream":
        return "bin/fm-send.sh 2ndmate-firstmate-upstream '<task instructions>'"
    else:
        return "bin/fm-route-dispatch.sh --task '<task instructions>'"


def query_jev_guard(cmd: str, proxy_bin: Path | None = None) -> dict:
    clean_cmd = " ".join(cmd.split())[:800]
    payload = {
        "model": TS_MODEL,
        "state": {
            "role": "firstmate_primary_supervisor_w1",
            "command": clean_cmd,
            "policy": (
                "Firstmate is the executive primary supervisor in workspace w1. "
                "Firstmate's duty is delegating tasks, steering Second Mates, managing beads, "
                "and triage. Direct hands-on sysadmin (SSHing to remote hosts like srv-covenant-app "
                "or gpu, service restarts, editing systemd configs, apt/pip installs) and application "
                "code changes/testing must be delegated to Second Mates."
            ),
        },
        "questions": {
            "action": {
                "type": "choice",
                "instructions": "Should Firstmate be allowed to execute this command in w1, or does it violate supervisor boundaries and require delegation to a Second Mate?",
                "criteria": CRITERIA_ACTION,
            },
            "violation_noul": {
                "type": "noul",
                "instructions": "Probability (0.0 to 1.0) that this command violates supervisor boundaries in w1 and is hands-on work that should be delegated.",
            },
            "target_domain": {
                "type": "choice",
                "instructions": "If this command requires delegation, which domain / Second Mate seat should own it?",
                "criteria": CRITERIA_DOMAIN,
            },
        },
    }

    data = post_jev_systemone(payload, proxy_bin)

    answers = data.get("answers", {})
    action = answers.get("action", {}).get("choice", "require_delegation")
    violation_noul = float(answers.get("violation_noul", {}).get("noul", 1.0))
    target_domain = answers.get("target_domain", {}).get("choice", "project_worker")

    is_deny = (target_domain == "project_worker") or (action == "require_delegation") or (violation_noul >= 0.70)
    suggested = get_suggested_dispatch(cmd, target_domain)

    if is_deny:
        reason = (
            f"Command violates supervisor boundary in w1 ({target_domain}). "
            f"Hands-on execution must be delegated to Second Mates."
        )
        return {
            "decision": "deny",
            "code": "require_delegation",
            "reason": reason,
            "target_domain": target_domain,
            "violation_noul": violation_noul,
            "suggested_command": suggested,
        }
    else:
        return {
            "decision": "allow",
            "code": "supervisor_approved",
            "reason": "Command within supervisor boundary",
            "target_domain": target_domain,
            "violation_noul": violation_noul,
            "suggested_command": "",
        }


def stamp_guard_telemetry(cmd: str, result: dict, fm_root: Path | None = None) -> None:
    try:
        root = fm_root or Path("/opt/ra/firstmate")
        state_dir = root / "state"
        state_dir.mkdir(parents=True, exist_ok=True)
        telemetry_file = state_dir / ".jev-guard-telemetry"
        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        decision = result.get("decision", "allow")
        tier = result.get("tier", 1)
        domain = result.get("target_domain", "-")
        code = result.get("code", "-")
        clean_cmd = " ".join(cmd.split())[:160]
        line = f"{ts}\t{decision}\ttier{tier}\t{code}\t{domain}\t{clean_cmd}\n"
        with open(telemetry_file, "a", encoding="utf-8") as f:
            f.write(line)
    except Exception as exc:
        print(f"Jev guard: telemetry write failed: {exc}", file=sys.stderr)


def _evaluate_command_inner(cmd: str, fm_root: Path | None = None) -> dict:
    cmd_clean = cmd.strip()
    if not cmd_clean:
        return {"decision": "allow", "code": "empty_cmd", "reason": "empty command"}

    # Tier 1: Fast-path whitelist
    if is_whitelisted_command(cmd_clean):
        return {
            "decision": "allow",
            "code": "fast_path_whitelist",
            "reason": "Approved supervisor tool or benign inspection",
            "tier": 1,
        }

    if targets_project(cmd_clean):
        return delegation_denial("Project work must be delegated to a crewmate")

    proxy_bin = get_jev_proxy()
    if not proxy_bin:
        return delegation_denial("Jev unavailable; only supervisor allowlist commands may run")

    try:
        res = query_jev_guard(cmd_clean, proxy_bin)
        res["tier"] = 3
        return res
    except Exception as exc:
        print(f"Jev guard: query failed: {exc}", file=sys.stderr)
        return delegation_denial(f"Jev unavailable ({exc}); only supervisor allowlist commands may run")


def evaluate_command(cmd: str, fm_root: Path | None = None) -> dict:
    res = _evaluate_command_inner(cmd, fm_root)
    stamp_guard_telemetry(cmd, res, fm_root)
    return res


def main() -> int:
    parser = argparse.ArgumentParser(description="Jev dynamic delegation guardrail for Firstmate")
    parser.add_argument("--command", "-c", help="Command string to evaluate")
    parser.add_argument("--check-only", action="store_true", help="Print tab-separated decision and exit")
    parser.add_argument("--json", action="store_true", help="Output full decision as JSON")
    parser.add_argument("--debug", action="store_true", help="Print debug information to stderr")
    args = parser.parse_args()

    cmd = args.command
    if not cmd:
        # Try stdin
        if not sys.stdin.isatty():
            payload_str = sys.stdin.read().strip()
            if payload_str:
                try:
                    p = json.loads(payload_str)
                    cmd = (
                        p.get("toolInput", {}).get("command")
                        or p.get("tool_input", {}).get("command")
                        or payload_str
                    )
                except Exception:
                    cmd = payload_str

    if not cmd:
        # Nothing to evaluate -> allow
        return 0

    script_dir = Path(__file__).resolve().parent
    fm_root = Path(os.environ.get("FM_ROOT_OVERRIDE", script_dir.parent))

    result = evaluate_command(cmd, fm_root)

    if args.json:
        print(json.dumps(result, indent=2))
    elif args.check_only:
        decision = result.get("decision", "allow")
        code = result.get("code", "")
        reason = result.get("reason", "")
        domain = result.get("target_domain", "")
        suggested = result.get("suggested_command", "")
        print(f"{decision}\t{code}\t{reason}\t{domain}\t{suggested}")
    else:
        # Default behavior: exit code 0 for allow, 2 for deny
        if result.get("decision") == "deny":
            code = result.get("code", "require_delegation")
            reason = result.get("reason", "")
            suggested = result.get("suggested_command", "")
            sys.stderr.write(f"[{code}] {reason}\n")
            if suggested:
                sys.stderr.write(f"-> Suggested: {suggested}\n")
            return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
