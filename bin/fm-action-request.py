#!/usr/bin/env python3
"""Internal request codec; the protected action gate owns authorization and execution.

mint <class>: read a request, emit its validated snapshot and SHA-256 binding.
check <class>: read a grant, validate its request and digest.
match <class> <argv...>: additionally require the exact approved invocation.
All input and output documents use JSON on stdin/stdout; refusals go to stderr.
"""

import argparse
import hashlib
import ipaddress
import json
import re
import sys
from urllib.parse import urlsplit


def object_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON member")
        result[key] = value
    return result


def decode(raw):
    def invalid_constant(_value):
        raise ValueError("non-finite JSON number")

    return json.loads(raw, object_pairs_hook=object_pairs, parse_constant=invalid_constant)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)


def normalize(action):
    return "prod_deploy" if action == "deploy" else action


def request_document(request, action):
    if action not in ("booking", "charging", "prod_deploy"):
        raise ValueError("unsupported consequential action")
    if not isinstance(request, dict) or set(request) != {"provenance", "argv"}:
        raise ValueError("request requires only provenance and argv")
    provenance = request["provenance"]
    if not isinstance(provenance, dict) or set(provenance) != {"kind", "origin_action_class"}:
        raise ValueError("missing bound provenance")
    if provenance["kind"] not in ("trusted", "untrusted-forwarded"):
        raise ValueError("missing bound provenance")
    if normalize(provenance["origin_action_class"]) != action:
        raise ValueError("provenance origin cannot be relabeled")
    argv = request["argv"]
    if not isinstance(argv, list) or len(argv) != 2 or argv[0] != "http-json" or not isinstance(argv[1], str):
        raise ValueError("only the built-in http-json operation is permitted; external commands and payload files deny")
    document = decode(argv[1])
    required = {"url", "method", "account_id", "credential_id", "headers", "body"}
    if not isinstance(document, dict) or set(document) != required:
        raise ValueError("HTTP request requires URL, method, account, credential, headers and body")
    if document["method"] not in ("POST", "PUT", "PATCH", "DELETE"):
        raise ValueError("unsupported HTTP action method")
    if not isinstance(document["url"], str) or any(ord(c) <= 32 or ord(c) == 127 for c in document["url"]):
        raise ValueError("invalid destination URL")
    destination = urlsplit(document["url"])
    if not destination.hostname or destination.username is not None or destination.password is not None or destination.fragment:
        raise ValueError("destination must not contain user information or fragments")
    # Accessing port also validates malformed and out-of-range port spellings.
    _ = destination.port
    if destination.scheme != "https":
        try:
            loopback = ipaddress.ip_address(destination.hostname).is_loopback
        except ValueError:
            loopback = False
        if destination.scheme != "http" or not loopback:
            raise ValueError("HTTPS required except for a literal synthetic loopback destination")
    for key in ("account_id", "credential_id"):
        if not isinstance(document[key], str) or not re.fullmatch(r"[a-zA-Z0-9_:\-]+", document[key]):
            raise ValueError("invalid account or credential identifier")
    headers = document["headers"]
    if not isinstance(headers, dict) or set(headers) - {"Authorization"}:
        raise ValueError("only the approved Authorization header may be supplied")
    if any(not isinstance(v, str) or any(ord(c) < 32 or ord(c) == 127 for c in v) for v in headers.values()):
        raise ValueError("invalid approved header")
    if not isinstance(document["body"], dict):
        raise ValueError("action body must be a JSON object")
    canonical(document)
    return document


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("mint", "check", "match"))
    parser.add_argument("action")
    parser.add_argument("argv", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    try:
        value = decode(sys.stdin.read())
        if not isinstance(value, dict):
            raise ValueError("expected a JSON object")
        request = value if args.mode == "mint" else value.get("request")
        document = request_document(request, normalize(args.action))
        digest = hashlib.sha256(canonical(request).encode("utf-8")).hexdigest()
        payload_digest = hashlib.sha256(canonical(document["body"]).encode("utf-8")).hexdigest()
        if args.mode != "mint":
            if value.get("schema") != "fm-action-grant.v2" or value.get("request_sha256") != digest or value.get("payload_sha256") != payload_digest:
                raise ValueError("missing or mismatched approved request digest")
        if args.mode == "match" and args.argv != request["argv"]:
            raise ValueError("command differs from approved payload")
        result = {"request": request, "request_sha256": digest, "payload_sha256": payload_digest} if args.mode == "mint" else document
        print(canonical(result))
        return 0
    except (ValueError, TypeError, KeyError, UnicodeError, RecursionError) as error:
        print("fm-action-gate: DENY: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
