#!/usr/bin/env python3
"""Make or check a GeoServer `digest1:` password digest, offline.

Usage
-----
Make a digest. The password is asked for twice and is not echoed:

    $ python3 tools/geoserver_digest.py
    Password:
    Again:
    digest1:zsGEMDmXrxhyU0I5T3+7jr183iuJS7XEecQaFEeyEr++TvhBRqZIpj7EkdKwX/3m

Check a password against a digest, e.g. to confirm a digest in the Secret is for
the password you think it is. Exits 0 if it matches, 1 if not:

    $ python3 tools/geoserver_digest.py --check 'digest1:zsGEMDmX...dKwX/3m'
    Password:
    matches

Read the password from stdin instead of prompting, for scripts or a password
manager's CLI. Only the first line is used. Avoid typing the password itself on
the command line, where it lands in shell history:

    $ pass show geoserver/admin | python3 tools/geoserver_digest.py --stdin
    digest1:...
    $ pass show geoserver/admin | python3 tools/geoserver_digest.py --stdin --check 'digest1:...'
    matches

The digest goes in a geoserver users.xml `password` attribute. In arches-flux-base
projects it goes in the geoserver-overlay-secrets Secret instead, and users.xml
refers to it with a @@secret:KEY@@ placeholder (see the README).

Format, as GeoServer's digestPasswordEncoder writes it (via Jasypt: SHA-256,
100,000 iterations, 16-byte random salt):

    digest1:<base64 of salt (16 bytes) + hash (32 bytes)>

where the hash is SHA-256 over salt + password, then rehashed 99,999 more times.
The salt travels inside the digest and no key is involved, so a digest made here
works in any GeoServer instance. Standard library only; Python 3.8+.
"""

import argparse
import base64
import getpass
import hashlib
import hmac
import os
import sys

PREFIX = "digest1:"
ITERATIONS = 100_000
SALT_BYTES = 16
HASH_BYTES = 32


def _hash(password, salt):
    digest = hashlib.sha256(salt + password.encode("utf-8")).digest()
    for _ in range(ITERATIONS - 1):
        digest = hashlib.sha256(digest).digest()
    return digest


def make_digest(password, salt=None):
    """Return a digest1 value for password, with a random salt unless one is given."""
    if salt is None:
        salt = os.urandom(SALT_BYTES)
    if len(salt) != SALT_BYTES:
        raise ValueError(f"salt must be {SALT_BYTES} bytes")
    return PREFIX + base64.b64encode(salt + _hash(password, salt)).decode("ascii")


def check_digest(password, digest):
    """True if password matches digest. Raises ValueError if digest is malformed."""
    if not digest.startswith(PREFIX):
        raise ValueError(f"not a {PREFIX} digest")
    try:
        raw = base64.b64decode(digest[len(PREFIX):], validate=True)
    except ValueError:
        raise ValueError("digest is not valid base64") from None
    if len(raw) != SALT_BYTES + HASH_BYTES:
        raise ValueError(f"digest decodes to {len(raw)} bytes, expected {SALT_BYTES + HASH_BYTES}")
    salt, expected = raw[:SALT_BYTES], raw[SALT_BYTES:]
    return hmac.compare_digest(_hash(password, salt), expected)


def _read_password(from_stdin, confirm):
    if from_stdin:
        password = sys.stdin.readline().rstrip("\r\n")
    else:
        password = getpass.getpass("Password: ")
        if confirm and getpass.getpass("Again: ") != password:
            sys.exit("Passwords do not match.")
    if not password:
        sys.exit("Empty password.")
    return password


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Make or check a GeoServer digest1 password digest, offline.")
    parser.add_argument("--check", metavar="DIGEST",
                        help="check the password against DIGEST instead of making one; "
                             "exits 0 if it matches, 1 if not")
    parser.add_argument("--stdin", action="store_true",
                        help="read the password from the first line of stdin, "
                             "not an interactive prompt")
    args = parser.parse_args(argv)

    password = _read_password(args.stdin, confirm=args.check is None)
    if args.check is None:
        print(make_digest(password))
        return 0
    try:
        matches = check_digest(password, args.check)
    except ValueError as e:
        sys.exit(f"Invalid digest: {e}")
    print("matches" if matches else "does not match")
    return 0 if matches else 1


if __name__ == "__main__":
    sys.exit(main())
