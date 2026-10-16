// Pocket port: tv80_reg with its storage in LUT RAM.
//
// A drop-in for upstream's rtl/snd/z80/tv80/tv80_reg.v (TV80 by Guy
// Hutchison, MIT licence; see that file): the same ports, including the NGPC
// savestate port, and the same cycle behaviour. Only the storage changes.
//
// The eight 16-bit register pairs are read on four ports (A, B, C and the
// savestate port S), so the array is kept four times in MLABs, one copy per
// reader, all written together. In flops the four 8:1 x 16-bit read muxes and
// the write decode cost about 170 ALMs.
//
// Writes keep tv80_reg's rules: a savestate write (WES) wins and writes both
// halves at AddrS, ungated by CEN; otherwise, on CEN, WEH and WEL write the
// high and low halves at AddrA.

module tv80_reg (/*AUTOARG*/
  // Outputs
  DOBH, DOAL, DOCL, DOBL, DOCH, DOAH,
  // Inputs
  AddrC, AddrA, AddrB, DIH, DIL, clk, CEN, WEH, WEL,
  // NGPC: savestate port (read always, write only while the core is parked)
  AddrS, DISH, DISL, WES, DOSH, DOSL
  );
    input  [2:0] AddrC;
    output [7:0] DOBH;
    input  [2:0] AddrA;
    input  [2:0] AddrB;
    input  [7:0] DIH;
    output [7:0] DOAL;
    output [7:0] DOCL;
    input  [7:0] DIL;
    output [7:0] DOBL;
    output [7:0] DOCH;
    output [7:0] DOAH;
    input  clk, CEN, WEH, WEL;
    input  [2:0] AddrS;
    input  [7:0] DISH;
    input  [7:0] DISL;
    input        WES;
    output [7:0] DOSH;
    output [7:0] DOSL;

  wire [2:0]  waddr = WES ? AddrS : AddrA;
  wire [1:0]  wbe   = WES ? 2'b11 : {CEN & WEH, CEN & WEL};
  wire [15:0] wdata = WES ? {DISH, DISL} : {DIH, DIL};
  wire        we    = |wbe;

  wire [15:0] qa, qb, qc, qs;

  pocket_lutram #(.WIDTH(16), .ADDR_W(3)) u_copy_a (.clk(clk), .we(we), .waddr(waddr), .wbe(wbe), .wdata(wdata), .raddr(AddrA), .q(qa));
  pocket_lutram #(.WIDTH(16), .ADDR_W(3)) u_copy_b (.clk(clk), .we(we), .waddr(waddr), .wbe(wbe), .wdata(wdata), .raddr(AddrB), .q(qb));
  pocket_lutram #(.WIDTH(16), .ADDR_W(3)) u_copy_c (.clk(clk), .we(we), .waddr(waddr), .wbe(wbe), .wdata(wdata), .raddr(AddrC), .q(qc));
  pocket_lutram #(.WIDTH(16), .ADDR_W(3)) u_copy_s (.clk(clk), .we(we), .waddr(waddr), .wbe(wbe), .wdata(wdata), .raddr(AddrS), .q(qs));

  assign {DOAH, DOAL} = qa;
  assign {DOBH, DOBL} = qb;
  assign {DOCH, DOCL} = qc;
  assign {DOSH, DOSL} = qs;

endmodule
