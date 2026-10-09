#!/bin/sh
# Tests for tools/check-geoserver-config.sh (tests/test_check_geoserver_config.py,
# cases in tests/_resources/check-geoserver-config.yaml).
#
# The check runs in projects' pre-commit and CI, not in geoserver, so unlike the
# other suites it is tested in the tests image only, and GEOSERVER_VERSION does not
# apply.
#
#   tests/check-geoserver-config.sh
#
# Needs docker. tests/run.sh runs this along with the other suites.
set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
tests_image=$(docker build -q "$repo/tests")
docker run --rm --user "$(id -u):$(id -g)" -e PYTHONDONTWRITEBYTECODE=1 \
  -v "$repo:/repo:ro" "$tests_image" \
  python -m pytest -q -p no:cacheprovider tests/test_check_geoserver_config.py
