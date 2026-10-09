"""Expand a YAML file of test cases into one folder per case.

    python expand_cases.py <cases.yaml> <output dir>

Shell-based test runners cannot read YAML, so this writes each case out as plain
files they can mount and diff:

    <output dir>/<case>/overlay/<path>      from overlay:
    <output dir>/<case>/image/<path>        from image:
    <output dir>/<case>/secrets/<key>       from secrets:
    <output dir>/<case>/expected/<path>     from expected.files:
    <output dir>/<case>/expected-exit       from expected.exit
    <output dir>/<case>/expected-stderr     from expected.stderr

A part that is absent in the YAML is absent on disk. Contents are written exactly,
with no newline added or translated.
"""

import sys
from pathlib import Path

import yaml

CASE_KEYS = {"overlay", "image", "secrets", "expected"}
EXPECTED_KEYS = {"exit", "stderr", "files"}


def write(path, content):
    if not isinstance(content, str):
        sys.exit(f"{path}: content must be a string, got {type(content).__name__}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content.encode())


def write_tree(root, files):
    for rel, content in files.items():
        if rel.startswith("/") or ".." in Path(rel).parts:
            sys.exit(f"{root}: path {rel!r} must stay inside the folder")
        write(root / rel, content)


def expand(cases_file, out_dir):
    cases = yaml.safe_load(Path(cases_file).read_text())["cases"]
    for name, case in cases.items():
        unknown = set(case) - CASE_KEYS
        if unknown:
            sys.exit(f"{name}: unknown keys {sorted(unknown)}")
        expected = case.get("expected") or {}
        unknown = set(expected) - EXPECTED_KEYS
        if unknown:
            sys.exit(f"{name}: unknown expected keys {sorted(unknown)}")
        if "exit" not in expected:
            sys.exit(f"{name}: expected.exit is required")

        root = Path(out_dir) / name
        root.mkdir(parents=True)
        for part in ("overlay", "image", "secrets"):
            if part in case:
                write_tree(root / part, case[part])
        if "files" in expected:
            write_tree(root / "expected", expected["files"])
        write(root / "expected-exit", f"{expected['exit']}\n")
        if "stderr" in expected:
            write(root / "expected-stderr", expected["stderr"])


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    expand(sys.argv[1], sys.argv[2])
