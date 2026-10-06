#!/bin/sh
# Run every tracked bench and save one log per bench, plus a summary.
#   wsl -e sh sim/run_all.sh <log-dir>
# The summary lists each bench with its exit status and its last line.
# The rc6 families (sim/run_rc6_*.sh) run here in their short modes (an entry
# "script:mode"; together a couple of hours on a free machine, most of it
# run_rc6_combo.sh quick). Their full sets take many hours and are run by
# hand: each script's header lists its modes. RC6=0 leaves them out.
cd "$(dirname "$0")/.."
LOG="${1:-sim/logs_all}"
mkdir -p "$LOG"
: > "$LOG/SUMMARY.txt"
for s in run.sh run_cartsave.sh run_rc4_engine.sh run_rc4_loadpath.sh \
         run_rc5_engine.sh run_rc5_loadpath.sh run_rtc.sh run_seed_gate.sh \
         run_stage.sh run_statecart.sh run_psram_init.sh \
         run_rc6_hostport.sh run_rc6_l2.sh:check run_rc6_stamp.sh:bench \
         run_rc6_stamp.sh:held run_rc6_r1.sh:t9s run_rc6_combo.sh:quick; do
	case "$s:${RC6:-1}" in run_rc6_*:0) continue ;; esac
	f=${s%%:*}
	a=""
	case "$s" in *:*) a=${s#*:} ;; esac
	n=${f%.sh}${a:+_$a}
	[ -f "sim/$f" ] || continue
	sh "sim/$f" $a < /dev/null > "$LOG/$n.log" 2>&1
	rc=$?
	printf '%-22s exit=%d  %s\n' "$f${a:+ $a}" "$rc" "$(tail -n 1 "$LOG/$n.log")" >> "$LOG/SUMMARY.txt"
done
cat "$LOG/SUMMARY.txt"
