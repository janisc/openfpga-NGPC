#!/bin/sh
# Two link transports on a simulated cable (sim/eq/tb_link.sv).
#   wsl -e sh sim/eq/run_link.sh [+verilator+seed+N]
# MUTATE='<sed expression>' plants a bug in the transport under test.
set -e
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
OUT=${OUT:-$HOME/ngpc-sim/link}
mkdir -p "$OUT"
sed "${MUTATE:-}" target/pocket/ngpc_link.sv > "$OUT/ngpc_link.sv"
"${VERILATOR:-$HOME/.local/bin/verilator}" --binary --timing -O3 -Wno-fatal -Wno-lint -Wno-style \
	--Mdir "$OUT/obj" --top-module tb_link \
	"$OUT/ngpc_link.sv" "$ROOT/sim/eq/tb_link.sv" > "$OUT/build.log" 2>&1 \
	|| { cat "$OUT/build.log"; exit 1; }
"$OUT/obj/Vtb_link" "$@"
