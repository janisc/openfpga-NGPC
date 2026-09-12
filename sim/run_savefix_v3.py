#!/usr/bin/env python3
"""Run the portable V3 regression; generates no game-derived fixtures."""
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
for tool in ("iverilog", "vvp"):
    if not shutil.which(tool):
        sys.exit(f"Missing {tool}; install Icarus Verilog (tested with version 13).")
if not (root / "upstream/rtl/cart/ngp_cart_overlay_geometry.sv").exists():
    sys.exit("Missing pinned upstream source; see docs/SAVEFIX_TESTING.md for setup.")
for script in ("savefix_codec.py", "savefix_banks.py", "savefix_fullstack.py", "savefix_bridge.py"):
    print(f"Running {script}", flush=True)
    subprocess.run([sys.executable, str(root / "sim" / script)], cwd=root, check=True)
print("All V3 regressions passed; logs and generated fixtures: dist/savefix-tests/")
