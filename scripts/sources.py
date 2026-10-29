#!/usr/bin/env python3
"""Prints JSON {package: source fingerprint}.

The armv7 build is not byte-for-byte reproducible (code signature, timestamps in the archive), so
publishing compares not the .deb but the sources it was built from:
  a tweak: its directory, shared/, common.mk and scripts/fix-sdk.py;
  a meta package: its directory.
Only files tracked by git count, so that build output is not picked up.
"""

import hashlib
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COMMON = ["shared", "common.mk", "scripts/fix-sdk.py"]


def tracked(paths):
    out = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z", "--", *paths],
                         check=True, capture_output=True).stdout
    return sorted(p for p in out.decode().split("\0") if p)


def fingerprint(paths):
    digest = hashlib.sha256()
    for path in tracked(paths):
        digest.update(path.encode() + b"\0" + (ROOT / path).read_bytes() + b"\0")
    return digest.hexdigest()


def package_id(control: Path) -> str:
    for line in control.read_text().splitlines():
        if line.startswith("Package: "):
            return line[len("Package: "):]
    raise SystemExit(f"no Package in {control}")


def main() -> None:
    result = {}
    for control in sorted(ROOT.glob("tweaks/*/control")):
        result[package_id(control)] = fingerprint([str(control.parent.relative_to(ROOT)), *COMMON])
    for control in sorted(ROOT.glob("meta/*/control")):
        result[package_id(control)] = fingerprint([str(control.parent.relative_to(ROOT))])
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
