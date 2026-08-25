#!/bin/sh
# Build with several fitter seeds and record the worst setup slack of each.
#
# The design closes at the 85C corner but misses the Slow 0C corner by a
# fraction of a nanosecond on seed 1. That is placement luck, not a structural
# problem, so try a few and keep one that passes every corner.
set -e
cd "$(dirname "$0")/../projects"
QUARTUS=${QUARTUS:-/f/quartus/quartus/bin64}
mkdir -p ../dist/seeds

for seed in 2 3 4 5; do
	sed -i "s/^set_global_assignment -name SEED .*/set_global_assignment -name SEED $seed/" ngpc_pocket.qsf
	echo "=== seed $seed ==="
	"$QUARTUS/quartus_sh.exe" --flow compile ngpc_pocket > "build_seed$seed.log" 2>&1 || true
	worst=$(grep -A1 "^Type  : Slow.*Setup 'ic|mp1" output_files/ngpc_pocket.sta.summary \
		| grep "^Slack" | awk '{print $3}' | sort -g | head -1)
	echo "seed $seed worst clk_sys setup slack: $worst"
	echo "$seed $worst" >> ../dist/seeds/results.txt
	if [ -f output_files/ngpc_pocket.rbf ]; then
		cp output_files/ngpc_pocket.rbf "../dist/seeds/ngpc_pocket_seed$seed.rbf"
	fi
done

echo "--- results ---"
cat ../dist/seeds/results.txt
