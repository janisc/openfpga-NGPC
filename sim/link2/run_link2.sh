#!/bin/sh
# Two complete NGPCs on a simulated link cable (sim/link2).
#
#   wsl -e sh sim/link2/run_link2.sh \
#       <bios.rom> <cart A> <cart B> <script> [extra plusargs...]
#
# ROM images are converted to hex in the run directory ($OUT, in WSL); they are
# never copied into the repository. BUILD=0 reuses the last build.
set -e
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
OUT=${OUT:-$HOME/ngpc-sim/link2}
VERILATOR=${VERILATOR:-$HOME/.local/bin/verilator}
mkdir -p "$OUT/run"

if [ "${BUILD:-1}" != 0 ]; then
	U=$ROOT/upstream/rtl
	# VFLAGS adds Verilator options. One thread: --threads 2 measured slower,
	# the per-step synchronisation costs more than the second core gains.
	"$VERILATOR" --cc --exe --build -j 6 -O3 --savable $VFLAGS \
		-MAKEFLAGS "OPT_FAST=-O3 OPT_SLOW=-O1" -CFLAGS -march=native \
		-Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
		-DNGPC_POCKET=1 -DNGPC_NO_CHEATS=1 -DTV80_REFRESH=1 -DNGPC_DOT_BURST=1 \
		-I"$U/t900" -I"$U/soc" -I"$U/video" -I"$U/snd" -I"$U/cart" \
		-y "$U/soc" -y "$U/t900" -y "$U/video" -y "$U/snd" -y "$U/snd/z80" \
		-y "$U/snd/z80/tv80" -y "$U/cart" -y "$U/Mem" -y "$U/Savestates" \
		+libext+.sv+.v \
		--Mdir "$OUT/obj" --top-module tb_link2 \
		"$ROOT/target/pocket/t900_regfile_mlab.sv" \
		"$ROOT/target/pocket/tv80_reg_mlab.v" "$ROOT/target/pocket/pocket_lutram.sv" \
		"$ROOT/target/pocket/ngpc_link.sv" \
		"$U/Mem/cache_ram.v" "$U/Mem/cache_ram_be.sv" \
		"$ROOT/target/pocket/ngpc_pocket_video.sv" \
		"$ROOT/sim/link2/ngpc_sim_machine.sv" \
		"$ROOT/sim/link2/tb_link2.sv" \
		"$ROOT/sim/link2/sim_main.cpp" > "$OUT/build.log" 2>&1 \
		|| { tail -40 "$OUT/build.log"; exit 1; }
	echo "built"
fi

[ $# -ge 4 ] || exit 0
hexof() { xxd -p -c1 "$1" > "$2"; }
hexof "$1" "$OUT/run/bios.hex"
hexof "$2" "$OUT/run/cart0.hex"
hexof "$3" "$OUT/run/cart1.hex"
B0=$(stat -c %s "$2"); B1=$(stat -c %s "$3")
SCRIPT=$4; shift 4
mkdir -p "$OUT/shots"
cd "$OUT/run"
"$OUT/obj/Vtb_link2" +bios=bios.hex +cart0=cart0.hex +cart0_bytes=$B0 \
	+cart1=cart1.hex +cart1_bytes=$B1 +script="$SCRIPT" +out="$OUT/shots" "$@"
