#!/usr/bin/env python3
"""
fm-jev-endpoint-guard.py - Jev Multi-Agent Upstream Service Endpoint & Latency Guard (Pattern 49)

Probes critical local daemons (Postgres, Redis) and external upstream cloud APIs (GitHub,
Jev System One API) to measure round-trip latency and detect connection timeouts, broken
routes, or upstream outages before autonomous agent tasks hang or fail silently.

Invariants:
  - Read-only diagnostics.
  - Fail-open: graceful fallback on individual endpoint connectivity issues.
  - Bounded runtime with parallel probing (< 2.5s total).
"""

import argparse
import concurrent.futures
import json
import socket
import sys
import time
import urllib.request
from datetime import datetime, timezone
from typing import Any, Dict, List


DEFAULT_ENDPOINTS = [
    "https://api.github.com",
    "https://api.typesafe.ai",
    "tcp://127.0.0.1:5432",
]


def probe_tcp(host: str, port: int, timeout: float = 2.0) -> Dict[str, Any]:
    """Probes a TCP listener port."""
    t0 = time.time()
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect((host, port))
        s.close()
        latency_ms = round((time.time() - t0) * 1000.0, 2)
        return {
            "endpoint": f"tcp://{host}:{port}",
            "type": "tcp",
            "reachable": True,
            "status_code": 0,
            "latency_ms": latency_ms,
            "error": None,
        }
    except Exception as e:
        latency_ms = round((time.time() - t0) * 1000.0, 2)
        return {
            "endpoint": f"tcp://{host}:{port}",
            "type": "tcp",
            "reachable": False,
            "status_code": 0,
            "latency_ms": latency_ms,
            "error": str(e),
        }


def probe_http(url: str, timeout: float = 2.0) -> Dict[str, Any]:
    """Probes an HTTP/HTTPS endpoint."""
    t0 = time.time()
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "fm-jev-endpoint-guard/1.0"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            latency_ms = round((time.time() - t0) * 1000.0, 2)
            return {
                "endpoint": url,
                "type": "http",
                "reachable": True,
                "status_code": resp.status,
                "latency_ms": latency_ms,
                "error": None,
            }
    except urllib.error.HTTPError as e:
        # HTTP errors like 401, 403, 404 still mean the server is reachable and responsive
        latency_ms = round((time.time() - t0) * 1000.0, 2)
        return {
            "endpoint": url,
            "type": "http",
            "reachable": True,
            "status_code": e.code,
            "latency_ms": latency_ms,
            "error": str(e) if e.code >= 500 else None,
        }
    except Exception as e:
        latency_ms = round((time.time() - t0) * 1000.0, 2)
        return {
            "endpoint": url,
            "type": "http",
            "reachable": False,
            "status_code": 0,
            "latency_ms": latency_ms,
            "error": str(e),
        }


def probe_endpoint(target: str, timeout: float = 2.0) -> Dict[str, Any]:
    """Dispatches probe by protocol."""
    if target.startswith("tcp://"):
        addr = target[6:]
        if ":" in addr:
            host, port_s = addr.split(":", 1)
            port = int(port_s) if port_s.isdigit() else 80
            return probe_tcp(host, port, timeout=timeout)
        return probe_tcp(addr, 80, timeout=timeout)
    else:
        return probe_http(target, timeout=timeout)


def audit_endpoints(
    endpoints: List[str] | None = None,
    timeout: float = 2.0,
    max_latency_ms: float = 2000.0,
) -> Dict[str, Any]:
    """Audits health and latency of all target endpoints concurrently."""
    if endpoints is None:
        endpoints = DEFAULT_ENDPOINTS

    results: List[Dict[str, Any]] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(8, len(endpoints))) as executor:
        future_to_ep = {executor.submit(probe_endpoint, ep, timeout): ep for ep in endpoints}
        for future in concurrent.futures.as_completed(future_to_ep):
            try:
                results.append(future.result())
            except Exception as e:
                ep = future_to_ep[future]
                results.append({
                    "endpoint": ep,
                    "type": "unknown",
                    "reachable": False,
                    "status_code": 0,
                    "latency_ms": 0.0,
                    "error": str(e),
                })

    reachable_count = sum(1 for r in results if r["reachable"])
    unreachable_count = len(results) - reachable_count
    slow_count = sum(1 for r in results if r["reachable"] and r["latency_ms"] > max_latency_ms)

    healthy = unreachable_count == 0 and slow_count == 0

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "total_endpoints": len(results),
            "reachable_endpoints": reachable_count,
            "unreachable_endpoints": unreachable_count,
            "slow_endpoints": slow_count,
            "max_latency_threshold_ms": max_latency_ms,
            "healthy": healthy,
        },
        "endpoints": sorted(results, key=lambda x: x["endpoint"]),
    }


def main():
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Upstream Service Endpoint & Latency Guard (Pattern 49)"
    )
    parser.add_argument(
        "--endpoints",
        nargs="+",
        default=DEFAULT_ENDPOINTS,
        help="Endpoints to probe (HTTP/HTTPS or tcp://host:port)",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=2.0,
        help="Probe timeout in seconds (default: 2.0)",
    )
    parser.add_argument(
        "--max-latency-ms",
        type=float,
        default=2000.0,
        help="Threshold for slow endpoint alert in ms (default: 2000.0)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit structured JSON telemetry to stdout",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit with code 0 if healthy, code 1 if unreachable or degraded",
    )

    args = parser.parse_args()
    report = audit_endpoints(
        endpoints=args.endpoints,
        timeout=args.timeout,
        max_latency_ms=args.max_latency_ms,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        s = report["summary"]
        print(f"Jev Endpoint Health & Latency Guard (Pattern 49) — {report['timestamp']}")
        print(f"  • Total Endpoints: {s['total_endpoints']} ({s['reachable_endpoints']} reachable, {s['unreachable_endpoints']} unreachable, {s['slow_endpoints']} slow)")
        print(f"  • Status: {'HEALTHY' if s['healthy'] else 'DEGRADED'}")
        if report["endpoints"]:
            print("\n  Endpoint Details:")
            for ep in report["endpoints"]:
                status_str = f"HTTP {ep['status_code']}" if ep['type'] == 'http' else "CONNECTED"
                state = f"OK ({ep['latency_ms']}ms, {status_str})" if ep['reachable'] else f"FAILED ({ep['error']})"
                print(f"    - {ep['endpoint']}: {state}")

    if args.check and not report["summary"]["healthy"]:
        sys.exit(1)


if __name__ == "__main__":
    main()
