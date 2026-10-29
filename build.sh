#!/usr/bin/env bash
# Builds all Skeuo4Ever packages into ./debs.
# Requires Theos (the THEOS variable) with an iOS toolchain and the iPhoneOS10.3 SDK.
# A package's version is the Version field in its control file. To release a new version, bump it.
# debs/sources.json is written next to the packages: source fingerprints that let publishing
# tell a rebuild of the same code from actual changes (see scripts/make-repo.py).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
: "${THEOS:?set the THEOS variable to the path to Theos}"
OUT="$ROOT/debs"

# The theos/sdks stubs lost the 32-bit runtime symbols: put them back (running it again changes nothing)
python3 "$ROOT/scripts/fix-sdk.py" "$THEOS/sdks/iPhoneOS10.3.sdk"

rm -rf "$OUT"
mkdir -p "$OUT"

version_of() {
    sed -n 's/^Version: //p' "$1"
}

for dir in "$ROOT"/tweaks/*/; do
    echo "==> $(basename "$dir")"
    make -C "$dir" clean package FINALPACKAGE=1 PACKAGE_VERSION="$(version_of "$dir/control")"
    cp "$dir"/packages/*.deb "$OUT/"
done

# Meta packages have no code, so they are built directly
for dir in "$ROOT"/meta/*/; do
    echo "==> $(basename "$dir") (meta)"
    stage="$(mktemp -d)"
    mkdir -p "$stage/DEBIAN"
    cp "$dir/control" "$stage/DEBIAN/control"
    id="$(sed -n 's/^Package: //p' "$dir/control")"
    dpkg-deb --root-owner-group -Zgzip -b "$stage" "$OUT/${id}_$(version_of "$dir/control")_iphoneos-arm.deb"
    rm -rf "$stage"
done

python3 "$ROOT/scripts/sources.py" > "$OUT/sources.json"
ls -l "$OUT"
