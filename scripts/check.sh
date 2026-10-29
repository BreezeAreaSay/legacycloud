#!/usr/bin/env bash
# Quick check without a full build:
#  1. compiles every tweak for armv7 / iOS 6 with the system clang against the SDK from Theos;
#  2. checks that every external symbol is in the SDK's armv7 stubs (scripts/linkcheck.py).
set -euo pipefail
: "${THEOS:?set THEOS to the path to Theos}"
SDK="${SDK:-$THEOS/sdks/iPhoneOS10.3.sdk}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

python3 "$ROOT/scripts/fix-sdk.py" "$SDK"

status=0
for file in "$ROOT"/tweaks/*/*.m; do
    # -fsjlj-exceptions: same as clang 11 from the Theos toolchain for armv7
    if clang -target armv7-apple-ios6.0 -isysroot "$SDK" -fobjc-arc -fsjlj-exceptions \
        -Wall -Wextra -Wno-unused-parameter -Werror \
        -I"$ROOT/shared" -I"$THEOS/vendor/include" -F"$THEOS/vendor/lib" \
        -c "$file" -o "$OUT/$(basename "$(dirname "$file")")__$(basename "$file").o"; then
        echo "ok   ${file#$ROOT/}"
    else
        echo "FAIL ${file#$ROOT/}"
        status=1
    fi
done

echo "--- link (armv7 stubs)"
python3 "$ROOT/scripts/linkcheck.py" "$SDK" "$THEOS/vendor/lib" "$OUT"/*.o || status=1
exit $status
