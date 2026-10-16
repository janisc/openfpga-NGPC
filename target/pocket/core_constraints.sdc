#
# NGPC for Analogue Pocket -- core constraints.
#
# APF's own clocks and derive_pll_clocks are in platform/pocket/apf_constraints.sdc.
# The machine's internal exceptions come from upstream's NGPC.sdc plus
# ngpc_pocket_timing.sdc, both listed in the project.
#

set clk_sys_c    {ic|mp1|ngpc_pll_inst|altera_pll_i|*[0].*|divclk}
set clk_ram_c    {ic|mp1|ngpc_pll_inst|altera_pll_i|*[1].*|divclk}
set clk_sys90_c  {ic|mp1|ngpc_pll_inst|altera_pll_i|*[2].*|divclk}
set clk_dot_c    {ic|mp1|ngpc_pll_inst|altera_pll_i|*[3].*|divclk}

# clk_sys and clk_ram come from one PLL and are crossed with plain synchronous
# handshakes inside the cartridge SDRAM service. Upstream's NGPC.sdc says it
# outright: NEVER put them in separate groups, the crossing's correctness
# depends on being timed as related clocks. They are deliberately in one group
# here, together with the 90-degree copy of clk_sys that feeds the video pads.
set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group [list $clk_sys_c $clk_ram_c $clk_sys90_c $clk_dot_c]

derive_clock_uncertainty

# The link port (ngpc_link.sv). The partner Pocket runs on its own clock, so SI,
# and SO and SD read back, are asynchronous and land on two-flop synchronisers;
# SO, SD and their directions change at most once per 48 clk_sys cycles and
# nothing samples them against this design's clock. No link pin has an I/O
# timing requirement.
set_false_path -from [get_ports {port_tran_si port_tran_so port_tran_sd}]
set_false_path -to   [get_ports {port_tran_so port_tran_so_dir port_tran_sd port_tran_sd_dir}]
