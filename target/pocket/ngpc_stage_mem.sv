// NGPC for Analogue Pocket -- the save staging region.
//
// The nonvolatile data slot needs a block of memory that APF can read and write
// over the bridge, and that the save engine can fill from cartridge flash. It
// wants three properties:
//
//   * Big enough for whole erase blocks -- NGP flash blocks reach 64 KB, so
//     this cannot live on-chip. The device has 134 M10K spare and 128 KB alone
//     would eat 100 of them.
//   * DETERMINISTIC read latency. data_unloader samples read_data a fixed
//     number of cycles after asserting read_en. Cartridge SDRAM cannot promise
//     that -- a refresh or a burst of CPU fetches stretches an access
//     arbitrarily, and the unloader would latch whatever happened to be there.
//   * No contention with the running machine.
//
// The Pocket's cellular PSRAM satisfies all three and is otherwise unused: the
// cartridge is in SDRAM and the console's own memories are on-chip. In
// asynchronous mode it answers in a bounded ~70 ns with no refresh to hide, so
// a fixed-latency read is honest here in a way it would not be against SDRAM.
//
// Two clients share it, and they are exclusive in time rather than arbitrated
// on merit: APF owns the region while it is moving the slot in or out, and the
// save engine stands aside for it (see host_busy_o, which the engine watches).
// The priority below is a backstop for that agreement, not the mechanism.

`default_nettype none

module ngpc_stage_mem
(
	input  wire        clk,
	input  wire        reset,

	// Which 64 KB bank of the staging region is the COMMITTED image. APF
	// only ever sees this one: it delivers into it and flushes out of it,
	// so a flush can never catch a half-built image. The engine builds the
	// next image in the other bank and flips this when the image is whole.
	input  wire        active_bank_i,
	// The bank a host WRITE lands in, chosen per writer by core_top: APF's
	// delivery goes to the committed bank, the savestate drain to the spare
	// one, so a state the apply then refuses leaves the committed image --
	// the one APF flushes at exit -- exactly as it was.
	input  wire        host_wr_bank_i,

	// ---- Client A: APF, through data_loader / data_unloader ---------------
	input  wire        host_wr_i,
	input  wire [24:0] host_wr_addr_i,   // byte address within the region
	input  wire [15:0] host_wr_data_i,

	input  wire        host_rd_i,
	input  wire [24:0] host_rd_addr_i,
	output reg  [15:0] host_rd_data_o,

	// Backpressure for the state copier: the skid can absorb this write
	// and the registered one behind it. Without it the drain outruns the
	// PSRAM on contention and drops words -- silently, in release builds.
	output wire        host_wr_ready_o,
	output wire        host_busy_o,      // any host-port beat (APF slot transfer or
	                                     // the copier's drain), ~10 ms tail

	// Ingestion diagnostics, stamped into the staged save's header so every
	// flushed .sav carries them off the device: how many host write beats
	// arrived since reset, how many the skid FIFO had to drop, and the
	// deepest the FIFO ever got. Hardware showed a loaded slot arriving with
	// only its first words intact -- the burst-overrun signature -- while
	// simulation is clean at APF's documented pacing; these counters measure
	// the real bus so the two can be reconciled.
	output reg  [15:0] diag_beats_o,
	output reg  [15:0] diag_drops_o,

	// ---- PSRAM set-up --------------------------------------------------------
	// The chip keeps its configuration registers while the Pocket is on, so
	// a core that ran before this one may have left it in another mode -- or
	// with refresh switched off, which corrupts what is stored (reproduced:
	// with RCR left at "refresh none of the array", a staged save decayed
	// within minutes). Before anything else touches it,
	// both dies are woken (in case of deep power-down), their BCR and RCR
	// read as found, set to the power-on defaults (BCR 9D1Fh asynchronous,
	// RCR 0010h full-array refresh) and read back. Once per configuration;
	// a menu Reset does not repeat it. Until it is done neither client is
	// served (APF's writes wait in the skid), and core_top holds the
	// Pocket's boot status until it is.
	output wire        psram_ready_o,
	// {die 0 BCR as found [31:16], die 0 RCR[7:0] as found [15:8],
	//  die 1 BCR[15] as found [7], die 1 RCR[2:0] as found [6:4],
	//  die 1 read back as written [3], die 0 read back as written [2],
	//  set-up done [1], 1 [0]}
	output wire [31:0] psram_report_o,

	// ---- Client B: the save engine ----------------------------------------
	input  wire        eng_req_i,
	input  wire        eng_we_i,
	input  wire [24:0] eng_addr_i,
	input  wire [15:0] eng_wdata_i,
	output wire        eng_ready_o,
	output reg         eng_done_o,
	output reg  [15:0] eng_rdata_o,

	// ---- PSRAM pins --------------------------------------------------------
	output wire [21:16] cram_a,
	inout  wire [15:0]  cram_dq,
	input  wire         cram_wait,
	output wire         cram_clk,
	output wire         cram_adv_n,
	output wire         cram_cre,
	output wire         cram_ce0_n,
	output wire         cram_ce1_n,
	output wire         cram_oe_n,
	output wire         cram_we_n,
	output wire         cram_ub_n,
	output wire         cram_lb_n
);

	// Host activity is a level with a tail: APF's bridge words arrive about a
	// microsecond apart, so "no access for a while" is what marks the end of a
	// transfer, not any signal it sends. ~10 ms of quiet closes it.
	localparam [19:0] HOST_IDLE_CLOCKS = 20'd500_000;

	reg [19:0] host_idle;
	assign host_busy_o = host_idle != HOST_IDLE_CLOCKS;

	always @(posedge clk) begin
		if (reset)                            host_idle <= HOST_IDLE_CLOCKS;
		else if (host_wr_i || host_rd_i)      host_idle <= 20'd0;
		else if (host_idle != HOST_IDLE_CLOCKS) host_idle <= host_idle + 20'd1;
	end

	// ---- PSRAM back end ----------------------------------------------------

	reg  [21:0] ps_addr;
	reg         ps_bank;
	reg         ps_write_en;
	reg         ps_read_en;
	reg  [15:0] ps_data_in;
	reg         ps_cfg = 1'b0;
	reg         ps_wake = 1'b0;

	wire [15:0] ps_data_out;
	wire        ps_read_avail;
	wire        ps_busy;

	psram #(
		.CLOCK_SPEED(49.152)
	) u_psram (
		.clk             (clk),
		.bank_sel        (ps_bank),
		.addr            (ps_addr),
		.write_en        (ps_write_en),
		.data_in         (ps_data_in),
		.write_high_byte (1'b1),
		.write_low_byte  (1'b1),
		.read_en         (ps_read_en),
		.read_avail      (ps_read_avail),
		.cfg             (ps_cfg),
		.wake            (ps_wake),
		.data_out        (ps_data_out),
		.busy            (ps_busy),
		.cram_a          (cram_a),
		.cram_dq         (cram_dq),
		.cram_wait       (cram_wait),
		.cram_clk        (cram_clk),
		.cram_adv_n      (cram_adv_n),
		.cram_cre        (cram_cre),
		.cram_ce0_n      (cram_ce0_n),
		.cram_ce1_n      (cram_ce1_n),
		.cram_oe_n       (cram_oe_n),
		.cram_we_n       (cram_we_n),
		.cram_ub_n       (cram_ub_n),
		.cram_lb_n       (cram_lb_n)
	);

	// The region is addressed in bytes by both clients; PSRAM counts 16-bit
	// words, so the low bit is dropped.
	wire [21:0] host_wr_word = {5'd0, host_wr_bank_i, host_wr_addr_i[15:1]};
	// A bank is 64 KB and the slot is 0xFE00. Anything written past the
	// bank -- a foreign or oversized file -- is dropped rather than let
	// into the other bank or wrapped over this one's header.
	wire        host_wr_in_bank = (host_wr_addr_i[24:16] == 9'd0);
	wire [21:0] host_rd_word = {5'd0, active_bank_i, host_rd_addr_i[15:1]};
	wire [21:0] eng_word     = eng_addr_i[22:1];


	// ---- Host write skid FIFO ----------------------------------------------
	//
	// The PSRAM serves a beat in ~360 ns; APF's slot streaming is documented
	// at ~1 us per 32-bit word, which the single pending register handled --
	// and the nonvolatile restore measured FASTER than that on hardware,
	// overrunning it. 512 beats of skid (one M10K) rides out a 1 KB burst;
	// anything that still will not fit is counted, not silently lost.
	// no_rw_check for the same reason as the savestate blob: the two ports
	// never touch one entry at the same time (fill >= 1 guards the read), and
	// without the attribute Quartus builds 512x38 bits out of registers --
	// measured as a 9,000-ALM, 147%-of-device explosion.
	(* ramstyle = "no_rw_check, M10K" *)
	reg  [37:0] skid [0:511];
	reg  [9:0]  skid_wp, skid_rp;
	wire [9:0]  skid_fill = skid_wp - skid_rp;
	wire        skid_empty = (skid_wp == skid_rp);
	wire        skid_full  = (skid_fill == 10'd511);
	// The copier (the only client that watches ready) is held at a shallow
	// fill, so APF -- which cannot be back-pressured -- always finds room in
	// the skid. At < 508 a drain kept it at 508-511 for the whole transfer,
	// and any APF burst during it overflowed into diag_drops (rc6, L3). The
	// drain's pace is the PSRAM's either way.
	assign host_wr_ready_o = (skid_fill[9:5] == 5'd0);

	// The engine (and the copier on its port) samples ready and raises a
	// one-cycle request the cycle after. A host beat promoted from the skid,
	// or a host read, in that same cycle took the PSRAM first and the request
	// was simply never served -- the walk then waited for a done that could
	// not come (review). Ready is therefore withheld while the host has
	// anything queued or arriving; the host path keeps its priority.
	// ---- PSRAM set-up (see psram_ready_o) -----------------------------------
	//
	// Not cleared by reset: it runs once, after the first release of reset
	// (the PLL is locked by then), and a menu Reset leaves the staged save
	// and the registers alone. At 49.152 MHz: CE# LOW 600 clocks (12.2 us)
	// per die, then 8000 clocks (163 us) for a die leaving deep power-down,
	// then per die seven accesses -- read BCR, read RCR, write RCR, write
	// BCR, read BCR, read RCR, and the array read the datasheet recommends
	// after register access. About 0.2 ms in all.
`ifdef NGPC_SIM_SKIP_PSRAM_INIT
	// Simulation only: benches whose PSRAM model ignores CRE skip it.
	reg         init_done_q = 1'b1;
`else
	reg         init_done_q = 1'b0;
`endif
	localparam [1:0] IS_WAKE = 2'd0, IS_WAIT = 2'd1, IS_OP = 2'd2;
	reg  [1:0]  ist   = IS_WAKE;
	reg  [13:0] icnt  = 14'd0;
	reg         idie  = 1'b0;
	reg  [2:0]  istep = 3'd0;
	reg         iwait = 1'b0;        // an access is in flight
	reg  [15:0] f_bcr0 = 16'd0, f_bcr1 = 16'd0;
	reg  [7:0]  f_rcr0 = 8'd0,  f_rcr1 = 8'd0;
	reg  [15:0] c_bcr  = 16'd0;
	reg         ok0 = 1'b0, ok1 = 1'b0;

	localparam [15:0] BCR_DEFAULT = 16'h9D1F;
	localparam [15:0] RCR_DEFAULT = 16'h0010;

	assign psram_ready_o  = init_done_q;
	assign psram_report_o = {f_bcr0, f_rcr0, f_bcr1[15], f_rcr1[2:0], ok1, ok0, init_done_q, 1'b1};

	assign eng_ready_o = init_done_q && !ps_busy && !ps_write_en && !ps_read_en &&
	                     !host_pending && skid_empty && !host_rd_i;

	always @(posedge clk) begin
		if (reset) begin
			skid_wp <= 10'd0;
			diag_beats_o <= 16'd0;
			diag_drops_o <= 16'd0;
		end else begin
			if (host_wr_i) begin
`ifdef NGPC_SAVE_DIAG
				diag_beats_o <= diag_beats_o + 16'd1;
`endif
				if (skid_full) begin
`ifdef NGPC_SAVE_DIAG
					diag_drops_o <= diag_drops_o + 16'd1;
`endif
				end else if (host_wr_in_bank) begin
					skid[skid_wp[8:0]] <= {host_wr_word, host_wr_data_i};
					skid_wp <= skid_wp + 10'd1;
				end
			end
		end
	end

	reg        host_pending;
	reg        host_pending_rd;
	reg [21:0] host_pending_addr;
	reg [15:0] host_pending_data;

	reg        eng_active;
	reg        eng_active_rd;

	// An APF read has taken the pending slot in this data_unloader window.
	reg        host_rd_served;
	wire       host_rd_claim = host_rd_i && !host_rd_served;

	always @(posedge clk) begin
		ps_write_en <= 1'b0;
		ps_read_en  <= 1'b0;
		eng_done_o  <= 1'b0;

		if (reset) begin
			host_pending   <= 1'b0;
			eng_active     <= 1'b0;
			skid_rp        <= 10'd0;
			host_rd_served <= 1'b0;
		end else begin
			// The pending slot is loaded only while it is empty. An APF read
			// claims it ahead of the skid, once per data_unloader window
			// (read_en is held 32 clocks and sampled at the end; the read is
			// done in ~21 at worst, core_top READ_MEM_CLOCK_DELAY). The old
			// "else if (host_rd_i)" reloaded the slot on every cycle of the
			// window -- over a popped write still waiting in it, which was then
			// lost without a count (rc6, L1). This must ship with the state
			// commit's host wait (ngpc_cart_save, L2): a flush overlapping a
			// drain used to cost drain beats, so the load failed and nothing
			// changed; now the drain survives, and without L2 its commit could
			// land in the middle of that flush.
			if (!host_rd_i) host_rd_served <= 1'b0;
			if (!host_pending) begin
				if (host_rd_claim) begin
					host_pending      <= 1'b1;
					host_pending_rd   <= 1'b1;
					host_pending_addr <= host_rd_word;
					host_rd_served    <= 1'b1;
				end else if (!skid_empty) begin
					host_pending      <= 1'b1;
					host_pending_rd   <= 1'b0;
					{host_pending_addr, host_pending_data} <= skid[skid_rp[8:0]];
					skid_rp           <= skid_rp + 10'd1;
				end
			end

			if (!init_done_q) begin
				// ---- the set-up sequence ----
				case (ist)
					IS_WAKE: begin
						ps_bank <= idie;
						ps_wake <= 1'b1;
						icnt    <= icnt + 14'd1;
						if (icnt == 14'd599) begin
							ps_wake <= 1'b0;
							icnt    <= 14'd0;
							idie    <= ~idie;
							if (idie) ist <= IS_WAIT;
						end
					end
					IS_WAIT: begin
						icnt <= icnt + 14'd1;
						if (icnt == 14'd7999) begin
							icnt  <= 14'd0;
							idie  <= 1'b0;
							istep <= 3'd0;
							ist   <= IS_OP;
						end
					end
					default: begin
						if (!iwait && !ps_busy && !ps_write_en && !ps_read_en) begin
							ps_bank <= idie;
							ps_cfg  <= (istep != 3'd6);
							iwait   <= 1'b1;
							case (istep)
								// A[19:18]: 10b BCR, 00b RCR. For a write the
								// register value is the address's low half.
								3'd0, 3'd4: begin ps_addr <= 22'h080000; ps_read_en <= 1'b1; end
								3'd1, 3'd5: begin ps_addr <= 22'h000000; ps_read_en <= 1'b1; end
								3'd2: begin
									ps_addr     <= {6'd0, RCR_DEFAULT};
									ps_data_in  <= RCR_DEFAULT;
									ps_write_en <= 1'b1;
								end
								3'd3: begin
									ps_addr     <= {6'b00_10_00, BCR_DEFAULT};
									ps_data_in  <= BCR_DEFAULT;
									ps_write_en <= 1'b1;
								end
								default: begin ps_addr <= 22'd0; ps_read_en <= 1'b1; end
							endcase
						end else if (iwait && (ps_read_avail ||
						             (!ps_busy && !ps_write_en && !ps_read_en &&
						              (istep == 3'd2 || istep == 3'd3)))) begin
							iwait <= 1'b0;
							case (istep)
								3'd0: if (idie) f_bcr1 <= ps_data_out; else f_bcr0 <= ps_data_out;
								3'd1: if (idie) f_rcr1 <= ps_data_out[7:0]; else f_rcr0 <= ps_data_out[7:0];
								3'd4: c_bcr <= ps_data_out;
								3'd5: begin
									if (idie) ok1 <= (c_bcr == BCR_DEFAULT) && (ps_data_out == RCR_DEFAULT);
									else      ok0 <= (c_bcr == BCR_DEFAULT) && (ps_data_out == RCR_DEFAULT);
								end
								default: ;
							endcase
							if (istep == 3'd6) begin
								ps_cfg <= 1'b0;
								istep  <= 3'd0;
								idie   <= ~idie;
								if (idie) init_done_q <= 1'b1;
							end else begin
								istep <= istep + 3'd1;
							end
						end
					end
				endcase
			end else if (!ps_busy && !ps_write_en && !ps_read_en) begin
				if (host_pending) begin
					host_pending <= 1'b0;
					ps_bank      <= 1'b0;
					ps_addr      <= host_pending_addr;

					if (host_pending_rd) begin
						ps_read_en <= 1'b1;
						eng_active <= 1'b0;
					end else begin
						ps_data_in  <= host_pending_data;
						ps_write_en <= 1'b1;
					end
				end else if (eng_req_i) begin
					ps_bank    <= 1'b0;
					ps_addr    <= eng_word;
					eng_active <= 1'b1;

					if (eng_we_i) begin
						ps_data_in    <= eng_wdata_i;
						ps_write_en   <= 1'b1;
						eng_active_rd <= 1'b0;
					end else begin
						ps_read_en    <= 1'b1;
						eng_active_rd <= 1'b1;
					end
				end
			end

			// Completion. A write is done once the controller goes idle again;
			// a read when its data arrives.
			if (ps_read_avail && init_done_q) begin
				if (eng_active && eng_active_rd) begin
					eng_rdata_o <= ps_data_out;
					eng_done_o  <= 1'b1;
					eng_active  <= 1'b0;
				end else begin
					host_rd_data_o <= ps_data_out;
				end
			end else if (eng_active && !eng_active_rd && !ps_busy && !ps_write_en) begin
				eng_done_o <= 1'b1;
				eng_active <= 1'b0;
			end
		end
	end

endmodule

`default_nettype wire
