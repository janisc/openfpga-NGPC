#!/bin/sh
# rc6 family F: the load diagnostic target/pocket/ngpc_savestate_bridge.sv
# stamps into pad word 8419 of every capture, against the REAL rc6 bridge and
# the real upstream engine (sim/tb_rc6f_stamp.sv, APF-side stimulus), and
# its held / drained bits on the real bridge + copier + save engine
# (sim/tb_rc6f_held.sh):
#
#   wsl -e sh sim/run_rc6_stamp.sh [all|bench|held|mutants]
#
#   bench    the six scenario groups on the rc6 bridge; the same stimulus on
#            the rc5 bridge (sim/tb_rc6f_rc5_bridge.sv = git show
#            ca02563:target/pocket/ngpc_savestate_bridge.sv), whose load
#            decisions and captures must match rc6's in everything but word
#            8419 (identity block 8420..8423 unchanged, the stamp decides
#            nothing); then every rc6 capture written as a .sta and decoded
#            with tools/savinfo.py, its texts checked word for word in the
#            rc6 follow-up's wording (sim/tb_rc6f_check.py). The bench's
#            save_busy_i is the save engine output that
#            target/pocket/ngpc_machine.sv wires to save_busy_state, read
#            from the file (sim/tb_rc6f_mkheld.py --wiring): boot_hold_o.
#   held     sim/tb_rc6f_held.sh: HELD-IDLE / HELD-LATE / HELD-EARLY /
#            C3-REAL with the real copier and save engine, savinfo judged.
#   mutants  each must fail where named (+STOPFAIL / +SCN):
#            - sim/tb_rc6f_mut_<name>.sv, the rc6 bridge with one part of
#              the change removed or misplaced (sed below), in the stamp
#              groups named for it; the rc5 bridge -- the whole change
#              removed -- is the mutant "rc5";
#            - mbusy: target/pocket/ngpc_machine.sv with save_busy_state
#              wired back to the engine's busy_o
#              (sim/tb_rc6f_mut_mbusy_machine.sv): HELD-LATE stamps held 1,
#              and the stamp bench rebuilt from that wiring fails group 4;
#            - noaddrrst: target/pocket/ngpc_state_cart.sv without the
#              cart_img_rd_addr reset (sim/tb_rc6f_mut_noaddrrst_cart.sv):
#              C3-REAL stamps drained 1.
#            Every sed is checked to have changed exactly the lines it
#            meant to (removed/added line counts, and for the two new ones
#            the lines themselves).
#   all      (default) bench, held, then mutants
#
# JOBS (default 3) vvp runs in parallel; one stamp group takes 2-8 minutes,
# the held bench a few. Logs: sim/tb_rc6f_logs/; captures, .sta files and
# savinfo output: sim/tb_rc6f_out/. The last line is
# "== ALL RC6 STAMP SCENARIOS PASS" or "== N FAILURE(S): ...", and the script
# then exits 1.
cd "$(dirname "$0")/.."

MODE=${1:-all}
JOBS=${JOBS:-3}
LOG=sim/tb_rc6f_logs
OUT=sim/tb_rc6f_out
BRIDGE=target/pocket/ngpc_savestate_bridge.sv
MACHINE=target/pocket/ngpc_machine.sv
CART=target/pocket/ngpc_state_cart.sv
COMMON="upstream/rtl/Savestates/savestates.sv sim/sim_synch3.v sim/tb_rc6f_stamp.sv"
HELDSRC="upstream/rtl/Savestates/savestates.sv $BRIDGE sim/sim_synch3.v upstream/rtl/cart/ngp_cart_overlay_geometry.sv target/pocket/ngpc_cart_save.sv"
GROUPS="1 2 3 4 5 6"
NF=0
SUMMARY=""
note() { NF=$((NF + 1)); SUMMARY="$SUMMARY $1;"; }

case "$MODE" in all|bench|held|mutants) ;; *) echo "usage: $0 [all|bench|held|mutants]"; exit 2 ;; esac

mkdir -p "$LOG" "$OUT/rc6" "$OUT/rc5" "$OUT/sta" "$OUT/mut"
if ! python3 sim/tb_rc6f_mkimg.py "$OUT/sav_img.hex"; then
	echo "== 1 FAILURE(S): sim/tb_rc6f_mkimg.py"; exit 1
fi

# The engine output a machine file drives the bridge's save_busy_i from, as
# the stamp bench's define: "" for boot_hold_o, -DRC6F_SBI_BUSY for busy_o.
sbi_define() {
	p=$(python3 sim/tb_rc6f_mkheld.py --wiring --machine "$1") || { echo "$p" >&2; return 1; }
	case "$p" in
		boot_hold_o) echo "" ;;
		busy_o)      echo "-DRC6F_SBI_BUSY" ;;
		*)           echo "unexpected wiring $p" >&2; return 1 ;;
	esac
}
if ! SBIDEF=$(sbi_define "$MACHINE"); then
	echo "== 1 FAILURE(S): the save_busy_i wiring could not be read from $MACHINE"; exit 1
fi
echo "== RC6F wiring: $MACHINE drives the bridge's save_busy_i from cart_save.$(python3 sim/tb_rc6f_mkheld.py --wiring)"

build() {   # tag bridge-file [defines]
	iverilog -g2012 -D SYNTHESIS $3 -o sim/tb_rc6f_$1.vvp -s tb_rc6f_stamp $2 $COMMON
}

# Run "<vvp tag> <log name> <plusargs...>" lines from stdin in JOBS lanes.
# Every job's log is removed before any starts, so a job that never ran (or
# was killed) cannot be judged on an older run's log. No xargs: a cleanup
# elsewhere that kills xargs by name killed this pool once.
run_jobs() {
	jl=$(mktemp)
	cat > "$jl"
	while read -r tag log rest; do rm -f "$LOG/$log.log"; done < "$jl"
	i=0
	while [ "$i" -lt "$JOBS" ]; do
		awk -v n="$JOBS" -v i="$i" 'NR % n == i' "$jl" | while read -r tag log rest; do
			vvp -n sim/tb_rc6f_$tag.vvp $rest > "$LOG/$log.log" 2>&1
			echo "   ran $log: $(tail -n 1 "$LOG/$log.log")"
		done &
		i=$((i + 1))
	done
	wait
	rm -f "$jl"
}

# A sed mutant: copy, then check the diff is exactly <removed>/<added> lines.
mutate() {   # name src dst counts sed-script
	sed -e "$5" "$2" > "$3"
	got="$(diff "$2" "$3" | grep -c '^<')/$(diff "$2" "$3" | grep -c '^>')"
	if [ "$got" != "$4" ]; then
		note "mutant $1: the sed changed $got (removed/added) lines, meant $4"
		return 1
	fi
	return 0
}

# ============================================================================
# bench
# ============================================================================
if [ "$MODE" = all ] || [ "$MODE" = bench ]; then
	if ! build rc6 "$BRIDGE" "$SBIDEF"; then echo "== 1 FAILURE(S): the rc6 build failed"; exit 1; fi
	if ! build rc5 sim/tb_rc6f_rc5_bridge.sv "-DRC6F_RC5 $SBIDEF"; then echo "== 1 FAILURE(S): the rc5 build failed"; exit 1; fi
	rm -f "$OUT"/rc6/*.hex "$OUT"/rc5/*.hex "$OUT"/sta/*
	echo "== RC6F bench: groups $GROUPS on rc6 and on rc5, $JOBS at a time"
	for b in rc6 rc5; do for g in $GROUPS; do echo "$b ${b}_g$g +GROUP=$g +OUT=$OUT/$b"; done; done | run_jobs

	echo "== RC6F bench: rc6 scenarios"
	for g in $GROUPS; do
		f=$LOG/rc6_g$g.log
		grep -E '^   (PASS|FAIL|INFO)' "$f" | sed 's/^/   /'
		if ! grep -q "^== RC6F GROUP $g PASS" "$f"; then note "rc6 group $g ($(tail -n 1 "$f"))"; fi
	done
	echo "== RC6F bench: rc5 (the whole change removed) must fail the stamp checks"
	for g in $GROUPS; do
		f=$LOG/rc5_g$g.log
		if grep -q "^== RC6F GROUP $g: [0-9]* FAILURE" "$f"; then
			echo "   rc5 group $g caught: $(grep -c '^   FAIL' "$f") check(s), first: $(grep -m1 '^   FAIL' "$f" | cut -c1-110)"
		else
			note "rc5 group $g was not caught ($(tail -n 1 "$f"))"
		fi
	done
	echo "== RC6F bench: rc6 against rc5 (decisions, identity block, blobs)"
	python3 sim/tb_rc6f_check.py cmp "$LOG" "$OUT/rc6" "$OUT/rc5" > "$LOG/cmp.log" 2>&1
	grep -E '^   FAIL|^      |^==' "$LOG/cmp.log" | sed 's/^/   /'
	tail -n 1 "$LOG/cmp.log" | grep -q 'ALL PASS' || note "rc5 comparison"
	echo "== RC6F bench: the captures as .sta files through tools/savinfo.py"
	python3 sim/tb_rc6f_check.py sta "$OUT/rc6" "$OUT/sta" > "$LOG/sta.log" 2>&1
	sed 's/^/   /' "$LOG/sta.log"
	tail -n 1 "$LOG/sta.log" | grep -q 'ALL PASS' || note "savinfo decode"
fi

# ============================================================================
# held: the real copier and save engine
# ============================================================================
if [ "$MODE" = all ] || [ "$MODE" = held ]; then
	echo "== RC6F held (sim/tb_rc6f_held.sh)"
	sh sim/tb_rc6f_held.sh > "$LOG/held.out" 2>&1
	sed 's/^/   /' "$LOG/held.out"
	tail -n 1 "$LOG/held.out" | grep -q '^== ALL RC6F HELD SCENARIOS PASS' || note "held ($(tail -n 1 "$LOG/held.out"))"
fi

# ============================================================================
# mutants
# ============================================================================
# name|groups that must catch it|removed/added lines|sed script (on the rc6 bridge)
MUTANTS='pad8420|1|1/1|s/localparam \[14:0\] PAD_DIAG = 15'"'"'d8419;/localparam [14:0] PAD_DIAG = 15'"'"'d8420;/
nochk|1 3|1/1|s/dg_chk  <= {blob_full_s, chk_magic == ID_MAGIC,/if (1'"'"'b0) dg_chk <= {blob_full_s, chk_magic == ID_MAGIC,/
rangate|2|2/1|/dg_ran  <= 1'"'"'b1;/d; s/cart_load_req <= 1'"'"'b1;/cart_load_req <= 1'"'"'b1; dg_ran <= 1'"'"'b1;/
nosat|5|1/1|s/if (dg_loads != 4'"'"'hF) dg_loads <= dg_loads + 4'"'"'d1;/dg_loads <= dg_loads + 4'"'"'d1;/
heldearly|4|2/2|s/dg_held <= save_busy_i;//; s/dg_held       <= 1'"'"'b0;/dg_held       <= save_busy_i;/
heldnever|1 4|1/1|s/dg_held <= save_busy_i;/dg_held <= 1'"'"'b0;/
drain0|2|1/1|s/cart_img_rd_addr == 14'"'"'d1/cart_img_rd_addr == 14'"'"'d0/
drainany|2|1/1|s/if (cart_img_rd_addr == 14'"'"'d1) dg_drained <= 1'"'"'b1;/dg_drained <= 1'"'"'b1;/
noclear|5|4/0|/dg_chk        <= 5'"'"'d0;/d; /dg_ran        <= 1'"'"'b0;/d; /dg_drained    <= 1'"'"'b0;/d; /dg_held       <= 1'"'"'b0;/d
frzi|1|1/1|s/load_frozen_o, dg_drained, dg_held, 10'"'"'d0}/frozen_i, dg_drained, dg_held, 10'"'"'d0}/
stamp4|1|1/1|s/if (id_cnt == 3'"'"'d4) begin/if (id_cnt == 3'"'"'d3) begin/
noreset|1|1/0|/dg_loads     <= 4'"'"'d0;/d'

# the two mutants of the rc6 follow-up outside the bridge, and the exact
# lines each sed must take out / put in
MB_SED='s/^\tassign save_busy_state = overlay_boot_hold;/\tassign save_busy_state = save_busy;/'
MB_OLD=$(printf '< \tassign save_busy_state = overlay_boot_hold;')
MB_NEW=$(printf '> \tassign save_busy_state = save_busy;')
NA_SED='/^\t\t\tcart_img_rd_addr <= 14'"'"'d0;/d'
NA_OLD=$(printf '< \t\t\tcart_img_rd_addr <= 14'"'"'d0;')

if [ "$MODE" = all ] || [ "$MODE" = mutants ]; then
	echo "== RC6F mutants"
	NAMES=""
	TMPL=$(mktemp)
	echo "$MUTANTS" > "$TMPL"
	while IFS='|' read -r name groups counts script; do
		m=sim/tb_rc6f_mut_$name.sv
		mutate "$name" "$BRIDGE" "$m" "$counts" "$script" || continue
		if ! build "mut_$name" "$m" "$SBIDEF"; then note "mutant $name: build failed"; continue; fi
		echo "   $name: $counts (removed/added) line(s) as meant, must fail group(s) $groups"
		NAMES="$NAMES $name"
	done < "$TMPL"
	rm -f "$TMPL"

	# mbusy: ngpc_machine's save_busy_state wired back to busy_o
	MBM=sim/tb_rc6f_mut_mbusy_machine.sv
	MB=""
	if mutate mbusy "$MACHINE" "$MBM" 1/1 "$MB_SED"; then
		MBDEF=$(sbi_define "$MBM"); mbrc=$?
		if [ "$(diff "$MACHINE" "$MBM" | grep '^<' | tr -d '\r')" != "$MB_OLD" ] ||
		   [ "$(diff "$MACHINE" "$MBM" | grep '^>' | tr -d '\r')" != "$MB_NEW" ]; then
			note "mutant mbusy: the sed did not change exactly the save_busy_state assignment"
		elif [ "$mbrc" -ne 0 ] || [ "$MBDEF" != "-DRC6F_SBI_BUSY" ]; then
			note "mutant mbusy: tb_rc6f_mkheld.py --wiring did not read busy_o from it"
		elif ! python3 sim/tb_rc6f_mkheld.py --machine "$MBM" --out sim/tb_rc6f_mut_mbusy_held.sv > /dev/null; then
			note "mutant mbusy: tb_rc6f_mkheld.py failed"
		elif ! iverilog -g2012 -D SYNTHESIS -DNGPC_SAVE_DIAG=1 -o sim/tb_rc6f_mut_mbusy_held.vvp -s tb_rc6f_held \
		           $HELDSRC "$CART" sim/tb_rc6f_mut_mbusy_held.sv; then
			note "mutant mbusy: the held build failed"
		elif ! build mut_mbusy_stamp "$BRIDGE" "$MBDEF"; then
			note "mutant mbusy: the stamp build failed"
		else
			echo "   mbusy: 1/1 line(s) as meant (save_busy_state = save_busy); the wiring read back: busy_o; must fail HELD-LATE and stamp group 4"
			MB=1
		fi
	fi
	# noaddrrst: ngpc_state_cart without the cart_img_rd_addr reset
	NAC=sim/tb_rc6f_mut_noaddrrst_cart.sv
	NA=""
	if mutate noaddrrst "$CART" "$NAC" 1/0 "$NA_SED"; then
		if [ "$(diff "$CART" "$NAC" | grep '^<' | tr -d '\r')" != "$NA_OLD" ]; then
			note "mutant noaddrrst: the sed did not remove exactly the reset of cart_img_rd_addr"
		elif ! python3 sim/tb_rc6f_mkheld.py > /dev/null; then
			note "mutant noaddrrst: tb_rc6f_mkheld.py failed"
		elif ! iverilog -g2012 -D SYNTHESIS -DNGPC_SAVE_DIAG=1 -o sim/tb_rc6f_mut_noaddrrst_held.vvp -s tb_rc6f_held \
		           $HELDSRC "$NAC" sim/tb_rc6f_held.sv; then
			note "mutant noaddrrst: build failed"
		else
			echo "   noaddrrst: 1/0 line(s) as meant (the reset's cart_img_rd_addr <= 14'd0); must fail C3-REAL"
			NA=1
		fi
	fi

	# the rc5 bridge: in "all" mode its bench run above already decided it
	RC5G=""
	if [ "$MODE" = mutants ]; then build rc5 sim/tb_rc6f_rc5_bridge.sv "-DRC6F_RC5 $SBIDEF" && RC5G=1; fi
	{
		[ -n "$MB" ] && echo "mut_mbusy_held mut_mbusy_held +SCN=HELD-LATE +CAPDIR=$OUT/mut"
		[ -n "$NA" ] && echo "mut_noaddrrst_held mut_noaddrrst_held +SCN=C3-REAL +CAPDIR=$OUT/mut"
		[ -n "$MB" ] && echo "mut_mbusy_stamp mut_mbusy_stamp_g4 +GROUP=4 +OUT=$OUT/mut +STOPFAIL"
		echo "$MUTANTS" | while IFS='|' read -r name groups counts script; do
			case " $NAMES " in *" $name "*) for g in $groups; do echo "mut_$name mut_${name}_g$g +GROUP=$g +OUT=$OUT/mut +STOPFAIL"; done ;; esac
		done
		[ -n "$RC5G" ] && echo "rc5 rc5_g1 +GROUP=1 +OUT=$OUT/mut +STOPFAIL"
	} | run_jobs
	for name in $NAMES rc5; do
		if [ "$name" = rc5 ]; then
			tag=rc5; groups=1
			[ "$MODE" = all ] && groups="$GROUPS"
		else
			tag=mut_$name
			groups=$(echo "$MUTANTS" | grep "^$name|" | cut -d'|' -f2)
		fi
		caught=""
		for g in $groups; do
			f=$LOG/${tag}_g$g.log
			if [ -f "$f" ] && grep -q "^== RC6F GROUP $g: .*FAILURE\|STOPPED AT FIRST FAILURE" "$f"; then
				caught="$caught g$g:$(grep -m1 '^   FAIL' "$f" | sed 's/^   FAIL //' | cut -c1-100)"
			fi
		done
		if [ -n "$caught" ]; then echo "   killed $name --$caught"
		else echo "   SURVIVED $name"; note "mutant $name survived"; fi
	done
	# mbusy must fail HELD-LATE on held = 1, and the stamp bench's group 4
	if [ -n "$MB" ]; then
		f=$LOG/mut_mbusy_held.log; s=$LOG/mut_mbusy_stamp_g4.log
		k1=""; k2=""
		grep -q '^   FAIL \[HELD-LATE\] held = 1, but the boot apply did not hold' "$f" && k1=1
		grep -q '^== RC6F GROUP 4: .*FAILURE\|STOPPED AT FIRST FAILURE' "$s" && k2=1
		if [ -n "$k1" ] && [ -n "$k2" ]; then
			echo "   killed mbusy -- HELD-LATE: $(grep -m1 '^   HELD-LATE: word 8419' "$f" | sed 's/^   HELD-LATE: //') | stamp g4:$(grep -m1 '^   FAIL' "$s" | sed 's/^   FAIL //' | cut -c1-100)"
		else
			echo "   SURVIVED mbusy (HELD-LATE caught: ${k1:-no}, stamp group 4 caught: ${k2:-no})"
			note "mutant mbusy survived"
		fi
	fi
	# noaddrrst must fail C3-REAL on drained = 1
	if [ -n "$NA" ]; then
		f=$LOG/mut_noaddrrst_held.log
		if grep -q '^   FAIL \[C3-REAL\] word 8419 = d113e800' "$f"; then
			echo "   killed noaddrrst -- C3-REAL: $(grep -m1 '^   FAIL \[C3-REAL\]' "$f" | sed 's/^   FAIL \[C3-REAL\] //' | cut -c1-150)"
		else
			echo "   SURVIVED noaddrrst ($(tail -n 1 "$f"))"
			note "mutant noaddrrst survived"
		fi
	fi
fi

if [ "$NF" -eq 0 ]; then
	echo "== ALL RC6 STAMP SCENARIOS PASS"
	exit 0
fi
echo "== $NF FAILURE(S):$SUMMARY"
exit 1
