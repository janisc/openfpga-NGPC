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
foreach dest [list $pocket_sr_to] {
	foreach coll $pocket_tick_sources {
		set_multicycle_path -setup -from $coll -to $dest 2
		set_multicycle_path -hold  -from $coll -to $dest 1
	}
}
