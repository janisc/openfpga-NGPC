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
