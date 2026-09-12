"""Actual patched save RTL + state-cart copier, modeled SDRAM/PSRAM/APF.
All fixtures are generated; no ROM, BIOS or native save files are used.
No CPU, gameplay, timing or physical Pocket execution.
"""
from pathlib import Path
import hashlib,json,struct,subprocess,zlib,sys
ROOT=Path(__file__).resolve().parents[1]
out=ROOT/'dist/savefix-tests/codec';out.mkdir(parents=True,exist_ok=True)
# Entirely synthetic 4 MiB cartridge. No external ROM, BIOS or save input.
rom=bytearray(4*1024*1024)
for i in range(len(rom)//2):
 struct.pack_into('<H',rom,i*2,(i*73 + (i>>8)*19 + 0x1357)&0xffff)
gold=bytearray(rom)
# Four complete physical blocks total 112 KiB, beyond the old 63 KiB payload.
blocks=[(0x3e0000,65536),(0x3f0000,32768),(0x3f8000,8192),(0x3fa000,8192)]
for block_index,(address,size) in enumerate(blocks):
 offset=address-0x200000
 gold[offset:offset+size]=bytes([255])*size
 for i in range(1024):
  word=0xffff if i%31==0 else (i*97 + block_index*211 + 7)%65535
  struct.pack_into('<H',gold,offset+2*i,word)
 struct.pack_into('<H',gold,offset+size-2,0x1234+block_index)
def hexfile(name,buf):
 (out/name).write_text(''.join(f'{w[0]:04x}\n' for w in struct.iter_unpack('<H',buf)))
hexfile('pristine.hex',rom);hexfile('synthetic_saved.hex',gold)
# Independent reference encoder for the V3 format used by RTL (FFFF/count).
def encode(raw):
 words=list(struct.unpack('<'+'H'*(len(raw)//2),raw));packed=[];i=0
 while i<len(words):
  if words[i]!=65535: packed.append(words[i]);i+=1
  else:
   end=i+1
   while end<len(words) and words[end]==65535:end+=1
   packed.extend((65535,end-i));i=end
 return packed
payload=[]
for address,size in blocks: payload+=encode(gold[address-0x200000:address-0x200000+size])
header=[0x4e47,0x5043,0x5341,0x5633,0xca57,0x600d,0x40,0,0,0xc000,3,0,0,0,0,0,256+len(payload),15]
def crc(words): return zlib.crc32(struct.pack('<'+'H'*len(words),*words)) ^ 0xffffffff
pc=crc(payload);header += [pc&65535,pc>>16];hc=crc(header);header += [hc&65535,hc>>16]
reference=header+[0]*(256-len(header))+payload+[0]*(32512-256-len(payload))
hexfile('reference.hex',struct.pack('<'+'H'*len(reference),*reference))
# Negative cases with correct checksums prove structural validation as well.
def fixture(name,mod):
 h=header[:];p=payload[:];mod(h,p)
 pc=crc(p);h[18:20]=[pc&65535,pc>>16];hc=crc(h[:20]);h[20:22]=[hc&65535,hc>>16]
 w=h+[0]*(256-len(h))+p+[0]*(32512-256-len(p));hexfile(name+'.hex',struct.pack('<'+'H'*len(w),*w))
first=payload.index(65535)
fixture('zero_run',lambda h,p:p.__setitem__(first+1,0))
fixture('overrun',lambda h,p:p.__setitem__(first+1,65535))
fixture('invalid_bitmap',lambda h,p:h.__setitem__(11,0x8000))
fixture('short_length',lambda h,p:h.__setitem__(16,h[16]-1))
fixture('wrong_size',lambda h,p:h.__setitem__(7,2))
fixture('wrong_geometry',lambda h,p:h.__setitem__(17,7))
fixture('wrong_identity',lambda h,p:h.__setitem__(4,h[4]^1))
sv=r'''
`timescale 1ns/1ps
`default_nettype none
module tb_compressed;
 reg clk=0; always #5 clk=~clk;
 reg reset=1,cart_ready=0,cart_replace=0,slots_settled=0;
 reg event0=0,event1=0; reg [5:0] block0=0,block1=0; reg [1:0] die_busy=0;
 reg host_busy=0,force_apply=0;
 wire busy,boot_hold,current,bank,save_error,apply_error,present;
 wire p2_req,p2_we; wire [24:0] p2_addr; wire [15:0] p2_wdata; wire [1:0] p2_be;
 reg p2_done=0,p2_pend=0; reg [15:0] p2_rdata;
 wire st_req,st_we; wire [24:0] st_addr; wire [15:0] st_wdata;
 reg st_done=0,st_pend=0; reg [15:0] st_rdata;
 reg [15:0] sdram[0:2097151],gold[0:2097151],pristine[0:2097151];
 reg [15:0] psram[0:65535],persisted[0:32511],reference[0:32511],saved_before[0:32511];
 reg [31:0] blob[0:16255];
 integer writes=0,requests=0,swrites=0,commits=0;
 reg prev_bank=0;
 reg cs_save=0,cs_load=0;
 wire cs_save_done,cs_load_done,cs_save_error,cs_load_error,img_wr;
 wire [13:0] img_addr,img_rd_addr; wire [31:0] img_data;
 reg [31:0] img_rd_data;
 wire sc_req,sc_active,sc_draining,sc_host_wr,sc_apply,sc_hold;
 wire [24:0] sc_addr,sc_host_addr; wire [15:0] sc_host_data;
 reg [4:0] host_tail=0;
 wire actual_host_busy=host_busy || sc_host_wr || host_tail!=0;
 wire mem_req=sc_active ? sc_req : st_req;
 wire [24:0] mem_addr=sc_active ? sc_addr : st_addr;
 wire mem_we=!sc_active && st_we;
 always @(posedge clk) begin
  if(reset) host_tail<=0;
  else if(sc_host_wr) host_tail<=20;
  else if(host_tail!=0) host_tail<=host_tail-1'b1;
  img_rd_data<=blob[img_rd_addr];
  if(img_wr) blob[img_addr]<=img_data;
  if(sc_host_wr) psram[{bank ^ sc_host_addr[16],sc_host_addr[15:1]}]<=sc_host_data;
  if(bank!=prev_bank) commits<=commits+1;
  prev_bank<=bank;
  p2_done<=0;
  if(p2_req) begin
   if(p2_we) begin sdram[p2_addr[21:1]]<=p2_wdata;writes<=writes+1;end
   else p2_rdata<=sdram[p2_addr[21:1]];
   requests<=requests+1;p2_pend<=1;
  end else if(p2_pend) begin p2_pend<=0;p2_done<=1;end
  st_done<=0;
  if(mem_req) begin
   if(mem_addr>=25'h20000 || mem_addr[15:0]>=16'hFE00) $fatal(1,"out of bank/image bounds %h",mem_addr);
   if(mem_we) begin psram[mem_addr[16:1]]<=st_wdata;swrites<=swrites+1;end
   else st_rdata<=psram[mem_addr[16:1]];
   st_pend<=1;
  end else if(st_pend) begin st_pend<=0;st_done<=1;end
  if(sc_active && st_req) $fatal(1,"copier stole active engine port");
 end
 ngpc_cart_save #(.QUIET_CLOCKS(20'd20)) dut (
  .clk(clk),.reset(reset),.cart_ready_i(cart_ready),.cart_replace_i(cart_replace),
  .cart_crc32_i(32'h600DCA57),.cart_bytes_i(25'h400000),.size_code0_i(2'd3),.size_code1_i(2'd3),
  .event0_i(event0),.block0_i(block0),.event1_i(event1),.block1_i(block1),.die_busy_i(die_busy),
  .host_busy_i(actual_host_busy || sc_draining),.state_apply_i(force_apply || sc_apply),.slots_settled_i(slots_settled),
  .diag_beats_i(16'd0),.diag_drops_i(16'd0),.boot_hold_o(boot_hold),.busy_o(busy),
  .save_present_o(present),.stage_current_o(current),.stage_bank_o(bank),.save_error_o(save_error),.apply_error_o(apply_error),
  .p2_req_o(p2_req),.p2_we_o(p2_we),.p2_addr_o(p2_addr),.p2_wdata_o(p2_wdata),.p2_be_o(p2_be),
  .p2_ready_i(1'b1),.p2_done_i(p2_done),.p2_rdata_i(p2_rdata),
  .stage_req_o(st_req),.stage_we_o(st_we),.stage_addr_o(st_addr),.stage_wdata_o(st_wdata),
  .stage_ready_i(1'b1),.stage_done_i(st_done),.stage_rdata_i(st_rdata));
 ngpc_state_cart copier (
  .clk(clk),.reset(reset),.cart_save_req(cs_save),.cart_save_done(cs_save_done),.cart_save_error(cs_save_error),
  .cart_img_wr(img_wr),.cart_img_addr(img_addr),.cart_img_data(img_data),
  .cart_load_req(cs_load),.cart_load_done(cs_load_done),.cart_load_error(cs_load_error),
  .cart_img_rd_addr(img_rd_addr),.cart_img_rd_data(img_rd_data),
  .sc_rd_req(sc_req),.sc_rd_addr(sc_addr),.sc_rd_ready(1'b1),.sc_rd_done(st_done),.sc_rd_data(st_rdata),
  .sc_rd_active(sc_active),.draining_o(sc_draining),.sc_host_ready(1'b1),.sc_host_wr(sc_host_wr),.sc_host_addr(sc_host_addr),.sc_host_data(sc_host_data),
  .stage_bank_i(bank),.save_error_i(save_error),.apply_error_i(apply_error),.host_busy_i(actual_host_busy),
  .stage_current_i(current),.state_apply_o(sc_apply),.apply_busy_i(busy),.hold_o(sc_hold));
 integer i,n,bad,base,prev_writes; reg bank_before;
 task wait_pass;
 begin
  n=0;
  while(!busy && n<10000) begin @(negedge clk);n=n+1;end
  if(!busy) $fatal(1,"no pass started state=%d current=%b",dut.state,current);
  n=0;
  while(busy && n<4000000) begin @(negedge clk);n=n+1;end
  if(busy || boot_hold) $fatal(1,"pass stuck state=%d",dut.state);
 end endtask
 task wait_current;
 begin
  n=0;
  while(!current && !save_error && n<6000000) begin @(negedge clk);n=n+1;end
  if(!current || save_error) $fatal(1,"not current state=%d error=%b",dut.state,save_error);
 end endtask
 task event_block(input integer die,input integer blocknum);
 begin
  @(negedge clk);die_busy=1;
  @(negedge clk);if(die==0) begin event0=1;block0=blocknum;end else begin event1=1;block1=blocknum;end
  @(negedge clk);event0=0;event1=0;
  @(negedge clk);die_busy=0;
 end endtask
 task capture_active;
 begin
  base=bank?32768:0;
  for(i=0;i<32512;i=i+1) persisted[i]=psram[base+i];
 end endtask
 task compare_gold;
 begin
  bad=0;
  for(i=0;i<2097152;i=i+1) if(sdram[i]!==gold[i]) bad=bad+1;
  if(bad) $fatal(1,"full cartridge differs: %d words",bad);
 end endtask
 task boot_image;
 begin
  @(negedge clk);reset=1;cart_ready=0;slots_settled=0;host_busy=0;
  repeat(5) @(negedge clk);
  for(i=0;i<2097152;i=i+1) sdram[i]=pristine[i];
  for(i=0;i<65536;i=i+1) psram[i]=16'hDEAD;
  for(i=0;i<32512;i=i+1) psram[i]=persisted[i];
  p2_done=0;p2_pend=0;st_done=0;st_pend=0;
  reset=0;cart_ready=1;
  repeat(10) @(negedge clk);
  if(!boot_hold || writes!=prev_writes) $fatal(1,"boot did not hold for delivered slot");
  slots_settled=1;wait_pass();
 end endtask
 task reject_fixture(input [1023:0] filename);
 begin
  $readmemh(filename,persisted);prev_writes=writes;boot_image();
  if(!apply_error || writes!=prev_writes) $fatal(1,"malformed image applied %s",filename);
  $display("PASS reject before writes: %0s",filename);
 end endtask
 task state_capture(input integer error_expected);
 begin
  @(negedge clk);cs_save=1;
  @(negedge clk);cs_save=0;n=0;
  while(!cs_save_done && n<6000000) begin @(negedge clk);n=n+1;end
  if(!cs_save_done || cs_save_error!=error_expected) $fatal(1,"state capture result wrong");
  @(negedge clk);
 end endtask
 task state_load(input integer error_expected);
 begin
  @(negedge clk);cs_load=1;
  @(negedge clk);cs_load=0;n=0;
  while(!cs_load_done && n<6000000) begin @(negedge clk);n=n+1;end
  if(!cs_load_done || cs_load_error!=error_expected) $fatal(1,"state load result wrong state=%d dut=%d err=%b",copier.st,dut.state,cs_load_error);
  @(negedge clk);
 end endtask
 initial begin
  $readmemh("dist/savefix-tests/codec/pristine.hex",pristine);
  $readmemh("dist/savefix-tests/codec/synthetic_saved.hex",gold);
  $readmemh("dist/savefix-tests/codec/reference.hex",reference);
  for(i=0;i<32512;i=i+1) persisted[i]=16'hDEAD;
  prev_writes=writes;boot_image();wait_current();
  if(present) $fatal(1,"no-file boot created nonempty save");
  for(i=0;i<2097152;i=i+1) sdram[i]=gold[i];
  event_block(0,30);event_block(0,31);event_block(0,32);event_block(0,33);
  wait_current();capture_active();
  for(i=0;i<22;i=i+1) if(persisted[i]!==reference[i]) $fatal(1,"reference header differs at %d rtl=%h ref=%h",i,persisted[i],reference[i]);
  for(i=256;i<reference[16];i=i+1) if(persisted[i]!==reference[i]) $fatal(1,"reference payload differs at %d",i);
  $display("PASS synthetic four dirty blocks: %0d image bytes, independent Python CRC/encoding match",persisted[16]*2);
  prev_writes=writes;boot_image();compare_gold();
  if(apply_error) $fatal(1,"synthetic image rejected");
  $display("PASS cold restore: all 2097152 cartridge words match");
  // Capture through the real state-cart copier, then change/erase flash and rewind.
  state_capture(0);
  @(negedge clk);for(i=21'hF0000;i<21'hF8000;i=i+1) sdram[i]=16'hFFFF;
  event_block(0,30);wait_current();
  state_load(0);compare_gold();capture_active();
  $display("PASS state copier capture, erase, rewind, battery image publication");
  // Replacing an erased block is an event even if all its words are FFFF.
  for(i=21'hFA000;i<21'hFB000;i=i+1) begin sdram[i]=16'hFFFF;gold[i]=16'hFFFF;end
  event_block(0,33);wait_current();capture_active();
  prev_writes=writes;boot_image();compare_gold();
  $display("PASS all-erased dirty block cold reload");
  // New dirty block on the second die, with FFFF literals encoded as runs.
  for(i=21'h1FA000;i<21'h1FB000;i=i+1) begin sdram[i]=16'hFFFF;gold[i]=16'hFFFF;end
  sdram[21'h1FA001]=16'h1234;gold[21'h1FA001]=16'h1234;
  event_block(1,33);wait_current();capture_active();
  prev_writes=writes;boot_image();compare_gold();
  $display("PASS second-die block and first-die preservation");
  // State from the earlier bitmap cannot safely revert a newly dirty block.
  capture_active();for(i=0;i<32512;i=i+1)saved_before[i]=persisted[i];
  prev_writes=writes;state_load(1);
  if(writes!=prev_writes) $fatal(1,"omitted state block caused partial restore");
  capture_active();for(i=0;i<32512;i=i+1)if(saved_before[i]!==persisted[i])$fatal(1,"rejected state destroyed previous save");
  $display("PASS unsafe earlier-bitmap state rejected and previous image preserved");
  // Mid-copy updates cannot publish a torn image. Inject after staging starts.
  bank_before=bank;
  sdram[21'hF0000]=16'h1111;event_block(0,30);
  while(!busy) @(negedge clk);
  repeat(100) @(negedge clk);
  sdram[21'hF0000]=16'h2222;gold[21'hF0000]=16'h2222;event_block(0,30);
  while(busy) @(negedge clk);
  if(bank!=bank_before) $fatal(1,"torn candidate published");
  wait_current();capture_active();prev_writes=writes;boot_image();compare_gold();
  $display("PASS mid-copy flash event discards candidate then restages");
  // Incompressible 64 KiB block cannot fit. Last valid image survives exactly.
  capture_active();for(i=0;i<32512;i=i+1)saved_before[i]=persisted[i];bank_before=bank;
  for(i=21'hF0000;i<21'hF8000;i=i+1)sdram[i]=16'h0000;
  event_block(0,30);wait_pass();
  if(!save_error || bank!=bank_before || current) $fatal(1,"overflow not rejected");
  capture_active();for(i=0;i<32512;i=i+1)if(saved_before[i]!==persisted[i])$fatal(1,"overflow changed active image");
  state_capture(1);
  $display("PASS incompressible overflow preserves previous image; state capture fails without hang");
  // Incoming malformed states also leave previous staging/flash untouched.
  blob[0]=0;prev_writes=writes;state_load(1);
  if(writes!=prev_writes) $fatal(1,"malformed state wrote flash");
  capture_active();for(i=0;i<32512;i=i+1)if(saved_before[i]!==persisted[i])$fatal(1,"malformed state changed active image");
  $display("PASS malformed state rejected without flash writes or active image changes");
  // Independent malformed fixtures, including valid CRC but illegal record geometry.
  reject_fixture("dist/savefix-tests/codec/zero_run.hex");
  reject_fixture("dist/savefix-tests/codec/overrun.hex");
  reject_fixture("dist/savefix-tests/codec/invalid_bitmap.hex");
  reject_fixture("dist/savefix-tests/codec/short_length.hex");
  reject_fixture("dist/savefix-tests/codec/wrong_size.hex");
  reject_fixture("dist/savefix-tests/codec/wrong_geometry.hex");
  reject_fixture("dist/savefix-tests/codec/wrong_identity.hex");
  for(i=0;i<32512;i=i+1)persisted[i]=reference[i];persisted[256]=persisted[256]^1;
  prev_writes=writes;boot_image();if(!apply_error || writes!=prev_writes)$fatal(1,"payload corruption accepted");
  for(i=0;i<32512;i=i+1)persisted[i]=reference[i];for(i=3000;i<32512;i=i+1)persisted[i]=16'hDEAD;
  prev_writes=writes;boot_image();if(!apply_error || writes!=prev_writes)$fatal(1,"truncated transfer accepted");
  $display("PASS CRC corruption and interrupted cold transfer rejected before writes");
  // Legacy V2 one 8 KiB block, then oversized raw V2 dirty map rejection.
  for(i=0;i<32512;i=i+1)persisted[i]=0;
  for(i=0;i<8;i=i+1)persisted[i]=reference[i];persisted[3]=16'h5632;persisted[10]=2;
  for(i=0;i<4096;i=i+1)persisted[256+i]=i;
  prev_writes=writes;boot_image();if(apply_error)$fatal(1,"valid V2 rejected");
  for(i=0;i<2097152;i=i+1)gold[i]=pristine[i];
  for(i=0;i<4096;i=i+1)gold[21'hFD000+i]=i;
  compare_gold();wait_current();capture_active();
  if(persisted[3]!=16'h5633)$fatal(1,"legacy image did not upgrade");
  $display("PASS bounded legacy V2 restore and V3 upgrade");
  for(i=0;i<32512;i=i+1)persisted[i]=reference[i];persisted[3]=16'h5632;
  prev_writes=writes;boot_image();if(!apply_error || writes!=prev_writes)$fatal(1,"oversized V2 accepted");
  $display("PASS oversized legacy V2 rejected before any flash write");
  $display("ALL PASS");$finish;
 end
 initial begin #10000000000;$fatal(1,"watchdog");end
endmodule
`default_nettype wire
'''
# Physical CPU block33 is offset1FA000; divide by2 =>FD000 words.
sv=sv.replace("21'hFA000", "21'hFD000").replace("21'hFB000", "21'hFE000").replace("21'h1FA000", "21'h1FD000").replace("21'h1FB000", "21'h1FE000").replace("21'h1FA001", "21'h1FD001")
tb=out/'tb_compressed.sv';tb.write_text(sv)
if '--prepare-only' in sys.argv: sys.exit(0)
rtl=ROOT/'target/pocket'
cmd=['iverilog','-g2012','-s','tb_compressed','-o',str(out/'test.vvp'),str(ROOT/'upstream/rtl/cart/ngp_cart_overlay_geometry.sv'),str(rtl/'ngpc_cart_save.sv'),str(rtl/'ngpc_state_cart.sv'),str(tb)]
c=subprocess.run(cmd,capture_output=True,text=True,cwd=ROOT);(out/'compile.log').write_text(c.stdout+c.stderr);assert c.returncode==0,c.stderr
with (out/'simulation.log').open('w') as log:
 v=subprocess.run(['vvp','-i',str(out/'test.vvp')],stdout=log,stderr=subprocess.STDOUT,text=True,cwd=ROOT,timeout=300)
v.stdout=(out/'simulation.log').read_text();print(v.stdout,flush=True);assert v.returncode==0
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
report=dict(result='PASS RTL simulation; no FPGA build or hardware validation',synthetic_cartridge_sha256=hashlib.sha256(rom).hexdigest(),image_bytes=512+len(payload)*2,rtl_sha256=sha(rtl/'ngpc_cart_save.sv'),copier_sha256=sha(rtl/'ngpc_state_cart.sv'),testbench_sha256=sha(tb),output=v.stdout,limitations='Actual save-engine/state-cart RTL with geometry; modeled memory/host and synthesized dirty events. No CPU/gameplay/APF pins, full FPGA synthesis, physical Pocket, or power-loss SD-file atomicity validation. State rewind to omitted currently dirty blocks fails explicitly because the original ROM bytes are unavailable.')
(out/'result.json').write_text(json.dumps(report,indent=2)+'\n')
