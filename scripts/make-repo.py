#!/usr/bin/env python3
"""Собирает Cydia-репозиторий для GitHub Pages в каталоге _site.

Плоский репозиторий: в Cydia добавляется адрес https://<user>.github.io/<repo>/
Использование: scripts/make-repo.py [каталог с .deb] [каталог сайта]
"""

import bz2
import gzip
import hashlib
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEBS = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "debs"
SITE = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "_site"

RELEASE_HEADER = """Origin: iOS6Revive
Label: iOS6Revive
Suite: stable
Version: 1.0
Codename: ios6revive
Architectures: iphoneos-arm
Components: main
Description: Функции новых iOS в стиле iOS 6
"""


def digests(data: bytes) -> dict:
    return {
        "MD5sum": hashlib.md5(data).hexdigest(),
        "SHA1": hashlib.sha1(data).hexdigest(),
        "SHA256": hashlib.sha256(data).hexdigest(),
    }


def control_of(deb: Path) -> str:
    return subprocess.run(["dpkg-deb", "-f", str(deb)], check=True, capture_output=True, text=True).stdout.strip()


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
        fields = [control_of(target), f"Filename: debs/{deb.name}", f"Size: {len(data)}"]
        fields += [f"{name}: {value}" for name, value in digests(data).items()]
        entries.append("\n".join(fields))

    packages = ("\n\n".join(entries) + "\n").encode()
    indexes = {
        "Packages": packages,
        "Packages.gz": gzip.compress(packages, mtime=0),
        "Packages.bz2": bz2.compress(packages),
    }
    for name, data in indexes.items():
        (SITE / name).write_bytes(data)

    release = [RELEASE_HEADER.rstrip("\n")]
    for title, key in (("MD5Sum", "MD5sum"), ("SHA1", "SHA1"), ("SHA256", "SHA256")):
        release.append(f"{title}:")
        release += [f" {digests(data)[key]} {len(data)} {name}" for name, data in indexes.items()]
    (SITE / "Release").write_text("\n".join(release) + "\n")

    print(f"{len(debs)} пакетов → {SITE}")


if __name__ == "__main__":
    main()
