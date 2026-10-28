#!/usr/bin/env bash
# Быстрая проверка без полной сборки: компилирует каждый твик под armv7 / iOS 6
# системным clang против SDK из Theos. Ничего не линкует.
set -euo pipefail
: "${THEOS:?укажите путь к Theos в THEOS}"
SDK="${SDK:-$THEOS/sdks/iPhoneOS9.3.sdk}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
status=0
for file in "$ROOT"/tweaks/*/*.m; do
    if clang -target armv7-apple-ios6.0 -isysroot "$SDK" -fobjc-arc \
        -Wall -Wextra -Wno-unused-parameter -Werror \
        -I"$ROOT/shared" -I"$THEOS/vendor/include" -F"$THEOS/vendor/lib" \
        -c "$file" -o "$OUT/$(basename "$file").o"; then
        echo "ok   ${file#$ROOT/}"
    else
        echo "FAIL ${file#$ROOT/}"
        status=1
    fi
done
exit $status
