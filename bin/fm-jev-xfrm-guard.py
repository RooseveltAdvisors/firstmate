#!/usr/bin/env python3
"""
bin/fm-jev-xfrm-guard.py - Host Network IPsec & XFRM Transform Error Guard (Pattern 224)

Audits Linux kernel IPsec (XFRM) framework statistics from /proc/net/xfrm_stat:
  - Inbound transform drops (XfrmInError, XfrmInBufferError, XfrmInHdrError, XfrmInNoStates, XfrmInStateSeqError, XfrmInStateExpired)
  - Inbound policy violations (XfrmInNoPols, XfrmInPolBlock, XfrmInPolError)
  - Outbound transform drops (XfrmOutError, XfrmOutBundleGenError, XfrmOutNoStates, XfrmOutStateSeqError, XfrmOutStateExpired)
  - Outbound policy blocks (XfrmOutPolBlock, XfrmOutPolDead, XfrmOutPolError, XfrmOutNoQueueSpace)
  - Replay sequence desynchronization and key renegotiation drops

Detects VPN / WireGuard / IPsec tunnel desynchronization, replay attack drops, security association (SA) expirations,
and kernel packet discards before secure inter-host agent tunnels or clinic VPN gateways disconnect.

Invariants:
  - Read-only diagnostics. Safe, passive, and non-destructive.
  - Fail-open: graceful fallback when /proc/net/xfrm_stat is missing or restricted.
  - Bounded sub-millisecond execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List, Optional


def parse_xfrm_stat_file(path: str) -> Dict[str, int]:
    """Parse /proc/net/xfrm_stat format (key whitespace value)."""
    stats: Dict[str, int] = {}
    if not os.path.exists(path):
        return stats

    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                parts = line.split()
                if len(parts) >= 2:
                    k = parts[0]
                    try:
                        v = int(parts[1])
                        stats[k] = v
                    except ValueError:
                        continue
    except Exception:
        pass
    return stats


def audit_xfrm(
    stat_path: str = "/proc/net/xfrm_stat",
    warn_error_threshold: int = 100,
    crit_seq_error_threshold: int = 50,
) -> Dict[str, Any]:
    stats = parse_xfrm_stat_file(stat_path)

    # Inbound metrics
    in_error = stats.get("XfrmInError", 0)
    in_buffer_error = stats.get("XfrmInBufferError", 0)
    in_hdr_error = stats.get("XfrmInHdrError", 0)
    in_no_states = stats.get("XfrmInNoStates", 0)
    in_seq_error = stats.get("XfrmInStateSeqError", 0)
    in_expired = stats.get("XfrmInStateExpired", 0)
    in_pol_block = stats.get("XfrmInPolBlock", 0)
    in_pol_error = stats.get("XfrmInPolError", 0)

    # Outbound metrics
    out_error = stats.get("XfrmOutError", 0)
    out_bundle_gen_error = stats.get("XfrmOutBundleGenError", 0)
    out_no_states = stats.get("XfrmOutNoStates", 0)
    out_seq_error = stats.get("XfrmOutStateSeqError", 0)
    out_expired = stats.get("XfrmOutStateExpired", 0)
    out_pol_block = stats.get("XfrmOutPolBlock", 0)
    out_pol_error = stats.get("XfrmOutPolError", 0)
    out_no_queue_space = stats.get("XfrmOutNoQueueSpace", 0)

    total_in_errors = (
        in_error + in_buffer_error + in_hdr_error + in_no_states + in_seq_error + in_expired + in_pol_block + in_pol_error
    )
    total_out_errors = (
        out_error + out_bundle_gen_error + out_no_states + out_seq_error + out_expired + out_pol_block + out_pol_error + out_no_queue_space
    )
    total_errors = total_in_errors + total_out_errors
    total_seq_errors = in_seq_error + out_seq_error

    status = "HEALTHY"
    reasons: List[str] = []

    if total_seq_errors > crit_seq_error_threshold:
        status = "CRITICAL"
        reasons.append(f"Elevated anti-replay / sequence desynchronization errors: {total_seq_errors} (In: {in_seq_error}, Out: {out_seq_error})")
    elif total_errors > warn_error_threshold:
        status = "WARNING"
        reasons.append(f"Elevated XFRM transform and policy drops: {total_errors} total (In: {total_in_errors}, Out: {total_out_errors})")
    elif in_pol_block > 50 or out_pol_block > 50:
        status = "WARNING"
        reasons.append(f"Active policy block discards detected: InPolBlock={in_pol_block}, OutPolBlock={out_pol_block}")

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "reasons": reasons,
        "summary": {
            "total_errors": total_errors,
            "total_inbound_errors": total_in_errors,
            "total_outbound_errors": total_out_errors,
            "sequence_replay_errors": total_seq_errors,
            "policy_blocks": in_pol_block + out_pol_block,
            "missing_sa_drops": in_no_states + out_no_states,
        },
        "inbound": {
            "in_error": in_error,
            "in_buffer_error": in_buffer_error,
            "in_hdr_error": in_hdr_error,
            "in_no_states": in_no_states,
            "in_seq_error": in_seq_error,
            "in_expired": in_expired,
            "in_pol_block": in_pol_block,
            "in_pol_error": in_pol_error,
        },
        "outbound": {
            "out_error": out_error,
            "out_bundle_gen_error": out_bundle_gen_error,
            "out_no_states": out_no_states,
            "out_seq_error": out_seq_error,
            "out_expired": out_expired,
            "out_pol_block": out_pol_block,
            "out_pol_error": out_pol_error,
            "out_no_queue_space": out_no_queue_space,
        },
        "raw_stats": stats,
        "source": stat_path,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Audit Host Network IPsec & XFRM Transform Error Guard (Pattern 224)"
    )
    parser.add_argument("--stat-file", default="/proc/net/xfrm_stat", help="Path to /proc/net/xfrm_stat")
    parser.add_argument("--warn-error-threshold", type=int, default=100, help="Warning total error threshold")
    parser.add_argument("--crit-seq-threshold", type=int, default=50, help="Critical sequence error threshold")
    parser.add_argument("--json", action="store_true", help="Output JSON telemetry")

    args = parser.parse_args()
    report = audit_xfrm(
        stat_path=args.stat_file,
        warn_error_threshold=args.warn_error_threshold,
        crit_seq_error_threshold=args.crit_seq_threshold,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        status = report["status"]
        summary = report["summary"]
        in_s = report["inbound"]
        out_s = report["outbound"]
        print(f"[{status}] IPsec & XFRM Transform Guard:")
        print(f"  Total Errors: {summary['total_errors']} (Inbound: {summary['total_inbound_errors']}, Outbound: {summary['total_outbound_errors']})")
        print(f"  Inbound: InError={in_s['in_error']}, BufferErr={in_s['in_buffer_error']}, NoStates={in_s['in_no_states']}, SeqErr={in_s['in_seq_error']}, PolBlock={in_s['in_pol_block']}")
        print(f"  Outbound: OutError={out_s['out_error']}, BundleGenErr={out_s['out_bundle_gen_error']}, NoStates={out_s['out_no_states']}, SeqErr={out_s['out_seq_error']}, PolBlock={out_s['out_pol_block']}")
        if report["reasons"]:
            for r in report["reasons"]:
                print(f"  - {r}")

    if report["status"] == "CRITICAL":
        sys.exit(2)
    elif report["status"] == "WARNING":
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
