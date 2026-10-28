#!/usr/bin/env python3
"""Печатает JSON {пакет: отпечаток исходников}.

Сборка под armv7 не воспроизводима побайтно (подпись, время в архиве), поэтому
публикация сравнивает не .deb, а исходники, из которых он собран:
  твик — его каталог, shared/, common.mk и scripts/fix-sdk.py;
  мета-пакет — его каталог.
Учитываются только файлы под git, чтобы не цеплять результаты сборки.
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
    raise SystemExit(f"нет Package в {control}")


def main() -> None:
    result = {}
    for control in sorted(ROOT.glob("tweaks/*/control")):
        result[package_id(control)] = fingerprint([str(control.parent.relative_to(ROOT)), *COMMON])
    for control in sorted(ROOT.glob("meta/*/control")):
        result[package_id(control)] = fingerprint([str(control.parent.relative_to(ROOT))])
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
