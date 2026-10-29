#!/usr/bin/env bash
# Собирает все пакеты Skeuo4Ever в ./debs.
# Нужен Theos (переменная THEOS) с iOS-тулчейном и SDK iPhoneOS10.3.
# Версия пакета — поле Version в его control. Чтобы выпустить новую версию, подними его.
# Рядом с пакетами кладётся debs/sources.json: отпечатки исходников, по ним публикация
# отличает пересборку того же кода от изменений (см. scripts/make-repo.py).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
: "${THEOS:?укажите путь к Theos в переменной THEOS}"
OUT="$ROOT/debs"

# Заглушки theos/sdks потеряли 32-битные символы рантайма — возвращаем их (повторно ничего не меняет)
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

# Мета-пакеты без кода собираем напрямую
for dir in "$ROOT"/meta/*/; do
    echo "==> $(basename "$dir") (мета)"
    stage="$(mktemp -d)"
    mkdir -p "$stage/DEBIAN"
    cp "$dir/control" "$stage/DEBIAN/control"
    id="$(sed -n 's/^Package: //p' "$dir/control")"
    dpkg-deb --root-owner-group -Zgzip -b "$stage" "$OUT/${id}_$(version_of "$dir/control")_iphoneos-arm.deb"
    rm -rf "$stage"
done

python3 "$ROOT/scripts/sources.py" > "$OUT/sources.json"
ls -l "$OUT"
