#!/bin/sh
# Lock-step equivalence of the whole CPU core: upstream's t900 files against
# the t900 files the Quartus project builds (projects/ngpc_upstream.qip).
# Run from anywhere:
#   wsl -e sh sim/eq/run_cpu_lockstep.sh [plusargs]
# e.g.  +cycles=20000000 +verilator+seed+7
#       +mode=rom +bios=/path/bios.hex +rom=/path/cart.hex   (hex: one byte per line)
# Needs Verilator 5 (see LOCATIONS.md). The build lands in WSL, not on C:.
# BUILD=0 reuses the last build.
set -e
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
OUT=${OUT:-$HOME/ngpc-sim/cpu_lockstep}
VERILATOR=${VERILATOR:-$HOME/.local/bin/verilator}
mkdir -p "$OUT/ref"

if [ "${BUILD:-1}" != 0 ]; then
	# The reference: upstream's core with every module renamed *_ref.
	MODS="t900_alu t900_biu t900_cpu t900_decode t900_muldiv t900_regfile t900_seq t900_shifter"
	EXPR=""
	for m in $MODS; do EXPR="$EXPR -e s/\\b$m\\b/${m}_ref/g"; done
	REF=""
	for m in $MODS; do
		sed $EXPR "upstream/rtl/t900/$m.sv" > "$OUT/ref/$m.sv"
		REF="$REF $OUT/ref/$m.sv"
	done

	# Under test: exactly the t900 files the FPGA build uses.
	DUT=$(tr -d '\r' < projects/ngpc_upstream.qip | grep -E '^set.*SYSTEMVERILOG_FILE .*t900' \
		| grep -v t900_mcu | awk '{print $NF}' | sed "s|^\.\./|$ROOT/|")
	echo "under test:" $DUT | sed "s|$ROOT/||g" > "$OUT/build.log"

	"$VERILATOR" --binary --timing -O3 -Wno-fatal -Wno-lint -Wno-style \
		--x-assign 0 --x-initial 0 \
		-I"$ROOT/upstream/rtl/t900" \
		--Mdir "$OUT/obj" --top-module tb_cpu_lockstep \
		$REF $DUT "$ROOT/sim/eq/tb_cpu_lockstep.sv" >> "$OUT/build.log" 2>&1 \
		|| { cat "$OUT/build.log"; exit 1; }
	head -1 "$OUT/build.log"
fi

"$OUT/obj/Vtb_cpu_lockstep" "$@"
