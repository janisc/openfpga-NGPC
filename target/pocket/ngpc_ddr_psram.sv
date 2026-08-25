// NGPC for Analogue Pocket -- the DDR3 channel bundle, served from PSRAM.
//
// Upstream's persistence and savestate subsystems talk to MiSTer's DDR3 through
// rtl/mem/ddram.v: two channels, each a 64-bit request/ready mailbox with byte
// enables. Roughly 4,600 lines of upstream RTL sit behind that interface and
// port to the Pocket unchanged -- provided something answers on the other side.
//
// The Pocket has no DDR3. It does have two 16 MB cellular PSRAMs that no part
// of this core touches: the cartridge lives in SDRAM and the machine's own
// memories are on-chip. Dedicating cram0 to this keeps the SDRAM ports free for
// the cartridge, whose read latency the CPU actually feels.
//
// This module presents ddram.v's exact channel interface. The arbitration
// mirrors it too -- one outstanding transaction, a pending latch per channel so
// a request is never dropped, ch1 winning a tie -- because the clients were
// written against those semantics and it is not worth discovering which of them
// depend on it.
//
// WHAT IS DIFFERENT, and it matters:
//
//   Latency. DDR3 answers a 64-bit request in tens of nanoseconds. PSRAM in
//   asynchronous mode needs ~70 ns per 16-bit word, and a 64-bit word is four
//   of them -- so roughly 300 ns per request, an order of magnitude slower.
//   Nothing here is on a path the running machine waits for: the shadow is
//   written while the cartridge streams in at APF's ~1 word/us, and it is read
//   back during a save, when the machine is already paused. If a future client
//   puts this in the CPU's way, that assumption needs revisiting.
//
//   Size. 16 MB, addressed as 2M 64-bit words across two banks. MiSTer has a
//   gigabyte and its map is laid out accordingly (savestate slots start at
//   8 MB). Addresses beyond 16 MB wrap silently here; keep the map small.

`default_nettype none

module ngpc_ddr_psram
(
	input  wire        clk,

	input  wire [27:1] ch1_addr,
	output wire [63:0] ch1_dout,
	input  wire [63:0] ch1_din,
	input  wire        ch1_req,
	input  wire        ch1_rnw,
	input  wire [7:0]  ch1_be,
	output wire        ch1_ready,

	input  wire [27:1] ch2_addr,
	output wire [63:0] ch2_dout,
	input  wire [63:0] ch2_din,
	input  wire        ch2_req,
	input  wire        ch2_rnw,
	input  wire [7:0]  ch2_be,
	output wire        ch2_ready,

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

	// ---- PSRAM back end ---------------------------------------------------

	reg  [21:0] ps_addr;
	reg         ps_bank;
	reg         ps_write_en;
	reg         ps_read_en;
	reg  [15:0] ps_data_in;
	reg         ps_wr_hi;
	reg         ps_wr_lo;

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
		.write_high_byte (ps_wr_hi),
		.write_low_byte  (ps_wr_lo),

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

	// ---- Channel arbitration ----------------------------------------------
	//
	// ddram.v latches a pending bit rather than holding the request, because a
	// client may pulse req for a single cycle while the memory is busy. The
	// bundled address and data are NOT retained by it, which is why upstream
	// puts ngp_ddr_ch2_arbiter in front of the shared channel. Same contract
	// here: the payload is captured on acceptance, and one transaction is in
	// flight at a time.

	localparam S_IDLE  = 2'd0;
	localparam S_WRITE = 2'd1;
	localparam S_READ  = 2'd2;
	localparam S_DONE  = 2'd3;

	reg [1:0]  state;
	reg        ch1_pending;
	reg        ch2_pending;
	reg        owner_ch1;      // which channel the in-flight transaction belongs to

	reg [63:0] data_q;
	reg [7:0]  be_q;
	reg [19:0] qword_q;        // 64-bit word index within a bank
	reg        bank_q;
	reg [1:0]  beat;           // which 16-bit word of the four

	reg        ch1_ready_q;
	reg        ch2_ready_q;

	assign ch1_ready = ch1_ready_q;
	assign ch2_ready = ch2_ready_q;
	assign ch1_dout  = data_q;
	assign ch2_dout  = data_q;

	// A 64-bit word is four PSRAM words. ch_addr is a 16-bit word address, so
	// the 64-bit word index is addr[27:3]; the low two bits of that index the
	// beat and are supplied by the counter rather than the client.
	wire [24:0] ch1_qword = ch1_addr[27:3];
	wire [24:0] ch2_qword = ch2_addr[27:3];

	always @(posedge clk) begin
		ch1_ready_q <= 1'b0;
		ch2_ready_q <= 1'b0;
		ps_write_en <= 1'b0;
		ps_read_en  <= 1'b0;

		ch1_pending <= ch1_pending || ch1_req;
		ch2_pending <= ch2_pending || ch2_req;

		case (state)
			S_IDLE: begin
				if (ch1_pending || ch1_req) begin
					ch1_pending <= 1'b0;
					owner_ch1   <= 1'b1;
					data_q      <= ch1_din;
					be_q        <= ch1_be;
					qword_q     <= ch1_qword[19:0];
					bank_q      <= ch1_qword[20];
					beat        <= 2'd0;
					state       <= ch1_rnw ? S_READ : S_WRITE;
				end else if (ch2_pending || ch2_req) begin
					ch2_pending <= 1'b0;
					owner_ch1   <= 1'b0;
					data_q      <= ch2_din;
					be_q        <= ch2_be;
					qword_q     <= ch2_qword[19:0];
					bank_q      <= ch2_qword[20];
					beat        <= 2'd0;
					state       <= ch2_rnw ? S_READ : S_WRITE;
				end
			end

			S_WRITE: begin
				if (!ps_busy && !ps_write_en) begin
					ps_bank    <= bank_q;
					ps_addr    <= {qword_q, beat};
					ps_data_in <= data_q[{beat, 4'd0} +: 16];
					// The byte enables arrive as one bit per byte of the 64-bit
					// word; each beat consumes its own pair.
					ps_wr_lo   <= be_q[{beat, 1'b0}];
					ps_wr_hi   <= be_q[{beat, 1'b1}];
					ps_write_en <= 1'b1;

					if (beat == 2'd3) state <= S_DONE;
					else              beat  <= beat + 2'd1;
				end
			end

			S_READ: begin
				if (ps_read_avail) begin
					data_q[{beat, 4'd0} +: 16] <= ps_data_out;

					if (beat == 2'd3) begin
						state <= S_DONE;
					end else begin
						beat  <= beat + 2'd1;
					end
				end else if (!ps_busy && !ps_read_en) begin
					ps_bank   <= bank_q;
					ps_addr   <= {qword_q, beat};
					ps_read_en <= 1'b1;
				end
			end

			S_DONE: begin
				// Let the last write drain before releasing the client, so a
				// following read of the same address cannot overtake it.
				if (!ps_busy) begin
					state       <= S_IDLE;
					ch1_ready_q <=  owner_ch1;
					ch2_ready_q <= ~owner_ch1;
				end
			end

			default: state <= S_IDLE;
		endcase
	end

	initial begin
		state       = S_IDLE;
		ch1_pending = 1'b0;
		ch2_pending = 1'b0;
		owner_ch1   = 1'b0;
		beat        = 2'd0;
		ps_write_en = 1'b0;
		ps_read_en  = 1'b0;
	end

endmodule

`default_nettype wire
