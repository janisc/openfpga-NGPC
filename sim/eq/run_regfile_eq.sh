#!/bin/sh
# Lock-step equivalence of the LUT-RAM register file against upstream's.
# Run from anywhere:
#   wsl -e sh sim/eq/run_regfile_eq.sh
# Needs Verilator 5 (see LOCATIONS.md). The build lands in WSL, not on C:.
set -e
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
OUT=${OUT:-$HOME/ngpc-sim/regfile_eq}
mkdir -p "$OUT"

sed 's/^module t900_regfile/module t900_regfile_ref/' \
	upstream/rtl/t900/t900_regfile.sv > "$OUT/t900_regfile_ref.sv"

# MUTATE='<sed expression>' plants a bug in the copy under test, to show the
# bench catches it. A mutant run must end in REGFILE DIFFERS.
sed "${MUTATE:-}" target/pocket/t900_regfile_mlab.sv > "$OUT/t900_regfile_dut.sv"

"${VERILATOR:-$HOME/.local/bin/verilator}" --binary --timing -O3 -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
	--x-assign 0 --x-initial 0 \
	--Mdir "$OUT/obj" --top-module tb_regfile_eq \
	"$OUT/t900_regfile_ref.sv" \
	"$OUT/t900_regfile_dut.sv" \
	"$ROOT/sim/eq/tb_regfile_eq.sv" > "$OUT/build.log" 2>&1 \
	|| { cat "$OUT/build.log"; exit 1; }

"$OUT/obj/Vtb_regfile_eq"
