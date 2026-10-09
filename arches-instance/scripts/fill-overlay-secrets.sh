#!/bin/sh
# Fill @@secret:KEY@@ placeholders in the project's geoserver overlay with the value
# of key KEY in the geoserver-overlay-secrets Secret. This keeps values such as
# password digests out of the configMap, while the files that hold them (users.xml)
# stay readable in git.
#
# Runs as an init container after seed-data-dir, on the copies in the data dir.
#
#   No placeholders                    -> nothing to do, exit 0
#   A placeholder with no matching key -> exit 1, listing what is unfilled, so the
#                                         pod stops here rather than geoserver
#                                         starting with a broken file
#
# Values are inserted verbatim, so they must already be valid where they land
# (XML-escaped, no line breaks). digest1 password digests always are.
#
# Never use dollar-brace expansions in this file. Flux postBuild substitution runs
# over the configMap that ships it and would rewrite them. (Opting the configMap out
# with the substitute: disabled annotation would also skip its namespace variable.)
# tests/fill-overlay-secrets.sh enforces this.
set -eu

OVERLAY=/config-overlay
DATA=/opt/geoserver_data
SECRETS=/config-secrets

# Only files that came from the overlay are filled; files shipped in the image are
# never touched. The list comes from the overlay mount itself: -L follows kubelet's
# symlinks, and the prune skips its dot-prefixed `..data` bookkeeping directories
# (see seed-data-dir). %P prints each path relative to the overlay, which is also
# where seed-data-dir copied it to in the data dir.
files=$(find -L "$OVERLAY" -path "$OVERLAY/..*" -prune -o -type f -printf "$DATA/%P\n")
if [ -z "$files" ]; then
  exit 0
fi

# Each key of the Secret is a file in the mount (again skipping `..data`).
for keyfile in "$SECRETS"/*; do
  [ -f "$keyfile" ] || continue    # the glob stays literal when the mount is empty
  key=$(basename "$keyfile")
  value=$(cat "$keyfile")          # $(...) drops trailing newlines
  if [ "$(printf '%s' "$value" | wc -l)" -ne 0 ]; then
    echo "fill-overlay-secrets: key '$key' contains a line break" >&2
    exit 1
  fi
  # Escape what is special to sed: `.` in the key (the only regex metacharacter a
  # Secret key can contain), and `&`, `\` and the `|` delimiter in the value.
  key_re=$(printf '%s' "$key" | sed 's/\./\\./g')
  value_esc=$(printf '%s' "$value" | sed 's/[&|\\]/\\&/g')
  # $files is split on purpose: one argument per file. Overlay paths come from
  # configMap item paths, which contain no spaces.
  # shellcheck disable=SC2086
  sed -i "s|@@secret:$key_re@@|$value_esc|g" $files
done

# Anything still unfilled has no matching key, or a key name the Secret could not
# hold (keys may only use -._a-zA-Z0-9). The pattern runs to the next quote, angle
# bracket or whitespace rather than the next @, so a placeholder like
# @@secret:jo@example.org@@ is reported whole instead of slipping through.
# shellcheck disable=SC2086
unfilled=$(grep -Ho '@@secret:[^"<>[:space:]]*' $files | sort -u || true)
if [ -n "$unfilled" ]; then
  echo "fill-overlay-secrets: no key in secret geoserver-overlay-secrets for:" >&2
  echo "$unfilled" | sed "s|^$DATA/|  |" >&2
  exit 1
fi
