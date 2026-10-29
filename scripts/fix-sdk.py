#!/usr/bin/env python3
"""Дописывает в заглушку libobjc из theos/sdks символы, которые есть только у 32-битного рантайма.

Заглушки theos/sdks содержат один список символов на все архитектуры, поэтому функции,
которых нет на arm64, из них выпали. На armv7 (iOS 6) objc_msgSend_stret и родственники
существуют, и компилятор вызывает их для методов, возвращающих CGRect, CGPoint, CGSize.

Использование: scripts/fix-sdk.py путь/к/iPhoneOS10.3.sdk  (повторный запуск ничего не меняет)
"""

import sys
from pathlib import Path

MARKER = "# Skeuo4Ever: 32-битные символы"
BLOCK = f"""  {MARKER}
  - archs:                [ armv7, armv7s ]
    symbols:              [ _objc_msgSendSuper2_stret, _objc_msgSendSuper_stret,
                            _objc_msgSend_stret ]
"""


def main() -> None:
    tbd = Path(sys.argv[1]) / "usr/lib/libobjc.A.tbd"
    text = tbd.read_text()
    if MARKER in text:
        return
    lines = text.rstrip("\n").split("\n")
    if lines[-1] != "..." or not any(line.startswith("exports:") for line in lines):
        sys.exit(f"неожиданный формат {tbd}: не могу дописать символы")
    # exports — последний ключ документа, поэтому новый блок встаёт перед «...»
    last_key = max(i for i, line in enumerate(lines) if line and not line.startswith(" ") and line != "...")
    if not lines[last_key].startswith("exports:"):
        sys.exit(f"в {tbd} после exports есть другие ключи: не могу дописать символы")
    tbd.write_text("\n".join(lines[:-1]) + "\n" + BLOCK + "...\n")
    print(f"дописаны 32-битные символы в {tbd}")


if __name__ == "__main__":
    main()
