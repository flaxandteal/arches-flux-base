#!/bin/sh
# Tests for arches-instance/scripts/fill-overlay-secrets.sh.
#
# Cases are in tests/_resources/fill-overlay-secrets.yaml (the format is described
# at the top of that file). They are expanded into folders in the tests image, then
# run inside the geoserver image the script is deployed with.
#
#   tests/fill-overlay-secrets.sh                  # default geoserver version
#   GEOSERVER_VERSION=2.28.2 tests/fill-overlay-secrets.sh
#
# Needs docker. tests/run.sh runs this along with the other suites.
set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
script=arches-instance/scripts/fill-overlay-secrets.sh
version=${GEOSERVER_VERSION:-2.28.0}

# Flux postBuild substitution would rewrite dollar-brace expansions in the script.
# shellcheck disable=SC2016  # the pattern is meant literally
if grep -n '\${' "$repo/$script"; then
  echo "FAIL: $script contains a dollar-brace expansion (see the note in the script)" >&2
  exit 1
fi

cases=$(mktemp -d)
trap 'rm -rf "$cases"' EXIT
tests_image=$(docker build -q "$repo/tests")
docker run --rm --user "$(id -u):$(id -g)" \
  -v "$repo:/repo:ro" -v "$cases:/cases" "$tests_image" \
  python tests/expand_cases.py tests/_resources/fill-overlay-secrets.yaml /cases

docker run --rm -i --entrypoint /bin/sh \
  -v "$repo/$script:/scripts/fill-overlay-secrets.sh:ro" \
  -v "$cases:/cases:ro" \
  "docker.osgeo.org/geoserver:$version" <<'EOF'
set -u

# Mount a folder the way kubelet mounts a configMap or Secret: the real files sit in
# a timestamped directory, `..data` points at it, and each top-level entry is a
# symlink through `..data`. A missing folder gives an empty mount.
mount_like_kubelet() {  # mount_like_kubelet <source folder> <mount point>
  rm -rf "$2"
  mkdir -p "$2"
  [ -d "$1" ] || return 0
  mkdir "$2/..2026_01_01_00_00_00.000000001"
  cp -r "$1/." "$2/..2026_01_01_00_00_00.000000001/"
  ln -s ..2026_01_01_00_00_00.000000001 "$2/..data"
  for entry in $(ls -A "$1"); do ln -s "..data/$entry" "$2/$entry"; done
}

failures=0
for case in /cases/*/; do
  case=${case%/}
  name=$(basename "$case")
  problems=""

  # Data dir as seed-data-dir leaves it: files from the image, overlay copied on top.
  rm -rf /opt/geoserver_data
  mkdir -p /opt/geoserver_data
  if [ -d "$case/image" ]; then cp -r "$case/image/." /opt/geoserver_data/; fi
  mount_like_kubelet "$case/overlay" /config-overlay
  mount_like_kubelet "$case/secrets" /config-secrets
  set -- /config-overlay/*
  if [ -e "$1" ]; then cp -rL "$@" /opt/geoserver_data/; fi

  sh /scripts/fill-overlay-secrets.sh >/tmp/stdout 2>/tmp/stderr
  rc=$?

  expected_rc=$(cat "$case/expected-exit")
  if [ "$rc" != "$expected_rc" ]; then
    problems="$problems
  exit code $rc, expected $expected_rc"
  fi
  if [ -f "$case/expected-stderr" ] && ! diff "$case/expected-stderr" /tmp/stderr >/tmp/diff; then
    problems="$problems
  stderr differs (< expected, > actual):
$(sed 's/^/    /' /tmp/diff)"
  fi
  if [ -d "$case/expected" ] && ! diff -r "$case/expected" /opt/geoserver_data >/tmp/diff; then
    problems="$problems
  data dir differs from expected/:
$(sed 's/^/    /' /tmp/diff)"
  fi

  if [ -z "$problems" ]; then
    echo "ok:   $name"
  else
    echo "FAIL: $name$problems"
    if [ -s /tmp/stderr ]; then echo "  stderr was:"; sed 's/^/    /' /tmp/stderr; fi
    failures=$((failures + 1))
  fi
done

if [ "$failures" -ne 0 ]; then echo "$failures case(s) failed"; exit 1; fi
echo "all passed"
EOF
