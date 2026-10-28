#!/usr/bin/env python3
"""Собирает Cydia-репозиторий для GitHub Pages в каталоге _site.

Плоский репозиторий: в Cydia добавляется адрес https://<user>.github.io/<repo>/
Использование: scripts/make-repo.py [каталог с .deb] [каталог сайта]
IR_REPO_URL — адрес источника; если задан, у пакетов появляется страница (поле Depiction).

Cydia на iOS 6 пропускает Description через перекодировку APT в ASCII, и кириллица
превращается в «?». Поэтому в Description — короткая строка по-английски, а русское
описание живёт на странице пакета: её Cydia показывает в браузере, где UTF-8 работает.
Тексты страниц — depictions/<пакет>.txt.
"""

import bz2
import gzip
import hashlib
import html
import os
import shutil
import subprocess
import sys
from email.utils import formatdate
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEBS = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "debs"
SITE = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "_site"
REPO_URL = os.environ.get("IR_REPO_URL", "").rstrip("/")

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
<link rel="stylesheet" href="../style.css">
</head>
<body>
<div class="page depiction">
{body}
<h2>Подробности</h2>
<ul class="group">
<li class="row">Версия<em>{version}</em></li>
<li class="row">Совместимость<em>iOS 6.0 – 6.1.x</em></li>
<li class="row">Разработчик<em>{author}</em></li>
</ul>
</div>
</body>
</html>
"""


def digests(data: bytes) -> dict:
    return {
        "MD5sum": hashlib.md5(data).hexdigest(),
        "SHA1": hashlib.sha1(data).hexdigest(),
        "SHA256": hashlib.sha256(data).hexdigest(),
    }


def control_of(deb: Path) -> str:
    return subprocess.run(["dpkg-deb", "-f", str(deb)], check=True, capture_output=True).stdout.decode("utf-8").strip()


def field(control: str, name: str) -> str:
    for line in control.split("\n"):
        if line.startswith(name + ": "):
            return line[len(name) + 2:]
    return ""


def render_text(text: str) -> str:
    """Абзацы — ячейки, «## Заголовок» — новая группа, «- пункт» — список."""
    # «20 %» и «6.0 – 6.1» не должны разрываться переносом
    text = text.replace(" %", "\u00a0%").replace(" –", "\u00a0–")
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


def write_depiction(control: str) -> str:
    package = field(control, "Package")
    source = ROOT / "depictions" / f"{package}.txt"
    if not source.exists():
        return ""
    page = DEPICTION.format(
        name=html.escape(field(control, "Name") or package),
        body=render_text(source.read_text(encoding="utf-8")),
        version=html.escape(field(control, "Version")),
        author=html.escape(field(control, "Author")),
    )
    (SITE / "depictions").mkdir(exist_ok=True)
    (SITE / "depictions" / f"{package}.html").write_text(page, encoding="utf-8")
    return f"{REPO_URL}/depictions/{package}.html" if REPO_URL else ""


def main() -> None:
    debs = sorted(DEBS.glob("*.deb"))
    if not debs:
        sys.exit(f"нет пакетов в {DEBS}")

    if SITE.exists():
        shutil.rmtree(SITE)
    shutil.copytree(ROOT / "repo", SITE)
    (SITE / "debs").mkdir()
    (SITE / ".nojekyll").touch()  # GitHub Pages отдаёт файлы как есть

    entries = []
    for deb in debs:
        target = SITE / "debs" / deb.name
        shutil.copy2(deb, target)
        data = target.read_bytes()
        control = control_of(target)
        fields = [control, f"Filename: debs/{deb.name}", f"Size: {len(data)}"]
        fields += [f"{name}: {value}" for name, value in digests(data).items()]
        depiction = write_depiction(control)
        if depiction:
            fields.append(f"Depiction: {depiction}")
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
    for title, key in (("MD5Sum", "MD5sum"), ("SHA1", "SHA1"), ("SHA256", "SHA256")):
        release.append(f"{title}:")
        release += [f" {digests(data)[key]} {len(data)} {name}" for name, data in indexes.items()]
    (SITE / "Release").write_text("\n".join(release) + "\n")

    print(f"{len(debs)} пакетов → {SITE}")


if __name__ == "__main__":
    main()
