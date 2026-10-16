#!/bin/sh
# The register file bench again, but with the synthesis branch of
# t900_rf_lutram: the altdpram primitive as Quartus's own simulation library
# (altera_mf.v) models it, instead of the behavioural array. Slower (iverilog),
# so fewer cycles.
#   wsl -e sh sim/eq/run_regfile_eq_altera.sh [+cycles=N]
set -e
cd "$(dirname "$0")/../.."
OUT=${OUT:-$HOME/ngpc-sim/regfile_eq_altera}
MF=${MF:-/mnt/c/altera_lite/25.1std/quartus/eda/sim_lib/altera_mf.v}
mkdir -p "$OUT"

sed 's/^module t900_regfile/module t900_regfile_ref/' \
	upstream/rtl/t900/t900_regfile.sv > "$OUT/t900_regfile_ref.sv"

iverilog -g2012 -DSYNTHESIS -o "$OUT/tb.vvp" -s tb_regfile_eq \
	"$MF" "$OUT/t900_regfile_ref.sv" target/pocket/t900_regfile_mlab.sv \
	sim/eq/tb_regfile_eq.sv

vvp -n "$OUT/tb.vvp" "${@:-+cycles=300000}"
