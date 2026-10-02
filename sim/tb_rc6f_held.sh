#!/bin/sh
# rc6 family F, the real load path: what the load diagnostic's held and
# drained bits record with the REAL bridge, copier and save engine.
#   wsl -e sh /mnt/c/FPGA/ngpc-rc4/sim/tb_rc6f_held.sh
# sim/tb_rc6f_mkheld.py builds sim/tb_rc6f_held.sv from the tracked
# sim/tb_rc5_loadpath.sv with the bridge's save_busy_i wired as
# target/pocket/ngpc_machine.sv wires save_busy_state -- read from the file;
# since the rc6 follow-up it is the save engine's boot_hold_o -- and runs
# SETUP, HELD-IDLE, HELD-LATE (a load during a background staging pass:
# held 0), HELD-EARLY (a load inside the boot hold: held 1) and C3-REAL (a
# reset cuts a drain at section word 1, the next load is a copier timeout:
# drained 0, since ngpc_state_cart resets cart_img_rd_addr). The captures go
# through tools/savinfo.py and are judged (sim/tb_rc6f_check.py held).
# run_rc6_stamp.sh runs this and the two mutants it is for. The last line is
# "== ALL RC6F HELD SCENARIOS PASS" or "== N FAILURE(S): ...", and the script
# then exits 1.
cd "$(dirname "$0")/.."
OUT=sim/tb_rc6f_out/held
LOG=sim/tb_rc6f_logs
NF=0
SUMMARY=""
note() { NF=$((NF + 1)); SUMMARY="$SUMMARY $1;"; }
mkdir -p "$OUT" "$LOG"
rm -f "$OUT"/*.hex "$OUT"/*.sta "$OUT"/*.txt
python3 sim/tb_rc6f_mkheld.py || { echo "== 1 FAILURE(S): sim/tb_rc6f_mkheld.py"; exit 1; }
iverilog -g2012 -D SYNTHESIS -DNGPC_SAVE_DIAG=1 -o sim/tb_rc6f_held.vvp -s tb_rc6f_held \
    upstream/rtl/Savestates/savestates.sv \
    target/pocket/ngpc_savestate_bridge.sv \
    sim/sim_synch3.v \
    upstream/rtl/cart/ngp_cart_overlay_geometry.sv \
    target/pocket/ngpc_cart_save.sv \
    target/pocket/ngpc_state_cart.sv \
    sim/tb_rc6f_held.sv || { echo "== 1 FAILURE(S): the build failed"; exit 1; }
vvp -n sim/tb_rc6f_held.vvp > "$LOG/held.log" 2>&1
grep -E '^==|^   ' "$LOG/held.log"
grep -q '^== RC6F HELD BENCH: ALL PASS' "$LOG/held.log" || note "bench ($(tail -n 1 "$LOG/held.log"))"
echo "== savinfo on the captures"
python3 sim/tb_rc6f_check.py held "$OUT" "$OUT" > "$LOG/held_sta.log" 2>&1
sed 's/^/   /' "$LOG/held_sta.log"
tail -n 1 "$LOG/held_sta.log" | grep -q 'ALL PASS' || note "savinfo decode"
if [ "$NF" -eq 0 ]; then
	echo "== ALL RC6F HELD SCENARIOS PASS"
	exit 0
fi
echo "== $NF FAILURE(S):$SUMMARY"
exit 1
