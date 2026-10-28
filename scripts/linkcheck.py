#!/usr/bin/env python3
"""Проверка линковки без компоновщика: все ли внешние символы объектных файлов
экспортируются для armv7 заглушками (.tbd) SDK и Substrate.

Нужна потому, что заглушки theos/sdks общие для всех архитектур и теряют символы,
которые есть только на 32-битных устройствах (например, objc_msgSend_stret).

Использование: scripts/linkcheck.py SDK VENDOR_LIB OBJECT...
Читает таблицу символов через llvm-nm.
"""

import re
import shutil
import subprocess
import sys
from pathlib import Path

import yaml

ARCH = "armv7"


class TbdLoader(yaml.SafeLoader):
    pass


# Теги вида !tapi-tbd-v2 разбираем как обычные словари
TbdLoader.add_multi_constructor("!", lambda loader, suffix, node: loader.construct_mapping(node, deep=True))


def tbd_exports(path: Path) -> set:
    symbols = set()
    try:
        documents = list(yaml.load_all(path.read_text(errors="replace"), Loader=TbdLoader))
    except yaml.YAMLError:
        return symbols
    for doc in documents:
        if not isinstance(doc, dict):
            continue
        for block in doc.get("exports") or []:
            if ARCH not in (block.get("archs") or []):
                continue
            symbols.update(block.get("symbols") or [])
            symbols.update(block.get("weak-def-symbols") or [])
            for cls in block.get("objc-classes") or []:
                name = cls.lstrip("_")
                symbols.update({f"_OBJC_CLASS_$_{name}", f"_OBJC_METACLASS_$_{name}"})
            for ivar in block.get("objc-ivars") or []:
                symbols.add(f"_OBJC_IVAR_$_{ivar.lstrip('_')}")
    return symbols


def nm_tool() -> str:
    for name in ("llvm-nm", "llvm-nm-18", "nm"):
        if shutil.which(name):
            return name
    sys.exit("нужен llvm-nm")


def main() -> int:
    sdk, vendor, objects = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3:]
    exported = set()
    for tbd in list(sdk.rglob("*.tbd")) + list(vendor.rglob("*.tbd")):
        # libgcc_s в твики не подключается, хотя только в нём есть _Unwind_SjLj_* для armv7
        if not tbd.name.startswith("libgcc_s"):
            exported |= tbd_exports(tbd)

    nm = nm_tool()
    # Объекты одного твика линкуются вместе: имя файла «твик__файл.o», символы соседей не считаем внешними
    groups = {}
    for obj in objects:
        groups.setdefault(Path(obj).name.split("__")[0], []).append(obj)
    status = 0
    for group, members in sorted(groups.items()):
        defined = set()
        for obj in members:
            defined |= set(subprocess.run([nm, "--defined-only", "-j", obj], check=True, capture_output=True, text=True).stdout.split())
        for obj in members:
            undefined = subprocess.run([nm, "-u", obj], check=True, capture_output=True, text=True).stdout.split()
            # ___divsi3 и подобные приходят из статической libclang_rt, а не из .tbd
            missing = [s for s in undefined if s not in exported and s not in defined
                       and not re.match(r"^___(div|mod|udiv|umod)\w*si3$", s)]
            if missing:
                status = 1
                print(f"FAIL {Path(obj).name}: нет в заглушках для {ARCH}: {', '.join(sorted(missing))}")
            else:
                print(f"ok   {Path(obj).name}")
    return status


if __name__ == "__main__":
    sys.exit(main())
