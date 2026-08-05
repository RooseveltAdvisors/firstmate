#!/usr/bin/env python3
"""Normalized semantic model for the GitHub Actions workflow under test.

tests/no-mistakes-required-workflow.test.sh needs to assert what the house
hardened gate *means* - which trigger fires it, which permissions the job
holds, which authors it exempts, which concurrency identity each event gets -
without grepping the raw YAML, where a reworded comment can both break an
assertion and hide a real regression.

This helper supplies that model in two parts:

  1. A loader for the block-YAML subset GitHub Actions workflows use (block
     mappings, block sequences, flow sequences, quoted and plain scalars,
     literal `|` and folded `>` block scalars, comments). Comments are
     discarded, so nothing in the model can be satisfied by prose.
  2. An evaluator for the GitHub expression subset those workflows use inside
     `${{ ... }}` and `if:` - context paths, string literals, `==`, `!=`,
     `&&`, `||`, `!`, and parentheses - against a synthetic event context.
     GitHub's `&&`/`||` return an operand rather than a boolean, which is
     exactly Python's `and`/`or` over the same falsy set (false, 0, '', null),
     so the translation below is faithful for that subset.

Commands:
  parse    <workflow>                       - the whole model as JSON
  get      <workflow> <path>                - one value as JSON
  render   <workflow> <path> <context-json> - a `${{ }}` template, rendered
  evaluate <workflow> <path> <context-json> - an `if:` expression's truthiness

<path> is dot-separated; a numeric segment indexes a sequence, e.g.
`jobs.check.steps.0.run`. A missing path exits 1 so a deleted block (a removed
`concurrency:`, say) fails the caller instead of silently rendering nothing.
"""

import json
import re
import sys

# --- YAML subset loader ------------------------------------------------------

BLOCK_STYLES = ("|", "|-", "|+", ">", ">-", ">+")
KEY_RE = re.compile(r"^([^:]+):(?:[ \t]+(.*))?$")
DASH_RE = re.compile(r"^-([ \t]+|$)")


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def skip_ignorable(lines, i):
    while i < len(lines):
        stripped = lines[i].strip()
        if stripped == "" or stripped.startswith("#"):
            i += 1
        else:
            return i
    return i


def parse_scalar(text):
    text = text.strip()
    if text == "":
        return None
    if text[0] in "\"'" and len(text) > 1 and text[-1] == text[0]:
        body = text[1:-1]
        if text[0] == "'":
            return body.replace("''", "'")
        return body.encode().decode("unicode_escape")
    if text.startswith("[") and text.endswith("]"):
        inner = text[1:-1].strip()
        if inner == "":
            return []
        return [parse_scalar(part) for part in inner.split(",")]
    # A plain scalar ends at an unquoted " #"; nothing else may be trimmed,
    # because expressions legitimately carry '#', '-' and ':' characters.
    cut = text.find(" #")
    if cut != -1:
        text = text[:cut].rstrip()
    if text in ("true", "false"):
        return text == "true"
    if text in ("null", "~"):
        return None
    if re.fullmatch(r"-?\d+", text):
        return int(text)
    return text


def read_block_scalar(lines, i, key_indent, style):
    body = []
    content_indent = None
    while i < len(lines):
        line = lines[i]
        if line.strip() == "":
            body.append("")
            i += 1
            continue
        if indent_of(line) <= key_indent:
            break
        if content_indent is None:
            content_indent = indent_of(line)
        body.append(line[content_indent:])
        i += 1
    while body and body[-1] == "":
        body.pop()
    if style.startswith(">"):
        text = " ".join(part.strip() for part in body if part.strip() != "")
    else:
        text = "\n".join(body)
    chomp = style[1:]
    if chomp == "-":
        return text, i
    if chomp == "+" or not style.startswith(">"):
        return text + "\n", i
    return text, i


def parse_block(lines, i, indent):
    i = skip_ignorable(lines, i)
    if i >= len(lines) or indent_of(lines[i]) < indent:
        return None, i
    if DASH_RE.match(lines[i].lstrip(" ")):
        return parse_sequence(lines, i, indent)
    return parse_mapping(lines, i, indent)


def parse_child(lines, i, parent_indent):
    """Value of a key whose own line carried none: the block below it."""
    probe = skip_ignorable(lines, i)
    if probe >= len(lines):
        return None, probe
    child_indent = indent_of(lines[probe])
    if child_indent > parent_indent:
        return parse_block(lines, probe, child_indent)
    # A sequence may sit at the key's own indent.
    if child_indent == parent_indent and DASH_RE.match(lines[probe].lstrip(" ")):
        return parse_sequence(lines, probe, child_indent)
    return None, probe


def parse_mapping(lines, i, indent):
    out = {}
    while True:
        i = skip_ignorable(lines, i)
        if i >= len(lines) or indent_of(lines[i]) != indent:
            break
        text = lines[i].strip()
        match = KEY_RE.match(text)
        if match is None:
            raise ValueError("unsupported YAML line %d: %s" % (i + 1, text))
        key = match.group(1).strip()
        raw = (match.group(2) or "").strip()
        i += 1
        if raw in BLOCK_STYLES:
            out[key], i = read_block_scalar(lines, i, indent, raw)
        elif raw == "":
            out[key], i = parse_child(lines, i, indent)
        else:
            out[key] = parse_scalar(raw)
    return out, i


def parse_sequence(lines, i, indent):
    out = []
    while True:
        i = skip_ignorable(lines, i)
        if i >= len(lines) or indent_of(lines[i]) != indent:
            break
        stripped = lines[i].lstrip(" ")
        dash = DASH_RE.match(stripped)
        if dash is None:
            break
        body_indent = indent + len(dash.group(0))
        rest = stripped[len(dash.group(0)):]
        if rest.strip() == "":
            item, i = parse_block(lines, i + 1, body_indent)
        elif KEY_RE.match(rest.strip()) is None and DASH_RE.match(rest) is None:
            # A plain scalar item, e.g. the `- main` under a `branches:` filter.
            # Without this the model cannot even load a branch-filtered gate, so
            # the filter assertions would crash instead of reporting the filter.
            item, i = parse_scalar(rest), i + 1
        else:
            # Re-indent the item's first line so it reads as a plain block.
            lines[i] = " " * body_indent + rest
            item, i = parse_block(lines, i, body_indent)
        out.append(item)
    return out, i


def load(path):
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().split("\n")
    value, _ = parse_block(lines, 0, 0)
    return value if value is not None else {}


# --- GitHub expression subset ------------------------------------------------

TOKEN_RE = re.compile(
    r"""
      (?P<str>'(?:[^']|'')*')
    | (?P<num>\d+(?:\.\d+)?)
    | (?P<path>[A-Za-z_][A-Za-z0-9_\-]*(?:\.[A-Za-z_][A-Za-z0-9_\-]*)*)
    | (?P<op>&&|\|\||==|!=|>=|<=|>|<|!|\(|\)|,)
    | (?P<ws>\s+)
    """,
    re.X,
)

OPS = {"&&": " and ", "||": " or ", "!": " not "}
CONSTANTS = {"true": "True", "false": "False", "null": "None"}


def lookup(ctx, *keys):
    node = ctx
    for key in keys:
        if not isinstance(node, dict):
            return None
        node = node.get(key)
    return node


def translate(expr):
    out = []
    pos = 0
    while pos < len(expr):
        match = TOKEN_RE.match(expr, pos)
        if match is None:
            raise ValueError("unsupported expression token at %r" % expr[pos:])
        pos = match.end()
        kind = match.lastgroup
        text = match.group()
        if kind == "ws":
            out.append(" ")
        elif kind == "str":
            out.append(repr(text[1:-1].replace("''", "'")))
        elif kind == "num":
            out.append(text)
        elif kind == "op":
            out.append(OPS.get(text, text))
        else:
            lowered = text.lower()
            if lowered in CONSTANTS:
                out.append(CONSTANTS[lowered])
            else:
                args = ", ".join(repr(part) for part in text.split("."))
                out.append("lookup(C, %s)" % args)
    return "".join(out)


def evaluate(expr, ctx):
    return eval(  # noqa: S307 - fixed grammar above, test-only helper
        translate(expr), {"__builtins__": {}, "lookup": lookup}, {"C": ctx}
    )


def to_text(value):
    if value is True:
        return "true"
    if value is False:
        return "false"
    if value is None:
        return ""
    return str(value)


TEMPLATE_RE = re.compile(r"\$\{\{(.*?)\}\}", re.S)


def render(template, ctx):
    return TEMPLATE_RE.sub(lambda m: to_text(evaluate(m.group(1), ctx)), template)


# --- CLI ---------------------------------------------------------------------


def resolve(model, path):
    node = model
    for segment in path.split("."):
        if isinstance(node, list):
            if not segment.isdigit() or int(segment) >= len(node):
                return None, False
            node = node[int(segment)]
        elif isinstance(node, dict):
            if segment not in node:
                return None, False
            node = node[segment]
        else:
            return None, False
    return node, True


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    command, workflow = argv[1], argv[2]
    model = load(workflow)
    if command == "parse":
        print(json.dumps(model, indent=2, sort_keys=True))
        return 0
    if len(argv) < 4:
        sys.stderr.write("%s requires a path\n" % command)
        return 2
    value, found = resolve(model, argv[3])
    if not found:
        sys.stderr.write("workflow has no %s\n" % argv[3])
        return 1
    if command == "get":
        print(value if isinstance(value, str) else json.dumps(value))
        return 0
    if len(argv) < 5:
        sys.stderr.write("%s requires a context JSON argument\n" % command)
        return 2
    ctx = json.loads(argv[4])
    if command == "render":
        print(render(value, ctx))
        return 0
    if command == "evaluate":
        print("true" if evaluate(value, ctx) else "false")
        return 0
    sys.stderr.write("unknown command: %s\n" % command)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
