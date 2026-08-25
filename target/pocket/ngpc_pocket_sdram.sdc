# SDRAM pin timing for the Analogue Pocket.
#
# Adapted from upstream's rtl/mem/sdram.sdc, which cannot be used as-is: it
# names MiSTer's top-level SDRAM_* ports and MiSTer's PLL instance path. The
# reasoning in that file is the reasoning here -- read it for why the forwarded
# pin clock is modelled as a generated clock and why the DQ capture carries a
# two-cycle setup.
#
# Read AFTER the SDC that runs derive_pll_clocks (platform/pocket/apf_constraints.sdc),
# so the controller clock exists before the generated pin clock is derived.
#
# TWO DIFFERENCES FROM MiSTer, both worth knowing:
#
#   1. No chip select. The Pocket has no SDRAM CS pin; it is tied low on the
#      board, so SDRAM_nCS is left unconnected and is absent from the port list
#      below.
#
#   2. The delay numbers are still MiSTer's. They describe a board -- trace
#      lengths and a specific SDRAM part -- and the Pocket is neither. They are
#      a starting point that closes timing, not a measured fit. If the
#      cartridge image ever comes back subtly wrong (a few bad words rather
#      than nothing at all), this file is the first suspect, and the honest fix
#      is the Pocket SDRAM's own tAC/tOH against its actual routing.

set sdram_ctrl_clk_pin {ic|mp1|ngpc_pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}

set sdram_ctrl_clk [get_clocks $sdram_ctrl_clk_pin]
if {[get_collection_size $sdram_ctrl_clk] == 0} {
	post_message -type error "ngpc_pocket_sdram.sdc: no controller clock matched the configured pin"
}

# dram_clk is an inverted copy of the controller clock forwarded through the
# output DDIO cell. Modelling it as a generated clock ON the pin accounts for
# the forward path's insertion delay; without it every output pin reports a
# large fictitious clock skew.
create_generated_clock -name sdram_clk_pin -invert \
	-source [get_pins $sdram_ctrl_clk_pin] \
	[get_ports {dram_clk}]

if {[get_collection_size [get_clocks sdram_clk_pin]] == 0} {
	post_message -type error "ngpc_pocket_sdram.sdc: no dram_clk generated pin clock matched"
}

set sdram_out_ports [get_ports {dram_cke dram_a[*] dram_ba[*] dram_dqm[*] \
	dram_cas_n dram_ras_n dram_we_n dram_dq[*]}]

# Outputs launch on the controller clock rising edge and are sampled by the
# SDRAM on the dram_clk edge a half period later. The inversion lives in the
# generated clock, so no -clock_fall qualifier is used here.
set_output_delay -clock sdram_clk_pin -max 1.500 $sdram_out_ports
set_output_delay -clock sdram_clk_pin -min -0.800 $sdram_out_ports

# DQ is launched by the SDRAM tAC after a dram_clk edge, so the forwarded pin
# clock is the correct launch reference.
set_input_delay -clock sdram_clk_pin -max 6.000 [get_ports {dram_dq[*]}]
set_input_delay -clock sdram_clk_pin -min 2.500 [get_ports {dram_dq[*]}]

# The forwarded clock leaves the FPGA a full clock-network insertion after the
# internal capture edge, so the beat launched by pin-clock edge N is captured by
# the internal falling edge one period later.
set_multicycle_path -setup 2 -from [get_ports {dram_dq[*]}]
set_multicycle_path -hold 1 -from [get_ports {dram_dq[*]}]

# sdram.sv connects only `dataout_l` of the input DDIO cell; the rising-edge
# half is left unconnected. Its register still exists inside the hard cell, so
# exclude the dangling capture instead of reporting it as a real violation.
set dq_unused_rise_regs [get_registers {*altddio_in:u_sdram_dq_capture*dataout_h*}]
if {[get_collection_size $dq_unused_rise_regs] > 0} {
	set_false_path -to $dq_unused_rise_regs
}
