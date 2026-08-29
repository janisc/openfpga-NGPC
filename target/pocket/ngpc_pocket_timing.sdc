# NGPC for Analogue Pocket -- timing exceptions specific to this target.
#
# Read AFTER the upstream NGPC.sdc, which it extends rather than replaces.
#
# WHY THIS FILE EXISTS
#
# The Pocket's FPGA is a 5CEBA4F23C8 -- speed grade 8, where MiSTer's
# 5CSEBA6U23I7 is grade 7. The TLCS-900H register-file write cone is deeper
# than one 20.345 ns clk_sys period on either part, which is why upstream
# multicycles it at all; on the slower grade the fitter simply surfaces two
# more members of the same family.
#
# Upstream states the rule these follow, and states it narrowly on purpose:
# a source that can only change on a ce_t900_g tick, feeding storage that can
# only commit on a ce_t900_g tick, is a two-cycle path, because ce is at most
# one clk_sys pulse in sixteen and run/halt/pause gating can only increase that
# spacing. "Decode inputs, read/write data, other sequencer registers, other
# BIU registers, and savestate data remain single-cycle timed" -- that stays
# true here. Every register below was checked against that rule individually.
#
# Do not add to this file by pattern-matching a failing path name. Open the
# RTL, find the register's always block, and confirm it has no update path
# outside reset / restore_hold / `else if (ce)`.

set pocket_regfile_to [get_registers {*|t900_regfile:u_regfile|regs*}]
set pocket_biu_addr_to [get_registers {*|t900_biu:u_biu|bus_addr_r*}]

if {[get_collection_size $pocket_regfile_to] == 0} {
	post_message -type error "ngpc_pocket_timing.sdc: no TLCS register-file storage matched"
}
if {[get_collection_size $pocket_biu_addr_to] == 0} {
	post_message -type error "ngpc_pocket_timing.sdc: no TLCS BIU address registers matched"
}

# t900_seq.sv: declared at 351, written only at 3352 under `retire_now`, inside
# the sequencer's `else if (ce)` state block that opens at 2775. The only other
# writers are the reset branch (2681) and the savestate restore path (3405),
# neither of which coexists with a register-file commit.
set pocket_irq_shadow_from [get_registers {*|t900_seq:u_seq|irq_shadow}]

# t900_seq.sv: declared at 414. Written in reset (2692), in restore_hold (2767)
# and inside `else if (ce)` (2777, 2937). This is the exact structure upstream
# documents for wr_pend -- "apart from reset/restore, when ce_t900_g and normal
# register-file writes are suppressed".
set pocket_q_flush_from [get_registers {*|t900_seq:u_seq|q_flush_r}]

# t900_biu.sv: declared at 198. Every write (419, 424, 564) is inside the BIU's
# `else if (ce)` block opening at 414; the remaining assignment at 408 is the
# reset branch. Note this is a BIU register, which upstream's comment otherwise
# holds to single-cycle timing -- it is listed here because it was checked, not
# because BIU registers are exempt as a class.
set pocket_q_valid_from [get_registers {*|t900_biu:u_biu|q_valid*}]

foreach {name coll} [list \
		irq_shadow $pocket_irq_shadow_from \
		q_flush_r  $pocket_q_flush_from \
		q_valid    $pocket_q_valid_from] {
	if {[get_collection_size $coll] == 0} {
		post_message -type error "ngpc_pocket_timing.sdc: no TLCS $name register matched"
	}
	set_multicycle_path -setup -from $coll -to $pocket_regfile_to 2
	set_multicycle_path -hold  -from $coll -to $pocket_regfile_to 1
	set_multicycle_path -setup -from $coll -to $pocket_biu_addr_to 2
	set_multicycle_path -hold  -from $coll -to $pocket_biu_addr_to 1
}

# ---------------------------------------------------------------------------
# The rest of the tick-domain storage, as DESTINATIONS.
#
# Upstream constrains two destinations: the register file and the BIU address
# register. Both are chosen for the same reason -- they commit only on a
# ce_t900_g tick -- and both were enough on grade-7 silicon. Two more members of
# that same set surface here once the cartridge SDRAM service is competing for
# placement:
#
#   sr    t900_seq.sv, written at 2677 (reset), 2938 and 3155. The latter two
#         are inside the `else if (ce)` branch opening at 2775 of the always
#         block at 2673.
#   st.*  the sequencer state itself, same always block, same ce branch.
#         Upstream already treats st.* as a ce-qualified SOURCE, so its
#         tick-only behaviour is upstream's own claim, not a new one.
#
# The sources are every collection upstream established plus the three added
# above. Each is frozen between ticks; none of them is a decode or read hold,
# which load on every !ce cycle and stay single-cycle timed.
#
# The collections named with $ come from upstream's NGPC.sdc, which the project
# reads first. If upstream renames one, this fails loudly rather than silently
# dropping an exception.

set pocket_sr_to [get_registers {*|t900_seq:u_seq|sr*}]
set pocket_st_to [get_registers {*|t900_seq:u_seq|st.*}]

foreach {name coll} [list sr $pocket_sr_to st $pocket_st_to] {
	if {[get_collection_size $coll] == 0} {
		post_message -type error "ngpc_pocket_timing.sdc: no TLCS $name storage matched"
	}
}

set pocket_tick_sources [list 	$t900_state_mc_from 	$t900_sr_mc_from 	$t900_wr_pend_mc_from 	$t900_int_req_mc_from 	$t900_int_level_mc_from 	$t900_dma_req_mc_from 	$t900_pause_req_mc_from 	$pocket_irq_shadow_from 	$pocket_q_flush_from 	$pocket_q_valid_from]

# st.* is deliberately NOT in this list. It qualifies on the same argument sr
# does, and adding it is legal -- but measured, it made the design worse:
# -0.365 ns became -1.390 ns. Marking more paths as two-cycle changes what
# register retiming chooses to do, and it spent the freedom somewhere that hurt
# the paths still timed at one cycle. Timing is not monotonic in how much you
# relax, so this list is what measured best, not what could be justified.
# ---------------------------------------------------------------------------
# THE DESTINATION GAP.
#
# Upstream constrains two destinations: the register file and the BIU address
# register. On grade-7 silicon that was enough. Here it is not, and the reason
# is visible in the failing set rather than in any new claim about the CPU:
# nearly every failing source below is one upstream ALREADY established as
# tick-qualified (int_req_hold, int_level_hold, dma_req_hold, pause_req_hold,
# st.*, sr*, wr_pend). They fail only because they also reach BIU registers
# that no -to list covers.
#
#   bus_wdata_r   t900_biu.sv:174. Reset at 399, written at 479/491/539 and in
#                 the tasks at 631/665/726/740, whose only call sites (447, 457,
#                 508, 517, 520, 541, 548, 574, 577, 603) all sit inside the
#                 `else if (ce)` branch opening at 414. The always block at 389
#                 closes at 616 with no trailing else.
#   bc_two_bytes  t900_biu.sv:178. Same block, same reset list (393), same ce
#                 branch (477, 489, 629, 663, 724, 738).
#
# Both are siblings of bus_addr_r (declared and reset at 397 in that same list),
# which upstream already exempts -- this is the same block's ce-qualification,
# not a wider one.
#
# NOT bus_wdata_h. The generate block at 800 loads the output holds on `!ce`,
# which is the decode-hold structure, and stays single-cycle timed.
set pocket_biu_wdata_to [get_registers {*|t900_biu:u_biu|bus_wdata_r*}]
set pocket_biu_bc2_to   [get_registers {*|t900_biu:u_biu|bc_two_bytes}]

# ---------------------------------------------------------------------------
# FOUR MORE TICK-QUALIFIED SOURCES.
#
# t900_seq.sv has exactly one sequential always block (2673); every other
# always in the file is combinational. So for a sequencer register the only
# question is which branch each write sits in -- reset (from 2674), the
# destructive-restore branch (2762-2774), or `else if (ce)` (2775 onward).
#
#   queue_refill  declared 416. Reset at 2733; cleared at 2784/2785 inside the
#                 ce branch. Absent from the restore branch entirely. This is
#                 the largest single contributor to the failing set.
#   k1_r          declared 380. Reset at 2702, written 2986 and 3029.
#   grp_r         declared 384. Reset at 2706, written 2990 and 3033.
#
#   drdata        t900_biu.sv:127. Reset at 405; every write (687-696) is inside
#                 place_read, called only at 508 within the ce branch.
#
# NOT the dec_*_hold family. t900_cpu.sv:552 loads them under `if (!ce)` --
# they reload on every non-tick cycle and are genuinely single-cycle timed.
# dec_needs_byte1_hold appears in the failing set and stays there; that path
# has to be met by placement, not by a constraint.
set pocket_queue_refill_from [get_registers {*|t900_seq:u_seq|queue_refill}]
set pocket_k1_r_from         [get_registers {*|t900_seq:u_seq|k1_r*}]
set pocket_grp_r_from        [get_registers {*|t900_seq:u_seq|grp_r*}]
set pocket_drdata_from       [get_registers {*|t900_biu:u_biu|drdata*}]

foreach {name coll} [list \
		biu_wdata    $pocket_biu_wdata_to \
		biu_bc2      $pocket_biu_bc2_to \
		queue_refill $pocket_queue_refill_from \
		k1_r         $pocket_k1_r_from \
		grp_r        $pocket_grp_r_from \
		drdata       $pocket_drdata_from] {
	if {[get_collection_size $coll] == 0} {
		post_message -type error "ngpc_pocket_timing.sdc: no TLCS $name register matched"
	}
}

# st.* is deliberately NOT a destination. It qualifies on the same argument sr
# does, and adding it is legal -- but measured, it made the design worse:
# -0.365 ns became -1.390 ns. Marking more paths as two-cycle changes what the
# fitter does with the freedom, and it spent it somewhere that hurt the paths
# still timed at one cycle. Timing is not monotonic in how much you relax, so
# this list is what measured best, not what could be justified.
lappend pocket_tick_sources \
	$pocket_queue_refill_from \
	$pocket_k1_r_from \
	$pocket_grp_r_from \
	$pocket_drdata_from

foreach dest [list $pocket_sr_to $pocket_regfile_to $pocket_biu_addr_to \
		$pocket_biu_wdata_to $pocket_biu_bc2_to] {
	foreach coll $pocket_tick_sources {
		set_multicycle_path -setup -from $coll -to $dest 2
		set_multicycle_path -hold  -from $coll -to $dest 1
	}
}

# ---------------------------------------------------------------------------
# THE DECODE HOLDS -- TRIED, LEFT OUT.
#
# The dec_*_hold and q_byte_hold registers load under `if (!ce)`
# (t900_cpu.sv:484, 487, 489-501), so static timing sees them launching one
# cycle before a tick. Functionally they do not: the queue they descend from is
# written only inside the BIU's `else if (ce)` branch (t900_biu.sv:555, 556,
# 560), q_rd advances only there (418), and no savestate path writes the queue
# at all. So q_byte_hold takes its value on the first cycle after a tick,
# dec_*_hold on the second, and every reload after that is a no-op -- which is
# upstream's own stated invariant in the t900_cpu.sv header ("correct from the
# THIRD clk_sys cycle after a tick ... ticks must be at least four clk_sys
# cycles apart; they are sixteen at the fastest gear").
#
# The argument is sound as far as it goes. The exception is still not here, for
# two reasons.
#
# It showed no benefit. It measured -3.123 ns where the same configuration
# without it measured -2.852 -- but that comparison proves nothing either way,
# because this project builds with NUM_PARALLEL_PROCESSORS 6 and the parallel
# fitter is not reproducible: the SAME configuration measured -2.852 on one run
# and -3.107 on another. Anything under about 0.3 ns here is noise. What can be
# said is that it did not help.
#
# And it is the one exception in this file whose safety argument is ours rather
# than upstream's. Every other exception rests on an enable that is false except
# on ticks, so naming the tick spacing is the whole proof. This one rests on the
# claim that reloads do not change the value -- a claim about the input cone,
# which is a longer chain and one upstream deliberately does not make. Its
# failure mode is not a timing failure but a rare wrong decode under some gear
# and prefetch alignment: one instruction taking a wrong operand, in one game,
# after a long session.
#
# An unmeasurable gain does not buy that risk. If a future change makes the
# decode cone the thing standing between this core and closure, re-derive it
# from the RTL and measure it properly -- several runs per configuration,
# because one run cannot tell 0.25 ns from luck.
