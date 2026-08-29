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
