#!/usr/bin/env python3
"""Internal request codec; the protected action gate owns authorization and execution.

mint <class> <target> <adapter-root>: validate a request and emit its bindings.
check <class> <target> <adapter-root>: validate a grant and its bindings.
match <class> <target> <adapter-root> <argv...>: also match the invocation.
All input and output documents use JSON on stdin/stdout; refusals go to stderr.
"""

import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import stat
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


def protected_path(raw, directory=False, executable=False):
    if not isinstance(raw, str) or not raw.startswith("/"):
        raise ValueError("adapter paths must be absolute")
    path = Path(raw)
    if str(path.resolve(strict=True)) != raw:
        raise ValueError("adapter paths must use their canonical spelling")
    for index, node in enumerate((path, *path.parents)):
        metadata = node.lstat()
        if metadata.st_uid != 0 or stat.S_ISLNK(metadata.st_mode):
            raise ValueError("adapter and ancestor ownership must be protected")
        sticky_ancestor = index > 0 and stat.S_ISDIR(metadata.st_mode) and bool(metadata.st_mode & stat.S_ISVTX)
        if metadata.st_mode & 0o022 or (os.geteuid() != 0 and os.access(node, os.W_OK)):
            if not sticky_ancestor:
                raise ValueError("worker-writable adapter path or ancestor")
        if index == 0:
            expected_type = stat.S_ISDIR if directory else stat.S_ISREG
            if not expected_type(metadata.st_mode):
                raise ValueError("unexpected adapter path type")
            if executable and (metadata.st_mode & (stat.S_ISUID | stat.S_ISGID) or not os.access(node, os.X_OK)):
                raise ValueError("adapter must be executable without set-id privileges")
    return path


def file_digest(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def command_document(request, action, target, adapter_root):
    identifier = request["adapter_id"]
    if not isinstance(identifier, str) or not re.fullmatch(r"[a-zA-Z0-9_:\-]+", identifier):
        raise ValueError("invalid registered adapter identifier")
    root = protected_path(adapter_root, directory=True)
    manifest_path = protected_path(str(root / (identifier + ".json")))
    manifest = decode(manifest_path.read_text())
    fields = {"schema", "action_class", "target", "argv", "executable_sha256", "env", "input_files"}
    if not isinstance(manifest, dict) or set(manifest) != fields or manifest["schema"] != "fm-action-command-adapter.v1":
        raise ValueError("invalid registered command adapter")
    if action != "prod_deploy" or manifest["action_class"] != action or manifest["target"] != target:
        raise ValueError("registered adapter action or target mismatch")
    executable = protected_path(str(root / (identifier + ".exec")), executable=True)
    cwd = protected_path(str(root / (identifier + ".cwd")), directory=True)
    if file_digest(executable) != manifest["executable_sha256"]:
        raise ValueError("registered adapter executable digest mismatch")
    argv = manifest["argv"]
    if not isinstance(argv, list) or not argv or argv[0] != str(executable) or any(not isinstance(arg, str) or "\0" in arg for arg in argv):
        raise ValueError("invalid registered adapter arguments")
    if request["argv"] != argv:
        raise ValueError("command differs from registered adapter arguments")
    environment = manifest["env"]
    reserved = {"PATH", "HOME", "ENV", "BASH_ENV", "IFS", "SHELLOPTS", "BASHOPTS", "NODE_OPTIONS", "RUBYOPT", "PERL5OPT", "JAVA_TOOL_OPTIONS"}
    if not isinstance(environment, dict) or any(not re.fullmatch(r"[A-Z_][A-Z0-9_]*", key) or key in reserved or key.startswith(("LD_", "DYLD_", "PYTHON", "GIT_")) or not isinstance(value, str) or "\0" in value for key, value in environment.items()):
        raise ValueError("invalid registered adapter environment")
    inputs = manifest["input_files"]
    if not isinstance(inputs, list):
        raise ValueError("registered adapter inputs must be explicit")
    paths = set()
    for item in inputs:
        if not isinstance(item, dict) or set(item) != {"path", "sha256"}:
            raise ValueError("invalid registered adapter input")
        path = protected_path(item["path"])
        if str(path) in paths or file_digest(path) != item["sha256"]:
            raise ValueError("registered adapter input digest mismatch")
        paths.add(str(path))
    if any(arg.startswith("/") and arg not in paths for arg in argv[1:]):
        raise ValueError("absolute command arguments must name protected declared inputs")
    digest = hashlib.sha256(canonical(manifest).encode("utf-8")).hexdigest()
    return {"kind": "protected-command", "argv": argv, "cwd": str(cwd), "env": environment}, digest


def request_document(request, action, target, adapter_root):
    if action not in ("booking", "charging", "prod_deploy"):
        raise ValueError("unsupported consequential action")
    if not isinstance(request, dict) or set(request) not in ({"provenance", "argv"}, {"provenance", "argv", "adapter_id"}):
        raise ValueError("request requires provenance, argv and an optional registered adapter identifier")
    provenance = request["provenance"]
    if not isinstance(provenance, dict) or set(provenance) != {"kind", "origin_action_class"}:
        raise ValueError("missing bound provenance")
    if provenance["kind"] not in ("trusted", "untrusted-forwarded"):
        raise ValueError("missing bound provenance")
    if normalize(provenance["origin_action_class"]) != action:
        raise ValueError("provenance origin cannot be relabeled")
    if "adapter_id" in request:
        return command_document(request, action, target, adapter_root)
    argv = request["argv"]
    if not isinstance(argv, list) or len(argv) != 2 or argv[0] != "http-json" or not isinstance(argv[1], str):
        raise ValueError("unregistered external commands and payload files deny; use http-json or a protected command adapter")
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
    return {"kind": "http-json", "request": document}, None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("mint", "check", "match"))
    parser.add_argument("action")
    parser.add_argument("target")
    parser.add_argument("adapter_root")
    parser.add_argument("argv", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    try:
        value = decode(sys.stdin.read())
        if not isinstance(value, dict):
            raise ValueError("expected a JSON object")
        request = value if args.mode == "mint" else value.get("request")
        plan, adapter_digest = request_document(request, normalize(args.action), args.target, args.adapter_root)
        digest = hashlib.sha256(canonical(request).encode("utf-8")).hexdigest()
        payload = plan["request"]["body"] if plan["kind"] == "http-json" else plan
        payload_digest = hashlib.sha256(canonical(payload).encode("utf-8")).hexdigest()
        if args.mode != "mint":
            if value.get("schema") != "fm-action-grant.v2" or value.get("request_sha256") != digest or value.get("payload_sha256") != payload_digest or value.get("adapter_sha256") != adapter_digest:
                raise ValueError("missing or mismatched approved request digest")
        if args.mode == "match" and args.argv != request["argv"]:
            raise ValueError("command differs from approved payload")
        result = {"request": request, "request_sha256": digest, "payload_sha256": payload_digest, "adapter_sha256": adapter_digest} if args.mode == "mint" else plan
        print(canonical(result))
        return 0
    except (ValueError, TypeError, KeyError, UnicodeError, RecursionError) as error:
        print("fm-action-gate: DENY: " + str(error), file=sys.stderr)
        return 1
    except OSError as error:
        print("fm-action-gate: DENY: protected adapter filesystem check failed (" + type(error).__name__ + ")", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
