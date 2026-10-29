#!/usr/bin/env python3
"""Adds to the libobjc stub from theos/sdks the symbols that only the 32-bit runtime has.

The theos/sdks stubs hold a single symbol list for all architectures, so the functions
that arm64 lacks have dropped out of them. On armv7 (iOS 6) objc_msgSend_stret and its relatives
do exist, and the compiler calls them for methods that return CGRect, CGPoint or CGSize.

Usage: scripts/fix-sdk.py path/to/iPhoneOS10.3.sdk  (running it again changes nothing)
"""

import sys
from pathlib import Path

MARKER = "# Skeuo4Ever: 32-bit symbols"
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
        sys.exit(f"unexpected format of {tbd}: cannot add the symbols")
    # exports is the last key of the document, so the new block goes before "..."
    last_key = max(i for i, line in enumerate(lines) if line and not line.startswith(" ") and line != "...")
    if not lines[last_key].startswith("exports:"):
        sys.exit(f"{tbd} has other keys after exports: cannot add the symbols")
    tbd.write_text("\n".join(lines[:-1]) + "\n" + BLOCK + "...\n")
    print(f"added the 32-bit symbols to {tbd}")


if __name__ == "__main__":
    main()
