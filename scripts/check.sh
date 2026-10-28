#!/usr/bin/env bash
# Быстрая проверка без полной сборки:
#  1. компилирует каждый твик под armv7 / iOS 6 системным clang против SDK из Theos;
#  2. проверяет, что все внешние символы есть в заглушках SDK для armv7 (scripts/linkcheck.py).
set -euo pipefail
: "${THEOS:?укажите путь к Theos в THEOS}"
SDK="${SDK:-$THEOS/sdks/iPhoneOS10.3.sdk}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

python3 "$ROOT/scripts/fix-sdk.py" "$SDK"

status=0
for file in "$ROOT"/tweaks/*/*.m; do
    # -fsjlj-exceptions: как clang 11 из тулчейна Theos для armv7
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

echo "--- линковка (заглушки armv7)"
python3 "$ROOT/scripts/linkcheck.py" "$SDK" "$THEOS/vendor/lib" "$OUT"/*.o || status=1
exit $status
