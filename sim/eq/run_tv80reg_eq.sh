#!/bin/sh
# Lock-step equivalence of the LUT-RAM tv80_reg against upstream's.
#   wsl -e sh sim/eq/run_tv80reg_eq.sh
# ALTERA=1 runs the synthesis branch through Quartus's altdpram model
# (iverilog, slower, so fewer cycles by default).
# MUTATE='<sed expression>' plants a bug in the copy under test.
set -e
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
OUT=${OUT:-$HOME/ngpc-sim/tv80reg_eq}
mkdir -p "$OUT"

sed 's/^module tv80_reg /module tv80_reg_ref /' \
	upstream/rtl/snd/z80/tv80/tv80_reg.v > "$OUT/tv80_reg_ref.v"
sed "${MUTATE:-}" target/pocket/tv80_reg_mlab.v > "$OUT/tv80_reg_dut.v"

if [ "${ALTERA:-0}" = 1 ]; then
	MF=${MF:-/mnt/c/altera_lite/25.1std/quartus/eda/sim_lib/altera_mf.v}
	iverilog -g2012 -DSYNTHESIS -o "$OUT/tb.vvp" -s tb_tv80reg_eq \
		"$MF" "$OUT/tv80_reg_ref.v" "$OUT/tv80_reg_dut.v" \
		target/pocket/pocket_lutram.sv sim/eq/tb_tv80reg_eq.sv
	vvp -n "$OUT/tb.vvp" "${@:-+cycles=300000}"
else
	"${VERILATOR:-$HOME/.local/bin/verilator}" --binary --timing -O3 -Wno-fatal -Wno-lint -Wno-style \
		--x-assign 0 --x-initial 0 \
		--Mdir "$OUT/obj" --top-module tb_tv80reg_eq \
		"$OUT/tv80_reg_ref.v" "$OUT/tv80_reg_dut.v" \
		"$ROOT/target/pocket/pocket_lutram.sv" \
		"$ROOT/sim/eq/tb_tv80reg_eq.sv" > "$OUT/build.log" 2>&1 \
		|| { cat "$OUT/build.log"; exit 1; }
	"$OUT/obj/Vtb_tv80reg_eq" "$@"
fi
