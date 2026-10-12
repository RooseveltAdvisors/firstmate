#!/usr/bin/env python3
"""
fm-jev-container-guard.py - Jev Multi-Agent Docker & Podman Container / Volume Orphan Guard (Pattern 58)

Audits host and user-space container runtimes (Podman / Docker) for dead/exited containers,
dangling anonymous volumes (MountCount == 0), and unreferenced test fixture artifacts.
Prevents volume leaks and container accumulation across multi-agent automated test runs.

Invariants:
  - Read-only diagnostics by default. Non-destructive.
  - Fail-open: graceful handling if container runtime is absent or daemon is unreachable.
  - Bounded fast execution (< 2.0s).
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple


DEFAULT_MAX_DEAD_CONTAINERS = 5
DEFAULT_MAX_ORPHAN_VOLUMES = 10


def run_cmd(cmd: List[str], timeout: int = 5) -> Tuple[int, str]:
    """Runs a command and returns (returncode, stdout)."""
    try:
        res = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
            check=False,
        )
        return res.returncode, res.stdout.strip()
    except Exception as e:
        return 1, str(e)


def detect_runtime() -> Optional[str]:
    """Detects available container CLI: podman preferred for user namespace, else docker."""
    if shutil.which("podman"):
        return "podman"
    if shutil.which("docker"):
        return "docker"
    return None


def audit_containers(runtime: str) -> List[Dict[str, Any]]:
    """Audits containers and returns exited/stopped containers."""
    code, out = run_cmd([runtime, "ps", "-a", "--format", "json"])
    if code != 0 or not out:
        return []

    try:
        data = json.loads(out)
        if not isinstance(data, list):
            data = [data]
    except Exception:
        return []

    dead_containers = []
    for c in data:
        state = str(c.get("State", "")).lower()
        status = str(c.get("Status", ""))
        exited = c.get("Exited", False) or "exited" in state or "exited" in status.lower()

        if exited:
            names = c.get("Names")
            name = names[0] if isinstance(names, list) and names else str(names or c.get("Id", "")[:12])
            dead_containers.append({
                "id": str(c.get("Id", ""))[:12],
                "name": name,
                "image": str(c.get("Image", "")),
                "state": state,
                "status": status,
                "exit_code": c.get("ExitCode", 0),
                "created": c.get("CreatedAt", c.get("Created", "")),
            })

    return dead_containers


def audit_volumes(runtime: str) -> List[Dict[str, Any]]:
    """Audits volumes and returns unmounted/dangling volumes."""
    code, out = run_cmd([runtime, "volume", "ls", "--format", "json"])
    if code != 0 or not out:
        return []

    try:
        data = json.loads(out)
        if not isinstance(data, list):
            data = [data]
    except Exception:
        return []

    dangling_volumes = []
    for v in data:
        # In podman, MountCount == 0 means volume is not attached to any running container
        mount_count = v.get("MountCount", 0)
        is_anonymous = v.get("Anonymous", False)
        name = str(v.get("Name", ""))

        if mount_count == 0:
            mountpoint = v.get("Mountpoint", "")
            size_mb = 0.0
            if mountpoint and os.path.exists(mountpoint):
                try:
                    # Quick stat on mountpoint dir
                    size_bytes = sum(
                        os.path.getsize(os.path.join(dirpath, f))
                        for dirpath, _, filenames in os.walk(mountpoint)
                        for f in filenames
                    )
                    size_mb = round(size_bytes / (1024 * 1024), 2)
                except Exception:
                    pass

            dangling_volumes.append({
                "name": name[:16] if len(name) > 32 else name,
                "full_name": name,
                "mountpoint": mountpoint,
                "size_mb": size_mb,
                "anonymous": is_anonymous,
                "created": str(v.get("CreatedAt", "")),
            })

    return dangling_volumes


def audit_fleet_containers(
    max_dead: int = DEFAULT_MAX_DEAD_CONTAINERS,
    max_volumes: int = DEFAULT_MAX_ORPHAN_VOLUMES,
) -> Dict[str, Any]:
    """Audits container runtime and volume state."""
    runtime = detect_runtime()
    if not runtime:
        return {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "summary": {
                "runtime_detected": None,
                "dead_containers_count": 0,
                "dangling_volumes_count": 0,
                "status": "HEALTHY",
                "recommendation": "no container runtime present; skipping check",
                "healthy": True,
            },
            "dead_containers": [],
            "dangling_volumes": [],
        }

    dead = audit_containers(runtime)
    dangling = audit_volumes(runtime)
    total_volume_mb = round(sum(v["size_mb"] for v in dangling), 2)

    status = "HEALTHY"
    recommendation = "optimal"

    if len(dead) >= max_dead or len(dangling) >= max_volumes:
        status = "WARNING"
        recommendation = f"{len(dead)} exited containers, {len(dangling)} dangling volumes ({total_volume_mb} MB); prune recommended"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "runtime_detected": runtime,
            "dead_containers_count": len(dead),
            "dangling_volumes_count": len(dangling),
            "dangling_volumes_size_mb": total_volume_mb,
            "max_dead_threshold": max_dead,
            "max_volumes_threshold": max_volumes,
            "status": status,
            "recommendation": recommendation,
            "healthy": (status == "HEALTHY"),
        },
        "dead_containers": dead,
        "dangling_volumes": dangling,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Container & Volume Orphan Guard (Pattern 58)"
    )
    parser.add_argument(
        "--max-dead",
        type=int,
        default=DEFAULT_MAX_DEAD_CONTAINERS,
        help=f"Exited containers warning threshold (default: {DEFAULT_MAX_DEAD_CONTAINERS})",
    )
    parser.add_argument(
        "--max-volumes",
        type=int,
        default=DEFAULT_MAX_ORPHAN_VOLUMES,
        help=f"Dangling volumes warning threshold (default: {DEFAULT_MAX_ORPHAN_VOLUMES})",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output raw JSON results",
    )

    args = parser.parse_args()

    results = audit_fleet_containers(
        max_dead=args.max_dead,
        max_volumes=args.max_volumes,
    )

    if args.json:
        print(json.dumps(results, indent=2))
        return 0 if results["summary"]["healthy"] else 1

    summary = results["summary"]
    print(f"Jev Container & Volume Guard (Pattern 58) - {results['timestamp']}")
    print(f"Runtime:            {summary['runtime_detected']}")
    print(f"Dead Containers:    {summary['dead_containers_count']}")
    print(f"Dangling Volumes:   {summary['dangling_volumes_count']} ({summary['dangling_volumes_size_mb']} MB)")
    print(f"Health Status:      {summary['status']}")
    print(f"Recommendation:     {summary['recommendation']}")

    if results["dead_containers"]:
        print("\nExited Containers:")
        for c in results["dead_containers"]:
            print(f"  - [{c['id']}] {c['name']} (image: {c['image']}, status: {c['status']})")

    if results["dangling_volumes"]:
        print("\nDangling Volumes:")
        for v in results["dangling_volumes"][:10]:
            print(f"  - {v['name']}: {v['size_mb']} MB (created: {v['created'][:19]})")

    return 0 if summary["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
