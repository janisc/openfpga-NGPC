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

	// ---- Client A: APF, through data_loader / data_unloader ---------------
	input  wire        host_wr_i,
	input  wire [24:0] host_wr_addr_i,   // byte address within the region
	input  wire [15:0] host_wr_data_i,

	input  wire        host_rd_i,
	input  wire [24:0] host_rd_addr_i,
	output reg  [15:0] host_rd_data_o,

	output wire        host_busy_o,      // a slot transfer is in progress

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
	wire [21:0] host_wr_word = host_wr_addr_i[22:1];
	wire [21:0] host_rd_word = host_rd_addr_i[22:1];
	wire [21:0] eng_word     = eng_addr_i[22:1];

	assign eng_ready_o = !ps_busy && !ps_write_en && !ps_read_en && !host_pending;

	reg        host_pending;
	reg        host_pending_rd;
	reg [21:0] host_pending_addr;
	reg [15:0] host_pending_data;

	reg        eng_active;
	reg        eng_active_rd;

	always @(posedge clk) begin
		ps_write_en <= 1'b0;
		ps_read_en  <= 1'b0;
		eng_done_o  <= 1'b0;

		if (reset) begin
			host_pending <= 1'b0;
			eng_active   <= 1'b0;
		end else begin
			// Latch a host access; it is served ahead of the engine.
			if (host_wr_i) begin
				host_pending      <= 1'b1;
				host_pending_rd   <= 1'b0;
				host_pending_addr <= host_wr_word;
				host_pending_data <= host_wr_data_i;
			end else if (host_rd_i) begin
				host_pending      <= 1'b1;
				host_pending_rd   <= 1'b1;
				host_pending_addr <= host_rd_word;
			end

			if (!ps_busy && !ps_write_en && !ps_read_en) begin
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
			if (ps_read_avail) begin
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
