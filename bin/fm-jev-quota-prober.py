#!/usr/bin/env python3
"""
fm-jev-quota-prober.py - Jev System One Pre-Flight Quota & Token Health Prober.

Performs sub-second runway and credential probes before worker launch to prevent
429 quota exhaustion and revoked-token stalls. For a doomed lane it recommends,
and with --auto-divert emits, only a permitted lane with confirmed runway; the
caller decides whether to launch that recommendation.

Usage:
  bin/fm-jev-quota-prober.py --harness <harness> [--model <model>] [--auto-divert] [--json]
  bin/fm-jev-quota-prober.py --check-all [--json]
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

DEFAULT_SAFE_HARNESS = "cursor"
DEFAULT_SAFE_MODEL = "composer-2.5"


def query_quota_axi(providers: list[str] | None = None) -> dict:
    """Fetch structured quota evidence from quota-axi in sub-second time."""
    quota_axi_bin = shutil.which("quota-axi")
    if not quota_axi_bin:
        return {}

    cmd = [quota_axi_bin, "--json"]
    if providers:
        cmd.extend(["--provider", ",".join(providers)])

    try:
        res = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        )
        if res.returncode == 0:
            return json.loads(res.stdout)
    except Exception:
        pass
    return {}


def is_zai_bundle_dry() -> bool:
    """Check if the zai-general API bundle carries the explicit dry spend marker."""
    fm_root = Path(os.environ.get("FM_HOME") or Path(__file__).resolve().parent.parent)
    return (fm_root / "state" / ".zai-bundle-dry").exists()


def applicable_availability(provider: dict, model: str) -> list[dict]:
    bare_model = model.rsplit("/", 1)[-1]
    scopes = {"all_models", "all_products"}
    if bare_model:
        scopes.update({f"model:{bare_model}", f"product:{bare_model}"})
    return [
        row
        for row in provider.get("quotaSemantics", {}).get("effectiveAvailability", [])
        if row.get("scope") in scopes
    ]


def availability_exhausted(provider: dict, model: str) -> bool:
    return any(
        row.get("runway", {}).get("status") == "exhausted_now"
        or (
            row.get("status") == "known"
            and isinstance(row.get("effectivePercentRemaining"), (int, float))
            and row["effectivePercentRemaining"] <= 0
        )
        for row in applicable_availability(provider, model)
    )


def availability_confirmed(provider: dict, model: str) -> bool:
    state = provider.get("state", {})
    semantics = provider.get("quotaSemantics", {})
    rows = applicable_availability(provider, model)
    return (
        state.get("status") == "fresh"
        and state.get("stale") is False
        and not state.get("error")
        and semantics.get("status") in {"known", "partial"}
        and bool(rows)
        and all(
            row.get("status") == "known"
            and isinstance(row.get("effectivePercentRemaining"), (int, float))
            and row["effectivePercentRemaining"] > 0
            and row.get("runway", {}).get("status")
            in {"through_reset", "projected_exhaustion"}
            for row in rows
        )
    )


def all_accounts_confirmed(accounts: list[dict], model: str) -> bool:
    # ponytail: the prober has no account selector, so every account row of a
    # provider must confirm runway; add an --account flag when lanes need one.
    return bool(accounts) and all(availability_confirmed(a, model) for a in accounts)


def unhealthy_result(
    harness: str,
    model: str,
    status: str,
    reason: str,
    providers: dict[str, list[dict]],
) -> dict:
    has_safe_diversion = all_accounts_confirmed(
        providers.get(DEFAULT_SAFE_HARNESS, []), DEFAULT_SAFE_MODEL
    )
    return {
        "harness": harness,
        "model": model,
        "status": status,
        "healthy": False,
        "reason": reason,
        "divert_harness": DEFAULT_SAFE_HARNESS if has_safe_diversion else "",
        "divert_model": DEFAULT_SAFE_MODEL if has_safe_diversion else "",
    }


def probe_harness(harness: str, model: str | None = None) -> dict:
    """
    Probe a specific harness and model combination.
    Returns health: 'healthy', 'exhausted', 'revoked', 'unknown'.
    """
    harness = harness.lower().strip()
    model = (model or "").lower().strip()

    quota_data = query_quota_axi()
    providers: dict[str, list[dict]] = {}
    for row in quota_data.get("providers", []):
        providers.setdefault(row.get("provider"), []).append(row)

    if harness == "grok" or "grok" in model:
        return unhealthy_result(
            harness,
            model,
            "forbidden",
            "Grok is reserved for Firstmate and cannot run crew work",
            providers,
        )

    # Pi GLM lanes are judged by the zai spend marker; every other lane needs
    # quota evidence from its own provider (a Pi model's is its id prefix).
    if harness == "pi" and ("zai-general" in model or "glm" in model):
        if is_zai_bundle_dry():
            return unhealthy_result(
                harness,
                model,
                "exhausted",
                "zai-general bundle is DRY (spend fact: insufficient balance)",
                providers,
            )
    else:
        provider = model.split("/", 1)[0] if harness == "pi" and "/" in model else harness
        accounts = providers.get(provider, [])
        if not accounts:
            return unhealthy_result(
                harness,
                model,
                "unknown",
                "No quota evidence available; runway is unknown",
                providers,
            )
        for account in accounts:
            state = account.get("state", {})
            if state.get("error"):
                return unhealthy_result(
                    harness,
                    model,
                    "revoked_or_unavailable",
                    state["error"],
                    providers,
                )
            if (
                account.get("credits", {}).get("remaining", 1) <= 0
                or availability_exhausted(account, model)
            ):
                return unhealthy_result(
                    harness,
                    model,
                    "exhausted",
                    f"{provider} quota exhausted",
                    providers,
                )
        if not all_accounts_confirmed(accounts, model):
            return unhealthy_result(
                harness,
                model,
                "unknown",
                f"{provider} quota evidence is stale or runway is unconfirmed",
                providers,
            )

    return {
        "harness": harness,
        "model": model,
        "status": "healthy",
        "healthy": True,
        "reason": "No quota blockers detected",
        "divert_harness": harness,
        "divert_model": model,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Jev Pre-Flight Quota & Token Health Prober")
    parser.add_argument("--harness", help="Harness to probe (e.g. pi, codex, cursor)")
    parser.add_argument("--model", help="Model to probe (e.g. zai-general/glm-5.3-flash, cursor-grok-4.6-high)")
    parser.add_argument("--auto-divert", action="store_true", help="Emit diverted harness and model if target is unhealthy")
    parser.add_argument("--check-all", action="store_true", help="Probe all standard fleet harnesses")
    parser.add_argument("--json", action="store_true", help="Output JSON")

    args = parser.parse_args()

    if args.check_all:
        results = [
            probe_harness("cursor", "cursor-grok-4.6-high"),
            probe_harness("cursor", "cursor-small"),
            probe_harness("codex", "gpt-5.6-luna"),
            probe_harness("pi", "zai-general/glm-5.3-flash"),
        ]
        if args.json:
            print(json.dumps(results, indent=2))
        else:
            print("Fleet Pre-Flight Harness Runway:")
            for r in results:
                icon = "✓" if r["healthy"] else "✗"
                div = f" -> divert to {r['divert_harness']}:{r['divert_model']}" if r["divert_harness"] else ""
                print(f"  {icon} {r['harness']} ({r['model']}): {r['status']} ({r['reason']}){div}")
        return 0

    if not args.harness:
        parser.print_help()
        return 2

    res = probe_harness(args.harness, args.model)

    if args.json:
        print(json.dumps(res, indent=2))
        return 0 if res["healthy"] else 1

    if args.auto_divert:
        if res["healthy"]:
            print(f"harness={res['harness']} model={res['model']} healthy=1")
            return 0
        if res["divert_harness"] and res["divert_model"]:
            print(f"harness={res['divert_harness']} model={res['divert_model']} healthy=0")
            return 0
        return 1

    if res["healthy"]:
        print(f"ok: {res['harness']} ({res['model']}) is healthy: {res['reason']}")
        return 0
    else:
        recommendation = (
            f" (recommended: {res['divert_harness']} {res['divert_model']})"
            if res["divert_harness"]
            else " (no permitted diversion has confirmed runway)"
        )
        print(f"blocked: {res['harness']} ({res['model']}) unhealthy: {res['reason']}{recommendation}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
