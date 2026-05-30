#!/usr/bin/env python3
"""Extract main-resource HTML from a Safari `.webarchive` (binary plist).

Usage:
    python3 tools/test-plugin/extract_webarchive.py <input.webarchive> <output.html>

This is a contributor helper — saved bank pages are converted to plain
HTML which is then fed to `sanitise.py`. The raw webarchive and the
extracted HTML both live OUTSIDE the repo (typically in
`~/Downloads/Moolah Sites/`); only the sanitised fixture is committed.

If the webarchive's main resource lives in a subframe, this script
extracts the *top* frame only. For SPAs that render in a subframe,
re-run with the subframe URL after locating it in
`WebSubframeArchives`.
"""
from __future__ import annotations

import plistlib
import sys
from pathlib import Path


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    src = Path(argv[0])
    out = Path(argv[1])
    if not src.exists():
        print(f"input not found: {src}", file=sys.stderr)
        return 1
    archive = plistlib.loads(src.read_bytes())
    main_resource = archive.get("WebMainResource") or {}
    data = main_resource.get("WebResourceData")
    if not data:
        print("webarchive has no WebMainResource.WebResourceData", file=sys.stderr)
        return 1
    out.write_bytes(data)
    url = main_resource.get("WebResourceURL", "?")
    print(f"extracted {len(data)} bytes from {url} → {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
