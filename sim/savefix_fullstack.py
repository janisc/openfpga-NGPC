"""Synthetic image through save encoder, state copier, staging arbiter, PSRAM controller.
Only cartridge SDRAM and CellularRAM devices are behavioral models.
"""
from pathlib import Path
import subprocess,json,hashlib
ROOT=Path(__file__).resolve().parents[1];rtl=ROOT/'target/pocket';out=ROOT/'dist/savefix-tests/fullstack';out.mkdir(parents=True,exist_ok=True)
s=(ROOT/'dist/savefix-tests/codec/tb_compressed.sv').read_text()
s=s.replace('module tb_compressed;', 'module tb_fullstack;')
s=s.replace("reg st_done=0,st_pend=0; reg [15:0] st_rdata;", "wire st_done;reg st_pend=0;wire [15:0] st_rdata;wire mem_ready,mem_host_busy,host_ready;reg [15:0] drops;")
s=s.replace('reg [15:0] psram[0:65535],persisted', 'reg [15:0] persisted')
s=s.replace('psram[','cmem[')
s=s.replace('wire actual_host_busy=host_busy || sc_host_wr || host_tail!=0;', 'wire actual_host_busy=host_busy || mem_host_busy;')
s=s.replace("  if(sc_host_wr) cmem[{bank ^ sc_host_addr[16],sc_host_addr[15:1]}]<=sc_host_data;",'')
a=s.index('  st_done<=0;');b=s.index('  if(sc_active && st_req)',a)
s=s[:a]+s[b:]
s=s.replace('.stage_ready_i(1\'b1)', '.stage_ready_i(mem_ready)').replace('.sc_rd_ready(1\'b1)', '.sc_rd_ready(mem_ready)').replace('.sc_host_ready(1\'b1)', '.sc_host_ready(host_ready)')
s=s.replace('st_done=0;st_pend=0;', 'st_pend=0;')
chip=(ROOT/'sim/tb_stage_host.sv').read_text()
chip=chip[chip.index('\treg [15:0] cmem'):chip.index('\t// ---- the test')].replace('clk_sys','clk')
chip=chip.replace("assign cram_dq = 16'hZZZZ;", "assign cram_dq = !cram_ce0_n && !cram_oe_n && cram_adv_n ? cmem[c_addr_l] : 16'hZZZZ;")
wiring=r'''
 wire [21:16] cram_a;wire [15:0] cram_dq;
 wire cram_clk,cram_adv_n,cram_cre,cram_ce0_n,cram_ce1_n,cram_oe_n,cram_we_n,cram_ub_n,cram_lb_n;
 wire [15:0] drop_count;
 ngpc_stage_mem stage_mem (
  .clk(clk),.reset(reset),.active_bank_i(bank),
  .host_wr_i(sc_host_wr),.host_wr_addr_i(sc_host_addr),.host_wr_data_i(sc_host_data),
  .host_rd_i(1'b0),.host_rd_addr_i(25'd0),.host_rd_data_o(),
  .host_busy_o(mem_host_busy),.host_wr_ready_o(host_ready),.diag_beats_o(),.diag_drops_o(drop_count),
  .eng_req_i(mem_req),.eng_we_i(mem_we),.eng_addr_i(mem_addr),.eng_wdata_i(st_wdata),
  .eng_ready_o(mem_ready),.eng_done_o(st_done),.eng_rdata_o(st_rdata),
  .cram_a(cram_a),.cram_dq(cram_dq),.cram_wait(1'b0),.cram_clk(cram_clk),.cram_adv_n(cram_adv_n),
  .cram_cre(cram_cre),.cram_ce0_n(cram_ce0_n),.cram_ce1_n(cram_ce1_n),
  .cram_oe_n(cram_oe_n),.cram_we_n(cram_we_n),.cram_ub_n(cram_ub_n),.cram_lb_n(cram_lb_n));
'''
s=s.replace(' integer i,n,bad,base,prev_writes;',wiring+chip+'\n integer i,n,bad,base,prev_writes;')
s=s[:s.index('  // Replacing an erased')]+'''
  if(drop_count!=0)$fatal(1,"state drain dropped %d words",drop_count);
  $display("ALL PASS synthetic cold restore and state capture/erase/rewind through actual staging/PSRAM RTL; zero FIFO drops");$finish;
 end
 initial begin #10000000000;$fatal(1,"watchdog");end
endmodule
`default_nettype wire
'''
# Larger real PSRAM latency requires more than the quick fake-memory limit.
s=s.replace('n<4000000','n<12000000').replace('n<6000000','n<20000000')
tb=out/'tb_fullstack.sv';tb.write_text(s)
cmd=['iverilog','-g2012','-DNGPC_SAVE_DIAG','-s','tb_fullstack','-o',str(out/'test.vvp'),str(ROOT/'upstream/rtl/cart/ngp_cart_overlay_geometry.sv')]+[str(rtl/f) for f in ('ngpc_cart_save.sv','ngpc_state_cart.sv','ngpc_stage_mem.sv','psram.sv')]+[str(tb)]
c=subprocess.run(cmd,capture_output=True,text=True,cwd=ROOT);(out/'compile.log').write_text(c.stdout+c.stderr);assert c.returncode==0,c.stderr
with (out/'simulation.log').open('w') as log:
 v=subprocess.run(['vvp','-i',str(out/'test.vvp')],stdout=log,stderr=subprocess.STDOUT,cwd=ROOT,timeout=300)
output=(out/'simulation.log').read_text();print(output);assert v.returncode==0
report=dict(result='PASS RTL simulation',output=output,rtl_hashes={f:hashlib.sha256((rtl/f).read_bytes()).hexdigest() for f in ('ngpc_cart_save.sv','ngpc_state_cart.sv','ngpc_stage_mem.sv','psram.sv')},limitations='Actual encoder/decoder, state copier, staging arbiter and PSRAM controller. Behavioral cartridge SDRAM/CellularRAM; synthetic dirty events are synthesized. Cold persisted prefix is injected directly into CellularRAM, not via APF. No FPGA synthesis/pin timing or physical device test.')
(out/'result.json').write_text(json.dumps(report,indent=2)+'\n')
