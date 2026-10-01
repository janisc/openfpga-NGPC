#!/bin/sh
# Run every tracked bench and save one log per bench, plus a summary.
#   wsl -e sh /mnt/c/FPGA/ngpc-rc4/sim/run_all.sh <log-dir>
# The summary lists each bench with its exit status and its last line.
cd "$(dirname "$0")/.."
LOG="${1:-sim/logs_all}"
mkdir -p "$LOG"
: > "$LOG/SUMMARY.txt"
for s in run.sh run_cartsave.sh run_rc4_engine.sh run_rc4_loadpath.sh \
         run_rc5_engine.sh run_rc5_loadpath.sh run_rtc.sh run_seed_gate.sh \
         run_stage.sh run_statecart.sh; do
	[ -f "sim/$s" ] || continue
	sh "sim/$s" > "$LOG/${s%.sh}.log" 2>&1
	rc=$?
	printf '%-22s exit=%d  %s\n' "$s" "$rc" "$(tail -n 1 "$LOG/${s%.sh}.log")" >> "$LOG/SUMMARY.txt"
done
cat "$LOG/SUMMARY.txt"
