#!/usr/bin/env bash
# Собирает все пакеты iOS6Revive в ./debs.
# Нужен Theos (переменная THEOS) с iOS-тулчейном и SDK iPhoneOS10.3.
# IR_BUILD_NUMBER (номер сборки в CI) добавляется к версии, чтобы Cydia видела обновления.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
: "${THEOS:?укажите путь к Theos в переменной THEOS}"
OUT="$ROOT/debs"

# Заглушки theos/sdks потеряли 32-битные символы рантайма — возвращаем их (повторно ничего не меняет)
python3 "$ROOT/scripts/fix-sdk.py" "$THEOS/sdks/iPhoneOS10.3.sdk"

rm -rf "$OUT"
mkdir -p "$OUT"

version_of() {
    local base
    base="$(sed -n 's/^Version: //p' "$1")"
    echo "${base}${IR_BUILD_NUMBER:+-$IR_BUILD_NUMBER}"
}

for dir in "$ROOT"/tweaks/*/; do
    echo "==> $(basename "$dir")"
    make -C "$dir" clean package FINALPACKAGE=1 PACKAGE_VERSION="$(version_of "$dir/control")"
    cp "$dir"/packages/*.deb "$OUT/"
done

# Мета-пакеты без кода собираем напрямую
for dir in "$ROOT"/meta/*/; do
    echo "==> $(basename "$dir") (мета)"
    stage="$(mktemp -d)"
    mkdir -p "$stage/DEBIAN"
    sed "s/^Version: .*/Version: $(version_of "$dir/control")/" "$dir/control" > "$stage/DEBIAN/control"
    id="$(sed -n 's/^Package: //p' "$dir/control")"
    dpkg-deb --root-owner-group -Zgzip -b "$stage" "$OUT/${id}_$(version_of "$dir/control")_iphoneos-arm.deb"
    rm -rf "$stage"
done

ls -l "$OUT"
