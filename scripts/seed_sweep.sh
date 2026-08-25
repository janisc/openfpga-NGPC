#!/bin/sh
# Build with several fitter seeds and record the worst setup slack of each.
#
# Placement is luck at the margins, and this design sits near one. A seed sweep
# is the cheapest way to buy back a few hundred picoseconds.
#
# Two rules this script learned the hard way:
#
#   1. quartus_fit --seed DOES write the seed back into the .qsf -- passing it
#      on the command line is not the escape hatch it looks like. What matters
#      is that nothing edits the file WHILE a compile is live: an earlier
#      version did, Quartus declared the file corrupt, and "helpfully" rewrote
#      it, inlining every pin assignment from Analogue's pocket.tcl and dropping
#      a constraint line. The seed is restored at the end here.
#
#   1b. NOTHING ELSE MAY RUN A QUARTUS FLOW while this is going. The per-seed
#      fits reuse whatever netlist is in db/, so a concurrent full compile
#      silently swaps the design out from under the sweep. That is how a
#      half-fixed bitstream once reached the SD card.
#
#   2. It refuses to start on a dirty tree, and it checks each build actually
#      succeeded before reading a slack number. The first version did neither,
#      so when a build failed it silently read the previous run's summary and
#      reported four different seeds with identical slack.
set -e
cd "$(dirname "$0")/.."
QUARTUS=${QUARTUS:-/f/quartus/quartus/bin64}
SEEDS=${SEEDS:-"1 2 3 4 5 6"}
OUT=builds/seeds

if [ -n "$(git status --porcelain -- projects target upstream platform)" ]; then
	echo "error: uncommitted changes in the build inputs." >&2
	echo "A sweep takes an hour; make sure it measures something you can reproduce." >&2
	exit 1
fi

mkdir -p "$OUT"
: > "$OUT/results.txt"

cd projects
"$QUARTUS/quartus_map.exe" ngpc_pocket > "../$OUT/map.log" 2>&1

for seed in $SEEDS; do
	echo "=== seed $seed ==="
	if ! "$QUARTUS/quartus_fit.exe" --seed="$seed" ngpc_pocket > "../$OUT/fit_$seed.log" 2>&1; then
		echo "seed $seed: FIT FAILED"
		echo "$seed FIT_FAILED" >> "../$OUT/results.txt"
		continue
	fi
	if ! "$QUARTUS/quartus_sta.exe" ngpc_pocket > "../$OUT/sta_$seed.log" 2>&1; then
		echo "seed $seed: STA FAILED"
		echo "$seed STA_FAILED" >> "../$OUT/results.txt"
		continue
	fi

	# Worst setup slack across every corner, not just the hot one: this design
	# has missed at Slow 0C while passing Slow 85C.
	worst=$(awk '/^Type .*Setup/ {getline; if ($0 ~ /^Slack/) print $3}' \
		output_files/ngpc_pocket.sta.summary | sort -g | head -1)
	echo "seed $seed worst setup slack (all corners): $worst"
	echo "$seed $worst" >> "../$OUT/results.txt"

	"$QUARTUS/quartus_asm.exe" ngpc_pocket > "../$OUT/asm_$seed.log" 2>&1 || true
	[ -f output_files/ngpc_pocket.rbf ] && cp output_files/ngpc_pocket.rbf "../$OUT/seed$seed.rbf"
done

cd ..
git checkout -- projects/ngpc_pocket.qsf

echo "--- results (worst corner, higher is better) ---"
sort -k2 -g -r "$OUT/results.txt"
