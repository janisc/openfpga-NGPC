#!/usr/bin/env python3
"""Package the built bitstream and the JSON definitions into an installable core.

APF loads a bit-reversed RBF, which Analogue calls an "RBF_R" and which the core
definition names with a .rev extension. Every byte of Quartus's .rbf has its bit
order flipped; nothing else about the file changes.

Usage:  python scripts/package.py [--zip]

Output: dist/Cores/<core>/            ready to copy onto the SD card
        dist/Platforms/
        dist/<core>_<version>.zip     with --zip
"""

import argparse
import json
import pathlib
import shutil
import sys
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
RBF = ROOT / "projects" / "output_files" / "ngpc_pocket.rbf"
PKG = ROOT / "pkg" / "pocket"
DIST = ROOT / "dist"
CORE_DIR_NAME = "Kitrinx.NGPC"

# Bit-reversal of every possible byte, built once.
REVERSE = bytes(int(f"{b:08b}"[::-1], 2) for b in range(256))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--zip", action="store_true", help="also produce a release zip")
    args = ap.parse_args()

    if not RBF.exists():
        print(f"error: {RBF} not found -- build the project first", file=sys.stderr)
        return 1

    core_json = json.loads((PKG / "Cores" / CORE_DIR_NAME / "core.json").read_text())
    meta = core_json["core"]["metadata"]
    rev_name = core_json["core"]["cores"][0]["filename"]

    if DIST.exists():
        shutil.rmtree(DIST)
    out_core = DIST / "Cores" / CORE_DIR_NAME
    out_core.mkdir(parents=True)
    shutil.copytree(PKG / "Platforms", DIST / "Platforms")

    for f in sorted((PKG / "Cores" / CORE_DIR_NAME).glob("*.json")):
        shutil.copy2(f, out_core / f.name)

    raw = RBF.read_bytes()
    (out_core / rev_name).write_bytes(raw.translate(REVERSE))
    print(f"{rev_name}: {len(raw):,} bytes reversed")

    # The Assets tree is where APF looks for the BIOS images named in data.json.
    # Ship it empty but present, with a note, so the destination is obvious.
    assets = DIST / "Assets" / "ngpc" / CORE_DIR_NAME
    assets.mkdir(parents=True)
    (assets / "PUT_BIOS_HERE.txt").write_text(
        "boot0.rom  Neo Geo Pocket Color BIOS (64 KiB)\n"
        "boot1.rom  Neo Geo Pocket mono BIOS (64 KiB)\n"
        "\n"
        "Same files the MiSTer core uses. Without boot0.rom the core has\n"
        "nothing to run and the screen stays blank.\n"
    )

    print(f"staged {DIST}")

    if args.zip:
        name = f"{CORE_DIR_NAME}_{meta['version']}.zip"
        zpath = DIST / name
        with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
            for p in sorted(DIST.rglob("*")):
                if p.is_file() and p != zpath:
                    z.write(p, p.relative_to(DIST))
        print(f"wrote {zpath}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
