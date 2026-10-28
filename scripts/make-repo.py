#!/usr/bin/env python3
"""Обновляет Cydia-источник iOS6Revive в каталоге SITE (рабочая копия ветки gh-pages).

Использование: scripts/make-repo.py [DEBS] [SITE]   (по умолчанию debs/ и _site/)
IR_REPO_URL — адрес источника, нужен для полей Depiction, Icon и Homepage.

Как в sqmrak/sqmrakdev, опубликованное не переписывается:
  * SITE/published.json помнит каждую выпущенную версию: файл, sha256 и отпечаток исходников
    (DEBS/sources.json, его пишет build.sh);
  * версия уже выпущена и исходники те же — остаётся опубликованный файл, новая сборка
    отбрасывается (сборка не воспроизводима побайтно, а обновлений-пустышек в Cydia быть не должно);
  * исходники изменились, а версия та же — ошибка: подними Version в control;
  * старые версии остаются в источнике, к ним можно откатиться.

Cydia на iOS 6 пропускает Description через перекодировку APT в ASCII, и кириллица
превращается в «?». Поэтому в Description — короткая строка по-английски, а русское описание —
на странице пакета (поле Depiction): её Cydia открывает в браузере, где UTF-8 работает.
Тексты страниц — depictions/<пакет>.txt, иконки — icons/<пакет>.png.
"""

import bz2
import datetime
import gzip
import hashlib
import html
import json
import os
import shutil
import subprocess
import sys
from email.utils import formatdate
from functools import cmp_to_key
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEBS = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "debs"
SITE = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "_site"
REPO_URL = os.environ.get("IR_REPO_URL", "").rstrip("/")
GENERATED = ["Packages", "Packages.gz", "Packages.bz2", "Release", "depictions"]

RELEASE_HEADER = """Origin: iOS6Revive
Label: iOS6Revive
Suite: stable
Version: 1.0
Codename: ios6revive
Architectures: iphoneos-arm
Components: main
Description: New iOS features in iOS 6 style
"""

DEPICTION = """<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
<title>{name}</title>
<link rel="stylesheet" href="../../style.css">
</head>
<body>
<div class="page depiction">
<div class="hero" id="hero">{icon}<h1>{name}</h1></div>
<script>
  // В Cydia заголовок с иконкой уже есть
  if (navigator.userAgent.indexOf("Cydia") >= 0) document.getElementById("hero").style.display = "none";
</script>
{body}
<h2>Подробности</h2>
<ul class="group">
<li class="row">Совместимость<em>iOS 6.0 – 6.1.x</em></li>
<li class="row">Разработчик<em>{author}</em></li>
</ul>
<h2>Версии</h2>
<ul class="group">
{versions}
</ul>
</div>
</body>
</html>
"""


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def control_of(deb: Path) -> str:
    return subprocess.run(["dpkg-deb", "-f", str(deb)], check=True, capture_output=True).stdout.decode("utf-8").strip()


def field(control: str, name: str) -> str:
    for line in control.split("\n"):
        if line.startswith(name + ": "):
            return line[len(name) + 2:]
    return ""


def version_cmp(a: str, b: str) -> int:
    if a == b:
        return 0
    lower = subprocess.run(["dpkg", "--compare-versions", a, "lt", b]).returncode == 0
    return -1 if lower else 1


def render_text(text: str) -> str:
    """Абзацы — ячейки, «## Заголовок» — новая группа, «- пункт» — список."""
    # «20 %» и «6.0 – 6.1» не должны разрываться переносом
    text = text.replace(" %", " %").replace(" –", " –")
    out, cells, bullets, paragraph = [], [], [], []

    def flush_paragraph():
        if paragraph:
            cells.append(f"<p>{html.escape(' '.join(paragraph))}</p>")
            paragraph.clear()

    def flush_bullets():
        if bullets:
            cells.append("<ul>" + "".join(f"<li>{html.escape(b)}</li>" for b in bullets) + "</ul>")
            bullets.clear()

    def flush_group():
        flush_paragraph()
        flush_bullets()
        if cells:
            out.append('<div class="group">' + "".join(cells) + "</div>")
            cells.clear()

    for line in text.strip().split("\n"):
        if line.startswith("- "):
            flush_paragraph()
            bullets.append(line[2:])
        elif line.startswith("## "):
            flush_group()
            out.append(f"<h2>{html.escape(line[3:])}</h2>")
        elif line.strip():
            flush_bullets()
            paragraph.append(line.strip())
        else:
            flush_paragraph()
            flush_bullets()
    flush_group()
    return "\n".join(out)


def publish_new(manifest: dict) -> list:
    """Добавляет в SITE новые версии. Возвращает ошибки."""
    sources = json.loads((DEBS / "sources.json").read_text())
    today = datetime.date.today().isoformat()
    errors = []
    for deb in sorted(DEBS.glob("*.deb")):
        control = control_of(deb)
        package, version = field(control, "Package"), field(control, "Version")
        source = sources.get(package)
        versions = manifest.setdefault(package, {})
        if version in versions:
            if versions[version]["source"] != source:
                errors.append(f"{package} {version}: исходники изменились, а эта версия уже опубликована — "
                              f"подними Version в control")
            continue
        newer = [v for v in versions if version_cmp(version, v) <= 0]
        if newer:
            errors.append(f"{package} {version}: уже опубликована более новая версия {max(newer, key=cmp_to_key(version_cmp))}")
            continue
        target = SITE / "debs" / f"{package}_{version}_iphoneos-arm.deb"
        target.parent.mkdir(exist_ok=True)
        shutil.copy2(deb, target)
        versions[version] = {"file": f"debs/{target.name}", "sha256": sha256(target), "source": source, "date": today}
        print(f"+ {package} {version}")
    return errors


def write_depiction(package: str, control: str, versions: dict) -> dict:
    """Страница и иконка пакета. Возвращает поля для Packages."""
    folder = SITE / "depictions" / package
    folder.mkdir(parents=True, exist_ok=True)
    extra = {}
    icon = ROOT / "icons" / f"{package}.png"
    icon_html = ""
    if icon.exists():
        shutil.copy2(icon, folder / "icon.png")
        icon_html = '<img src="icon.png" alt="">'
        if REPO_URL:
            extra["Icon"] = f"{REPO_URL}/depictions/{package}/icon.png"
    text = ROOT / "depictions" / f"{package}.txt"
    rows = "\n".join(
        f'<li class="row">{html.escape(v)}<em>{html.escape(versions[v]["date"])}</em></li>'
        for v in sorted(versions, key=cmp_to_key(version_cmp), reverse=True)
    )
    page = DEPICTION.format(
        name=html.escape(field(control, "Name") or package),
        icon=icon_html,
        body=render_text(text.read_text(encoding="utf-8")) if text.exists() else "",
        author=html.escape(field(control, "Author")),
        versions=rows,
    )
    (folder / "index.html").write_text(page, encoding="utf-8")
    if REPO_URL:
        extra["Depiction"] = f"{REPO_URL}/depictions/{package}/"
        extra["Homepage"] = f"{REPO_URL}/"
    return extra


def main() -> None:
    SITE.mkdir(parents=True, exist_ok=True)
    manifest_path = SITE / "published.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}

    errors = publish_new(manifest)
    for package, versions in manifest.items():
        for version, entry in versions.items():
            path = SITE / entry["file"]
            if not path.exists() or sha256(path) != entry["sha256"]:
                errors.append(f"{package} {version}: опубликованный файл {entry['file']} пропал или изменился")
    if errors:
        print("\n".join(f"ОШИБКА: {e}" for e in errors), file=sys.stderr)
        sys.exit(1)

    # Пересобираем всё производное; debs/ и published.json не трогаем
    for name in GENERATED:
        path = SITE / name
        if path.is_dir():
            shutil.rmtree(path)
        elif path.exists():
            path.unlink()
    shutil.copytree(ROOT / "repo", SITE, dirs_exist_ok=True)
    (SITE / ".nojekyll").touch()  # GitHub Pages отдаёт файлы как есть

    entries = []
    for package in sorted(manifest):
        versions = manifest[package]
        ordered = sorted(versions, key=cmp_to_key(version_cmp))
        latest_control = control_of(SITE / versions[ordered[-1]]["file"])
        extra = write_depiction(package, latest_control, versions)
        for version in ordered:
            path = SITE / versions[version]["file"]
            data = path.read_bytes()
            fields = [control_of(path), f"Filename: {versions[version]['file']}", f"Size: {len(data)}",
                      f"MD5sum: {hashlib.md5(data).hexdigest()}", f"SHA1: {hashlib.sha1(data).hexdigest()}",
                      f"SHA256: {versions[version]['sha256']}"]
            fields += [f"{key}: {value}" for key, value in extra.items()]
            entries.append("\n".join(fields))

    packages = ("\n\n".join(entries) + "\n").encode("utf-8")
    indexes = {
        "Packages": packages,
        "Packages.gz": gzip.compress(packages, mtime=0),
        "Packages.bz2": bz2.compress(packages),
    }
    for name, data in indexes.items():
        (SITE / name).write_bytes(data)

    release = [RELEASE_HEADER.rstrip("\n"), f"Date: {formatdate(usegmt=True)}"]
    for title, algorithm in (("MD5Sum", hashlib.md5), ("SHA1", hashlib.sha1), ("SHA256", hashlib.sha256)):
        release.append(f"{title}:")
        release += [f" {algorithm(data).hexdigest()} {len(data)} {name}" for name, data in indexes.items()]
    (SITE / "Release").write_text("\n".join(release) + "\n")

    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True, ensure_ascii=False) + "\n")
    print(f"{sum(len(v) for v in manifest.values())} версий {len(manifest)} пакетов → {SITE}")


if __name__ == "__main__":
    main()
