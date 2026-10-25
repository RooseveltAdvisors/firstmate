#!/usr/bin/env python3
"""fm-jev-guard.py - dynamic delegation guardrail for Firstmate using Jev System One.

Prevents Firstmate and secondmates from falling into hands-on implementation and sysadmin
rabbit holes by intercepting commands, fast-passing legitimate supervisor tasks,
and querying Jev System One on ambiguous or mutating commands.

Project paths and project_worker classifications require delegation.
Jev outages admit only SUPERVISOR_ALLOWLIST; allowed decisions are never cached.

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


def is_whitelisted_command(cmd: str) -> bool:
    """Admit supervisor tools without inspecting their quoted task payloads."""
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
            while args and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", args[0]):
                args = args[1:]
            if not args:
                continue
            if args[0] == "env":
                args = args[1:]
                while args and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", args[0]):
                    args = args[1:]
            if not args:
                return False
            if Path(args[0]).name in ("bash", "sh"):
                args = args[1:]
                if len(args) == 2 and args[0] in ("-c", "-lc"):
                    if not is_whitelisted_command(args[1]):
                        return False
                    continue
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
            # Do not let a tool fast-pass shell substitutions or file writes.
            for i, arg in enumerate(args):
                if not arg or any(char not in "<>&|" for char in arg):
                    continue
                if arg in (">&", "<&") and i + 1 < len(args) and args[i + 1].isdigit():
                    continue
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


def targets_project(cmd: str) -> bool:
    # Resolve cwd too: a plain pytest inside a project carries no path in argv.
    paths = str(Path.cwd().resolve()) + " " + cmd
    return bool(re.search(r"(?:^|[/\s=])projects(?:/|$)|(?:^|/)\.treehouse/", paths))


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
