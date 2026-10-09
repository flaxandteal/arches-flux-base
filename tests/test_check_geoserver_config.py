"""Tests for tools/check-geoserver-config.sh. Run by tests/check-geoserver-config.sh.

The check runs in projects' pre-commit and CI, not in geoserver, so it is tested
here in the tests image (POSIX sh and GNU grep, like a typical CI runner).
"""

import subprocess
from pathlib import Path

import pytest
import yaml

REPO = Path(__file__).resolve().parent.parent
CHECK = REPO / "tools" / "check-geoserver-config.sh"
CASES = yaml.safe_load((REPO / "tests/_resources/check-geoserver-config.yaml").read_text())["cases"]


def run_check(cwd, *args):
    return subprocess.run(["sh", str(CHECK), *args], cwd=cwd, capture_output=True, text=True)


def findings(stderr):
    """The reported lines: those between the header line and the first blank line."""
    lines = stderr.splitlines()
    if not lines or not lines[0].startswith("check-geoserver-config:"):
        return []
    found = []
    for line in lines[1:]:
        if not line.strip():
            break
        found.append(line.strip())
    return found


@pytest.mark.parametrize("name", CASES)
def test_case(name, tmp_path):
    case = CASES[name]
    for rel, content in case["files"].items():
        path = tmp_path / "geoserver" / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    result = run_check(tmp_path, "geoserver")

    assert result.returncode == case["expected"]["exit"], result.stderr
    assert sorted(findings(result.stderr)) == sorted(case["expected"].get("findings", []))


def test_values_are_never_printed(tmp_path):
    secret = "crypt2:VERY-SECRET-VALUE"
    (tmp_path / "geoserver").mkdir()
    (tmp_path / "geoserver/datastore.xml").write_text(f'<entry key="passwd">{secret}</entry>\n')

    result = run_check(tmp_path, "geoserver")

    assert result.returncode == 1
    assert "VERY-SECRET" not in result.stdout + result.stderr


def test_several_directories(tmp_path):
    for d in ("a", "b"):
        (tmp_path / d).mkdir()
        (tmp_path / d / "users.xml").write_text('<user password="plain:x"/>\n')

    result = run_check(tmp_path, "a", "b")

    assert result.returncode == 1
    assert sorted(findings(result.stderr)) == ["a/users.xml:1: plain:", "b/users.xml:1: plain:"]


def test_files_as_arguments(tmp_path):
    # How pre-commit calls it: the changed files, of any type.
    (tmp_path / "users.xml").write_text('<user password="plain:x"/>\n')
    (tmp_path / "values.yaml").write_text('password: "plain:x"\n')

    result = run_check(tmp_path, "users.xml", "values.yaml")

    assert result.returncode == 1
    assert findings(result.stderr) == ["users.xml:1: plain:"]


def test_missing_directory_is_an_error(tmp_path):
    result = run_check(tmp_path, "does-not-exist")
    assert result.returncode == 2 and "does-not-exist" in result.stderr


def test_no_arguments_is_a_usage_error(tmp_path):
    result = run_check(tmp_path)
    assert result.returncode == 2 and "usage:" in result.stderr
