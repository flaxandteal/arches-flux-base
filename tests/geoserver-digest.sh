#!/bin/sh
# Tests for tools/geoserver_digest.py.
#
#  1. Unit tests (tests/test_geoserver_digest.py) in the tests image, including
#     digests made by GeoServer itself (tests/_resources/geoserver-digest.yaml).
#  2. End to end: make digests with the tool, boot geoserver with them in
#     users.xml, and check logins over REST. This is what catches a geoserver
#     release that stops accepting digest1, so CI runs it for several versions.
#
# The two check opposite directions. The unit tests show the tool reads digests
# geoserver made (geoserver -> tool), but only against digests collected once. The
# tool itself runs in the tests image; geoserver is here as the judge of what it
# produces (tool -> geoserver), and only a real login can say whether a given
# release accepts it. That is also what showed geoserver encodes non-ASCII
# passwords as UTF-8, the same as the tool.
#
#   tests/geoserver-digest.sh
#   GEOSERVER_VERSION=3.0.1 tests/geoserver-digest.sh
#
# Needs docker. tests/run.sh runs this along with the other suites.
set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
version=${GEOSERVER_VERSION:-2.28.0}
tests_image=$(docker build -q "$repo/tests")

python_in_tests_image() {
  docker run --rm -i --user "$(id -u):$(id -g)" -e PYTHONDONTWRITEBYTECODE=1 \
    -v "$repo:/repo:ro" "$tests_image" "$@"
}

echo "-- unit tests"
python_in_tests_image python -m pytest -q -p no:cacheprovider tests/test_geoserver_digest.py

echo "-- end to end, geoserver $version"
# One ASCII and one non-ASCII password, to check geoserver encodes passwords the
# same way the tool does (UTF-8).
ascii_pw='S3cret-pw'
utf8_pw='pāua-kōwhai'
ascii_digest=$(echo "$ascii_pw" | python_in_tests_image python tools/geoserver_digest.py --stdin)
utf8_digest=$(echo "$utf8_pw" | python_in_tests_image python tools/geoserver_digest.py --stdin)

work=$(mktemp -d)
container=geoserver-digest-test-$$
trap 'docker rm -f "$container" >/dev/null 2>&1; rm -rf "$work"' EXIT
cat > "$work/users.xml" <<EOF
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<userRegistry xmlns="http://www.geoserver.org/security/users" version="1.0">
    <users>
        <user enabled="true" name="admin" password="$ascii_digest"/>
        <user enabled="true" name="admin2" password="$utf8_digest"/>
    </users>
    <groups/>
</userRegistry>
EOF

# Start from the image's own data dir, swap in our users.xml, and give admin2 the
# ADMIN role too so both users can call the REST API.
docker run -d --name "$container" -e SKIP_DEMO_DATA=true \
  -v "$work/users.xml:/tmp/users.xml:ro" --entrypoint /bin/sh \
  "docker.osgeo.org/geoserver:$version" -c '
    set -e
    mkdir -p /opt/geoserver_data
    cp -a /usr/local/tomcat/webapps/geoserver/data/. /opt/geoserver_data/
    cp /tmp/users.xml /opt/geoserver_data/security/usergroup/default/users.xml
    sed -i "s|</userList>|<userRoles username=\"admin2\"><roleRef roleID=\"ADMIN\"/></userRoles></userList>|" \
      /opt/geoserver_data/security/role/default/roles.xml
    exec /opt/startup.sh' >/dev/null

status() {  # status <user> <password>: HTTP status of an authenticated REST call
  docker exec "$container" curl -s -o /dev/null -w '%{http_code}' -u "$1:$2" \
    http://localhost:8080/geoserver/rest/about/version.json
}

# Wait on a page that needs no login, so a digest geoserver rejects shows up below
# as a failed check rather than as a slow start. Same URL as the Deployment's
# probes (/geoserver/web/ itself answers with a redirect).
ready_url=http://localhost:8080/geoserver/web/wicket/resource/org.geoserver.web.GeoServerBasePage/img/logo.png
printf 'waiting for geoserver'
tries=0
until [ "$(docker exec "$container" curl -s -o /dev/null -w '%{http_code}' "$ready_url" \
          2>/dev/null || true)" = 200 ]; do
  tries=$((tries + 1))
  if [ "$tries" -gt 90 ]; then
    echo; echo "FAIL: geoserver did not start within 3 minutes"
    docker logs "$container" 2>&1 | tail -30
    exit 1
  fi
  printf .
  sleep 2
done
echo

failures=0
expect() {  # expect <description> <expected status> <user> <password>
  got=$(status "$3" "$4")
  if [ "$got" = "$2" ]; then echo "ok:   $1"; else
    echo "FAIL: $1: HTTP $got, expected $2"; failures=$((failures + 1)); fi
}
expect "ASCII password, digest from the tool" 200 admin "$ascii_pw"
expect "non-ASCII password, digest from the tool" 200 admin2 "$utf8_pw"
expect "wrong password rejected" 401 admin "wrong"
expect "geoserver's default password rejected" 401 admin geoserver

if [ "$failures" -ne 0 ]; then echo "$failures check(s) failed"; exit 1; fi
echo "all passed"
