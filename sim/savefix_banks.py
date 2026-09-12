"""Exercise patched stage bank mapping and arbitration with actual PSRAM RTL."""
from pathlib import Path
import subprocess,json
ROOT=Path(__file__).resolve().parents[1];rtl=ROOT/'target/pocket';out=ROOT/'dist/savefix-tests/banks';out.mkdir(parents=True,exist_ok=True)
original=(ROOT/'sim/tb_stage_host.sv').read_text()
chip=original[original.index('\treg [15:0] cmem'):original.index('\t// ---- the test')]
chip=chip.replace("assign cram_dq = 16'hZZZZ;", "assign cram_dq = !cram_ce0_n && !cram_oe_n && cram_adv_n ? cmem[c_addr_l] : 16'hZZZZ;")
sv=r'''
`timescale 1ns/1ps
`default_nettype none
module tb_bank;
 reg clk_sys=0;always #10.173 clk_sys=~clk_sys;
 reg reset=1,bank=0,hw=0,hr=0,er=0,ew=0;
 reg [24:0] ha=0,ea=0;
 reg [15:0] hd=0,ed=0;
 wire [15:0] host_data,eng_data;
 wire host_busy,ready,done;
 wire [21:16] cram_a;wire [15:0] cram_dq;
 wire cram_clk,cram_adv_n,cram_cre,cram_ce0_n,cram_ce1_n,cram_oe_n,cram_we_n,cram_ub_n,cram_lb_n;
 ngpc_stage_mem dut (
  .clk(clk_sys),.reset(reset),.active_bank_i(bank),
  .host_wr_i(hw),.host_wr_addr_i(ha),.host_wr_data_i(hd),
  .host_rd_i(hr),.host_rd_addr_i(ha),.host_rd_data_o(host_data),.host_busy_o(host_busy),
  .diag_beats_o(),.diag_drops_o(),
  .eng_req_i(er),.eng_we_i(ew),.eng_addr_i(ea),.eng_wdata_i(ed),
  .eng_ready_o(ready),.eng_done_o(done),.eng_rdata_o(eng_data),
  .cram_a(cram_a),.cram_dq(cram_dq),.cram_wait(1'b0),.cram_clk(cram_clk),.cram_adv_n(cram_adv_n),
  .cram_cre(cram_cre),.cram_ce0_n(cram_ce0_n),.cram_ce1_n(cram_ce1_n),
  .cram_oe_n(cram_oe_n),.cram_we_n(cram_we_n),.cram_ub_n(cram_ub_n),.cram_lb_n(cram_lb_n));
'''+chip+r'''
 integer n;
 task host_write(input [24:0] address,input [15:0] value);
 begin
  @(negedge clk_sys);ha=address;hd=value;hw=1;#1;
  if(!host_busy)$fatal(1,"host busy misses first write beat");
  @(negedge clk_sys);hw=0;
 end endtask
 task host_read(input [24:0] address,input [15:0] expected);
 begin
  @(negedge clk_sys);ha=address;hr=1;#1;
  if(!host_busy)$fatal(1,"host busy misses first read beat");
  @(negedge clk_sys);hr=0;
  repeat(100)@(negedge clk_sys);
  if(host_data!==expected)$fatal(1,"host read %h got %h expected %h",address,host_data,expected);
 end endtask
 task engine(input bit we,input [24:0] address,input [15:0] value);
 begin
  n=0;while(!ready && n<1000)begin @(negedge clk_sys);n=n+1;end
  if(!ready)$fatal(1,"engine ready stuck");
  @(negedge clk_sys);er=1;ew=we;ea=address;ed=value;
  @(negedge clk_sys);er=0;n=0;
  while(!done && n<1000)begin @(negedge clk_sys);n=n+1;end
  if(!done)$fatal(1,"engine transaction lost");
  if(!we && eng_data!==value)$fatal(1,"engine read mismatch %h != %h",eng_data,value);
  @(negedge clk_sys);
 end endtask
 initial begin
  repeat(10)@(negedge clk_sys);reset=0;
  repeat(10)@(negedge clk_sys);
  host_write(0,16'h1111);repeat(100)@(negedge clk_sys);
  if(cmem[0]!==16'h1111)$fatal(1,"bank zero host mapping");
  engine(1,25'h10000,16'h2222);
  host_read(0,16'h1111);bank=1;host_read(0,16'h2222);
  host_write(2,16'h3333);repeat(100)@(negedge clk_sys);
  if(cmem[32769]!==16'h3333)$fatal(1,"bank one host mapping");
  // State drain addresses select the opposite bank relative to active.
  host_write(25'h10002,16'h4444);repeat(100)@(negedge clk_sys);
  if(cmem[1]!==16'h4444)$fatal(1,"state scratch-bank mapping");
  engine(0,25'h10002,16'h3333);engine(0,25'h00002,16'h4444);
  // Latch bank at ingress even while a write waits behind another operation.
  host_write(4,16'h5555);bank=0;
  repeat(100)@(negedge clk_sys);
  if(cmem[32770]!==16'h5555)$fatal(1,"FIFO address did not retain ingress bank");
  // Simultaneous host/engine requests: host priority must retain engine work.
  @(negedge clk_sys);ha=6;hd=16'h6666;hw=1;er=1;ew=1;ea=25'h10006;ed=16'h7777;
  @(negedge clk_sys);hw=0;er=0;n=0;
  while(!done && n<1000)begin @(negedge clk_sys);n=n+1;end
  if(!done)$fatal(1,"host arbitration lost engine request");
  repeat(100)@(negedge clk_sys);
  if(cmem[3]!==16'h6666 || cmem[32771]!==16'h7777)$fatal(1,"concurrent writes misrouted");
  $display("PASS actual stage_mem/PSRAM RTL: both banks, host reads, inactive state writes, FIFO bank latch, simultaneous host/engine arbitration");
  $finish;
 end
 initial begin #1000000;$fatal(1,"watchdog");end
endmodule
`default_nettype wire
'''
tb=out/'tb_bank.sv';tb.write_text(sv)
cmd=['iverilog','-g2012','-s','tb_bank','-o',str(out/'test.vvp'),str(rtl/'ngpc_stage_mem.sv'),str(rtl/'psram.sv'),str(tb)]
c=subprocess.run(cmd,capture_output=True,text=True,cwd=ROOT);(out/'compile.log').write_text(c.stdout+c.stderr);assert c.returncode==0,c.stderr
v=subprocess.run(['vvp','-i',str(out/'test.vvp')],capture_output=True,text=True,cwd=ROOT,timeout=30);(out/'simulation.log').write_text(v.stdout+v.stderr);print(v.stdout);assert v.returncode==0,v.stderr
(out/'result.json').write_text(json.dumps(dict(result='PASS',output=v.stdout,limitations='Actual stage_mem and PSRAM controller RTL against behavioral CellularRAM; no pin timing/device validation.'),indent=2)+'\n')
