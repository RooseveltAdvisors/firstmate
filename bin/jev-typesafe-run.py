#!/usr/bin/env python3
"""DECOMMISSIONED: jev-typesafe-run.py has been decommissioned.

Strict Invariant: No .env, no os.environ / env fallback, no /etc/arcs/op-token, no sudo.
Credentials for Jev System One are resolved strictly via Agent Vault UNIX domain socket
(/run/agent-vault/agent-vault.sock) using the scoped session token at
/etc/arcs/agent-vault/jev.session.

Please use the Jev service directly:
  /opt/ra/firstmate/projects/jev/bin/jev run -- <command> [args...]
or import jev.vault / jev.client from /opt/ra/firstmate/projects/jev/src.
"""
import sys


def main() -> None:
    print(
        "ERROR: jev-typesafe-run.py is DECOMMISSIONED.\n"
        "Strict Invariant: No .env, no os.environ fallback, no /etc/arcs/op-token, no sudo.\n"
        "Please use /opt/ra/firstmate/projects/jev/bin/jev instead.",
        file=sys.stderr,
    )
    sys.exit(1)


if __name__ == "__main__":
    main()
