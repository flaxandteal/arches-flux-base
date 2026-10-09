"""Unit tests for tools/geoserver_digest.py. Run by tests/geoserver-digest.sh.

Whether GeoServer itself accepts the digests is tested there too, by logging in to
a real geoserver.
"""

import base64
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

REPO = Path(__file__).resolve().parent.parent
TOOL = REPO / "tools" / "geoserver_digest.py"
sys.path.insert(0, str(TOOL.parent))

import geoserver_digest as gd  # noqa: E402

VECTORS = yaml.safe_load((REPO / "tests/_resources/geoserver-digest.yaml").read_text())["vectors"]


@pytest.mark.parametrize("vector", VECTORS, ids=[v["source"] for v in VECTORS])
def test_accepts_digests_made_by_geoserver(vector):
    assert gd.check_digest(vector["password"], vector["digest"])


@pytest.mark.parametrize("vector", VECTORS, ids=[v["source"] for v in VECTORS])
def test_rejects_wrong_password_for_digests_made_by_geoserver(vector):
    assert not gd.check_digest(vector["password"] + "x", vector["digest"])


def test_reproduces_a_geoserver_digest_given_its_salt():
    # The same salt and password must give exactly GeoServer's bytes, not merely
    # something check_digest accepts.
    for vector in VECTORS:
        salt = base64.b64decode(vector["digest"][len("digest1:"):])[:16]
        assert gd.make_digest(vector["password"], salt) == vector["digest"]


def test_made_digest_has_geoserver_shape():
    digest = gd.make_digest("s3cret")
    assert digest.startswith("digest1:")
    assert len(base64.b64decode(digest[len("digest1:"):])) == 48
    assert gd.check_digest("s3cret", digest)


def test_salt_is_random():
    assert gd.make_digest("same") != gd.make_digest("same")


def test_non_ascii_password_round_trips():
    digest = gd.make_digest("pāua-kōwhai")
    assert gd.check_digest("pāua-kōwhai", digest)
    assert not gd.check_digest("paua-kowhai", digest)


@pytest.mark.parametrize("bad", [
    "crypt2:abc",                    # wrong encoder
    "digest1:not base64!",           # not base64
    "digest1:" + base64.b64encode(b"short").decode(),  # wrong length
])
def test_malformed_digest_is_an_error_not_a_mismatch(bad):
    with pytest.raises(ValueError):
        gd.check_digest("anything", bad)


def run_tool(*args, stdin):
    return subprocess.run([sys.executable, str(TOOL), *args], input=stdin,
                          capture_output=True, text=True)


def test_cli_makes_a_digest_from_stdin():
    result = run_tool("--stdin", stdin="s3cret\n")
    assert result.returncode == 0, result.stderr
    assert gd.check_digest("s3cret", result.stdout.strip())


def test_cli_check_matches():
    vector = VECTORS[0]
    result = run_tool("--stdin", "--check", vector["digest"], stdin=vector["password"] + "\n")
    assert (result.returncode, result.stdout) == (0, "matches\n")


def test_cli_check_does_not_match():
    result = run_tool("--stdin", "--check", VECTORS[0]["digest"], stdin="wrong\n")
    assert (result.returncode, result.stdout) == (1, "does not match\n")


def test_cli_rejects_empty_password():
    result = run_tool("--stdin", stdin="\n")
    assert result.returncode != 0 and "Empty password" in result.stderr


def test_cli_reports_malformed_digest():
    result = run_tool("--stdin", "--check", "crypt2:abc", stdin="x\n")
    assert result.returncode != 0 and "Invalid digest" in result.stderr
