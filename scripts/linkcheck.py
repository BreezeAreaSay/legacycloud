#!/usr/bin/env python3
"""Link check without a linker: are all external symbols of the object files
exported for armv7 by the SDK and Substrate stubs (.tbd)?

It is needed because the theos/sdks stubs are shared by all architectures and lose the symbols
that exist only on 32-bit devices (e.g. objc_msgSend_stret).

Usage: scripts/linkcheck.py SDK VENDOR_LIB OBJECT...
Reads the symbol tables with llvm-nm.
"""

import shutil
import subprocess
import sys
from pathlib import Path

import yaml

ARCH = "armv7"


class TbdLoader(yaml.SafeLoader):
    pass


# Tags like !tapi-tbd-v2 are parsed as plain dictionaries
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
    sys.exit("llvm-nm is required")


def main() -> int:
    sdk, vendor, objects = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3:]
    exported = set()
    for tbd in list(sdk.rglob("*.tbd")) + list(vendor.rglob("*.tbd")):
        # libgcc_s is not linked into the tweaks, although only it has _Unwind_SjLj_* for armv7
        if not tbd.name.startswith("libgcc_s"):
            exported |= tbd_exports(tbd)

    nm = nm_tool()
    # Objects of one tweak are linked together: the file name is "tweak__file.o", and symbols of its siblings do not count as external
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
            # ___divsi3, ___udivsi3 and the like (integer division by a variable: armv7 of the A5 has no
            # divide instruction) are not in the stubs either, and the Theos toolchain links no libclang_rt
            missing = [s for s in undefined if s not in exported and s not in defined]
            if missing:
                status = 1
                print(f"FAIL {Path(obj).name}: missing from the {ARCH} stubs: {', '.join(sorted(missing))}")
            else:
                print(f"ok   {Path(obj).name}")
    return status


if __name__ == "__main__":
    sys.exit(main())
