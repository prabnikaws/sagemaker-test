#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""Strip all outputs and execution counts from Jupyter notebooks.

Zero dependencies — operates on raw JSON. Unconditionally strips ALL
outputs with no opt-out mechanism.

Usage:
    strip_notebook_outputs.py <file.ipynb> [file2.ipynb ...]
    strip_notebook_outputs.py --check <file.ipynb> [...]   (exit 1 if outputs found)
    cat file.ipynb | strip_notebook_outputs.py              (stdin/stdout)
"""
import json
import sys

STRIP_CELL_METADATA_KEYS = [
    "collapsed",
    "scrolled",
    "ExecuteTime",
    "execution",
    "heading_collapsed",
    "hidden",
]


def strip_notebook(nb):
    for cell in nb.get("cells", []):
        if "outputs" in cell:
            cell["outputs"] = []
        if "execution_count" in cell:
            cell["execution_count"] = None
        if "metadata" in cell:
            for key in STRIP_CELL_METADATA_KEYS:
                cell["metadata"].pop(key, None)
    nb.get("metadata", {}).pop("signature", None)
    nb.get("metadata", {}).pop("widgets", None)
    return nb


def has_outputs(nb):
    for cell in nb.get("cells", []):
        if cell.get("outputs"):
            return True
        if cell.get("execution_count") is not None:
            return True
    return False


def main():
    check_mode = "--check" in sys.argv or "--verify" in sys.argv
    files = [f for f in sys.argv[1:] if not f.startswith("--")]

    if not files and not sys.stdin.isatty():
        nb = json.load(sys.stdin)
        if check_mode:
            sys.exit(1 if has_outputs(nb) else 0)
        json.dump(strip_notebook(nb), sys.stdout, indent=1, ensure_ascii=False)
        sys.stdout.write("\n")
        return

    failed = False
    for filepath in files:
        if not filepath.endswith(".ipynb"):
            continue
        with open(filepath, "r", encoding="utf-8") as f:
            nb = json.load(f)
        if check_mode:
            if has_outputs(nb):
                print(f"FAIL: {filepath} contains outputs", file=sys.stderr)
                failed = True
        else:
            with open(filepath, "w", encoding="utf-8") as f:
                json.dump(strip_notebook(nb), f, indent=1, ensure_ascii=False)
                f.write("\n")

    if check_mode and failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
