#!/bin/sh
# Run every test suite in tests/. Needs only docker.
#
#   tests/run.sh
#   GEOSERVER_VERSION=2.28.2 tests/run.sh    # test against another geoserver
set -eu
cd "$(dirname "$0")"
sh ./fill-overlay-secrets.sh
sh ./geoserver-digest.sh
