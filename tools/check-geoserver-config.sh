#!/bin/sh
# Fail if committed geoserver config holds a password value.
#
# Usage
# -----
#   arches-flux-base/tools/check-geoserver-config.sh PATH [PATH...]
#
# Each PATH is a directory (searched recursively) or a file, so it works both in
# CI over whole trees and as a pre-commit hook, which passes the changed files:
#
#   arches-flux-base/tools/check-geoserver-config.sh clusters/*/*/geoserver
#   arches-flux-base/tools/check-geoserver-config.sh path/to/users.xml
#
# Files other than *.xml and *.properties are skipped, including ones named
# directly.
#
# Recommended pre-commit hook, in the project's .pre-commit-config.yaml. A local
# hook runs this script from the arches-flux-base submodule, so it is always the
# version the project has pinned (needs the submodule checked out):
#
#   repos:
#     - repo: local
#       hooks:
#         - id: check-geoserver-config
#           name: no password values in geoserver config
#           entry: arches-flux-base/tools/check-geoserver-config.sh
#           language: script
#           files: ^clusters/[^/]+/[^/]+/geoserver/.*\.(xml|properties)$
#
# Hooks only run where someone ran `pre-commit install`, and --no-verify skips
# them, so also run the check over the whole tree in CI.
#
# Exits 0 if clean, 1 if anything was found, 2 on a usage or read error.
#
# What it looks for, in *.xml and *.properties files: a value starting with one of
# geoserver's password prefixes, as an attribute value, element text or property
# value.
#
#   crypt1: crypt2:  Encrypted with the instance's keystore. Each arches-flux-base
#                    geoserver pod makes a fresh keystore at startup, so these
#                    can never be decrypted again. Datastore credentials belong in
#                    a JNDI resource or Kubernetes Secret instead.
#   plain:           A plaintext password.
#   digest1:         A password digest. Safe to commit only sops-encrypted: move
#                    it into the geoserver-overlay-secrets Secret and refer to it
#                    with a @@secret:KEY@@ placeholder (see the README).
#
# Only file, line and prefix are reported, never the value, so nothing secret ends
# up in CI logs.
set -u

if [ $# -eq 0 ]; then
  echo "usage: $0 PATH [PATH...]" >&2
  exit 2
fi

# A prefix counts when it starts a value: after a quote (attribute), > (element
# text) or = (properties), and followed by at least one value character.
pattern='["=>](crypt1|crypt2|plain|digest1):[^"<[:space:]]'

# -o prints only the match: file:line:"crypt2:x. The sed below drops the one value
# character and the delimiter, leaving file:line: crypt2:
found=$(grep -rEnIo --include='*.xml' --include='*.properties' "$pattern" "$@")
status=$?
if [ "$status" -eq 2 ]; then
  exit 2    # grep has already said what it could not read
fi
if [ "$status" -eq 1 ]; then
  exit 0    # nothing found
fi

echo "check-geoserver-config: password values in committed geoserver config:" >&2
printf '%s\n' "$found" | sed 's/.$//; s/:["=>]\([a-z0-9]*:\)$/: \1/; s/^/  /' >&2
cat >&2 <<'EOF'

  crypt1:/crypt2: are keystore-bound and cannot be decrypted by another pod: use
  JNDI or a Kubernetes Secret for datastore credentials. plain: is a plaintext
  password. digest1: belongs in the geoserver-overlay-secrets Secret, referred to
  with a @@secret:KEY@@ placeholder. See the arches-flux-base README.
EOF
exit 1
