#!/bin/sh
# RC6A: build the engine mutants from the REAL rc6 target/pocket/ngpc_cart_save.sv
# (read only) into sim/tb_rc6a_mut_<name>.sv, one rc6 change removed or
# broken in each. Each sed must change exactly one line, and the new line must
# contain what the mutant is about, or the script fails: the RTL moved and the
# mutant would test nothing.
#
#   R1 (saveless_erased) and its terms
#   nor1     R1 removed: the reject test no longer ORs in saveless_erased
#   nodata   saveless_erased without !image_has_data
#   noprog   saveless_erased without !prog_since_publish
#   noovf    saveless_erased without !pack_overflow
#   nodeliv  saveless_erased without its no-file / no-apply terms
#            (!apf_delivered && !pre_delivered && !base_q), as tb_r6a did
#   nobase   saveless_erased without !base_q alone
#   the follow-up's program/erase classifier (R1 made program-aware)
#   pend     (m1) saveless_erased back to !stage_pending in place of
#            !prog_since_publish (rc6 R1 before the follow-up)
#   progall  (m2) the classifier forced to "program": prog_event is every
#            flash event
#   prog0    (m3) the classifier forced to "erase": prog_event is never set
#   nopubclr a publish no longer clears prog_since_publish
#   norestart die 0's busy count no longer restarts when busy rises (only
#            the event clears it): a count an erase cut by a reset left
#            saturated reads the next program as an erase (classify bench)
#   the flash-idle guard
#   noguard  S_IDLE takes a state request whatever the dies are doing (the
#            rc5 condition)
# Called by sim/run_rc6_r1.sh and sim/tb_rc6a_t9s.sh.
set -e
cd "$(dirname "$0")/.."
ENG=target/pocket/ngpc_cart_save.sv
mk() {   # name must-appear-in-the-new-line sed-expression
	out=sim/tb_rc6a_mut_$1.sv
	sed "$3" "$ENG" > "$out"
	n=$(diff "$ENG" "$out" | grep -c '^[<>]' || true)
	if [ "$n" != "2" ]; then
		echo "== 1 FAILURE(S): mutant $1 did not apply to $ENG ($n diff lines, want 2)"
		exit 1
	fi
	new=$(diff "$ENG" "$out" | grep '^>' | tr -s '\t ' ' ' | tr -d '\r')
	case "$new" in
	*"$2"*) ;;
	*) echo "== 1 FAILURE(S): mutant $1 changed the wrong line: $new"; exit 1 ;;
	esac
	echo "   mutant $1: $new"
}
PE='wire        prog_event = (event0_i \&\& !(\&busy_cnt0)) || (event1_i \&\& !(\&busy_cnt1));'
mk nor1     '(!(|dirty0 || |dirty1))))' \
    's/(!(|dirty0 || |dirty1) || saveless_erased)))/(!(|dirty0 || |dirty1))))/'
mk nodata   '!prog_since_publish && !pack_overflow;' \
    's/!image_has_data \&\& !prog_since_publish \&\& !pack_overflow;/!prog_since_publish \&\& !pack_overflow;/'
mk noprog   '!image_has_data && !pack_overflow;' \
    's/!image_has_data \&\& !prog_since_publish \&\& !pack_overflow;/!image_has_data \&\& !pack_overflow;/'
mk noovf    '!image_has_data && !prog_since_publish;' \
    's/!image_has_data \&\& !prog_since_publish \&\& !pack_overflow;/!image_has_data \&\& !prog_since_publish;/'
mk nodeliv  "wire saveless_erased = 1'b1 &&" \
    "s/wire saveless_erased = !apf_delivered \&\& !pre_delivered \&\& !base_q \&\&/wire saveless_erased = 1'b1 \&\&/"
mk nobase   'wire saveless_erased = !apf_delivered && !pre_delivered &&' \
    's/wire saveless_erased = !apf_delivered \&\& !pre_delivered \&\& !base_q \&\&/wire saveless_erased = !apf_delivered \&\& !pre_delivered \&\&/'
mk pend     '!image_has_data && !stage_pending && !pack_overflow;' \
    's/!image_has_data \&\& !prog_since_publish \&\& !pack_overflow;/!image_has_data \&\& !stage_pending \&\& !pack_overflow;/'
mk progall  'prog_event = event0_i || event1_i;' \
    "s/$PE/wire        prog_event = event0_i || event1_i;/"
mk prog0    "prog_event = 1'b0;" \
    "s/$PE/wire        prog_event = 1'b0;/"
mk nopubclr 'prog_since_publish <= prog_since_publish;' \
    "/image_has_data <= pass_has_data;/{n;s/prog_since_publish <= 1'b0;/prog_since_publish <= prog_since_publish;/;}"
mk norestart 'busy_cnt0 <= busy_cnt0;' \
    "s/else if (die_busy_i\[0\] \&\& !busy_prev\[0\]) busy_cnt0 <= 12'd1;/else if (die_busy_i[0] \&\& !busy_prev[0]) busy_cnt0 <= busy_cnt0;/"
mk noguard  'state_req)) begin' \
    "s/(state_req \&\& die_busy_i == 2'b00))) begin/state_req)) begin/"
