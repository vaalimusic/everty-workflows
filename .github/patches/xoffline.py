#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Display a red X for offline peers instead of the amber status dot.

Edits flutter/lib/common/widgets/peer_card.dart and replaces the offline branch
of getOnline():
    child: CircleAvatar(
        radius: 3, backgroundColor: online ? Colors.green : kColorWarn)
with a red Material close icon, while leaving the online green dot untouched.

The patcher is idempotent.
"""

import argparse
import pathlib
import re
import sys

# Force UTF-8 stdout/stderr
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')

MARKER = "RDGEN_OFFLINE_X"

FUNC_RE = re.compile(
    r"\bWidget\s+getOnline\s*\(\s*double\s+rightPadding\s*,\s*bool\s+online\s*\)\s*\{"
)

DOT_RE = re.compile(
    r"(?P<indent>[ \t]*)child:\s*"
    r"CircleAvatar\(\s*\n"
    r"[ \t]*radius:\s*3\s*,\s*"
    r"backgroundColor:\s*online\s*\?\s*Colors\.green\s*:\s*kColorWarn\s*\)"
)


def find_function(text, name):
    match = FUNC_RE.search(text)
    if match is None:
        return None
    start = match.start()
    end_match = re.search(r"(?m)^\}\s*$", text[match.end():])
    if end_match is None:
        return None
    return start, match.end() + end_match.end()


def apply_xoffline(text):
    if MARKER in text:
        return text, False

    bounds = find_function(text, "getOnline")
    if bounds is None:
        # Fallback regex across entire text if function signature varied slightly
        if DOT_RE.search(text):
            match = DOT_RE.search(text)
            indent = match.group("indent")
            replacement = (
                f"{indent}// {MARKER}: show a red X instead of the amber offline dot\n"
                f"{indent}child: online\n"
                f"{indent}    ? CircleAvatar(radius: 3, backgroundColor: Colors.green)\n"
                f"{indent}    : Icon(\n"
                f"{indent}        Icons.close,\n"
                f"{indent}        color: Colors.red,\n"
                f"{indent}        size: 12.0,\n"
                f"{indent}      )"
            )
            return text[:match.start()] + replacement + text[match.end():], True
        print("Warning: getOnline() not found in peer_card.dart, skipping xoffline patch.")
        return text, False

    start, end = bounds
    body = text[start:end]

    match = DOT_RE.search(body)
    if match is None:
        print("Warning: CircleAvatar pattern not found in getOnline(), skipping xoffline patch.")
        return text, False

    indent = match.group("indent")
    replacement = (
        f"{indent}// {MARKER}: show a red X instead of the amber offline dot\n"
        f"{indent}child: online\n"
        f"{indent}    ? CircleAvatar(radius: 3, backgroundColor: Colors.green)\n"
        f"{indent}    : Icon(\n"
        f"{indent}        Icons.close,\n"
        f"{indent}        color: Colors.red,\n"
        f"{indent}        size: 12.0,\n"
        f"{indent}      )"
    )

    new_body = body[:match.start()] + replacement + body[match.end():]
    return text[:start] + new_body + text[end:], True


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--rustdesk-root",
        default=".",
        help="Root of the checked-out RustDesk source tree (default: .)",
    )
    args = parser.parse_args(argv)

    path = (
        pathlib.Path(args.rustdesk_root).resolve()
        / "flutter"
        / "lib"
        / "common"
        / "widgets"
        / "peer_card.dart"
    )
    if not path.is_file():
        print(f"Notice: {path} not found; skipping.", file=sys.stderr)
        return 0

    with open(path, "r", encoding="utf-8") as f:
        text = f.read()

    new_text, changed = apply_xoffline(text)

    if not changed:
        print(f"xoffline: {path} is already patched or skipped.")
        return 0

    with open(path, "w", encoding="utf-8") as f:
        f.write(new_text)
    print(f"xoffline: successfully patched offline indicator in {path}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
