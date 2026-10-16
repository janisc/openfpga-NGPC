// The NGP link cable over the Pocket's link port and an ordinary Game Boy
// Color link cable.
//
// THE PROBLEM
//
// The NGP's link connector (CON2) carries four signals: TxD0 and RxD0 of the
// TMP95C061's serial channel 0 (19200 bps 8N1 in every SNK title), RTS_n out of
// system register 0xB2 bit 0, and CTS0_n in. A GBC link cable has one crossed
// pair -- each end's SO lands on the other end's SI -- so each direction has
// ONE wire, and two signals to carry on it.
//
// THE TRANSPORT
//
// Each side sends its own TxD and RTS_n levels to the other, continuously, in
// short frames much faster than 19200 bps, and the other side rebuilds them as
// its RxD and CTS_n. This is a tunnel for the wire LEVELS, not for bytes: the
// NGP serial channels on both sides run exactly as they would on a real cable,
// at whatever rate and format the game set, and this module never looks at
// their data.
//
// A frame is six bits at CLKS_PER_BIT clk_sys cycles per bit, LSB first:
//
//   start (0) | TxD | RTS_n | tag | parity | stop (1)
//
// `tag` alternates from frame to frame and `parity` makes the three payload
// bits odd. Frames are sent back to back, so every frame starts with a fresh
// falling edge and the receiver resynchronises on each one; the two Pockets'
// clocks never need to agree beyond a bit-time. At 48 cycles per bit (1.024
// Mbit/s on the wire) a frame is 5.9 us, so a TxD edge is rebuilt 6-12 us
// late with up to 5.9 us of jitter -- about 11% of a 52 us bit at 19200 bps,
// well inside what the NGP's 16x-oversampling receiver tolerates.
//
// CABLE DETECT
//
// The partner counts as present after PRESENT_FRAMES valid frames in a row,
// and absent after BAD_FRAMES invalid ones or QUIET_CLKS without a valid one.
// While absent, RxD is mark (1), CTS_n deasserted (1) and `present` low --
// exactly an unplugged NGP cable. A Pocket running another core, a Game Boy, or
// nothing at all never produces a run of valid frames.
//
// ELECTRICAL RULES
//
// Only SO is ever driven, and only while `enable` is set; this module has no
// way to drive SI, SC or SD. SO lands on the partner's SI, an input, which is
// how every Game Boy link game uses the port. With `enable` low the pin is
// released and the receiver reports an unplugged cable.

module ngpc_link
#(
	parameter integer CLKS_PER_BIT   = 48,
	parameter integer PRESENT_FRAMES = 32,
	parameter integer BAD_FRAMES     = 8,
	parameter integer QUIET_CLKS     = 8 * 6 * 48
)
(
	input  wire clk,
	input  wire reset,
	input  wire enable,

	// The machine's side of CON2.
	input  wire txd,        // TxD0, resolved pin level
	input  wire rts_n,      // 0xB2 bit 0
	output wire rxd,        // RxD0
	output wire cts_n,      // CTS0_n
	output wire present,    // cable detect, active high

	// The link port. `si` is the raw, asynchronous pin.
	output wire so,
	output wire so_oe,
	input  wire si
);

	localparam integer FRAME_BITS = 6;
	localparam integer CW = $clog2(CLKS_PER_BIT * FRAME_BITS + 1);
	localparam integer QW = $clog2(QUIET_CLKS + 1);

	// ---- transmit -------------------------------------------------------
	reg [FRAME_BITS-1:0] tx_shift = {FRAME_BITS{1'b1}};
	reg [2:0]            tx_bit = 3'd0;
	reg [CW-1:0]         tx_cnt = {CW{1'b0}};
	reg                  tx_tag = 1'b0;

	always @(posedge clk) begin
		if (reset || !enable) begin
			tx_shift <= {FRAME_BITS{1'b1}};
			tx_bit   <= 3'd0;
			tx_cnt   <= {CW{1'b0}};
			tx_tag   <= 1'b0;
		end else if (tx_cnt != CLKS_PER_BIT - 1) begin
			tx_cnt <= tx_cnt + 1'd1;
		end else begin
			tx_cnt <= {CW{1'b0}};
			if (tx_bit == FRAME_BITS - 1) begin
				// Next frame: sample the levels now, so the frame carries them.
				tx_bit   <= 3'd0;
				tx_tag   <= ~tx_tag;
				tx_shift <= {1'b1, ~(txd ^ rts_n ^ ~tx_tag), ~tx_tag, rts_n, txd, 1'b0};
			end else begin
				tx_bit   <= tx_bit + 1'd1;
				tx_shift <= {1'b1, tx_shift[FRAME_BITS-1:1]};
			end
		end
	end

	assign so    = tx_shift[0];
	assign so_oe = enable;

	// ---- receive --------------------------------------------------------
	// Two synchroniser stages, then a five-sample majority so a glitch of up to
	// two clk_sys cycles on the cable cannot start a frame or flip a bit.
	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
	reg [1:0] si_sync = 2'b11;
	reg [4:0] si_hist = 5'b11111;
	wire [2:0] si_ones = si_hist[0] + si_hist[1] + si_hist[2] + si_hist[3] + si_hist[4];
	wire      si_f = (si_ones >= 3'd3);
	reg       si_prev = 1'b1;

	always @(posedge clk) begin
		si_sync <= {si_sync[0], si};
		si_hist <= {si_hist[3:0], si_sync[1]};
		si_prev <= si_f;
	end

	reg                  rx_busy = 1'b0;
	reg [CW-1:0]         rx_cnt = {CW{1'b0}};
	reg [2:0]            rx_bit = 3'd0;
	reg [FRAME_BITS-1:0] rx_shift = {FRAME_BITS{1'b1}};

	// One-cycle result of a finished frame.
	reg       fr_done = 1'b0;
	reg       fr_ok = 1'b0;
	reg [2:0] fr_payload = 3'd0;   // {tag, rts_n, txd}

	always @(posedge clk) begin
		fr_done <= 1'b0;
		if (reset || !enable) begin
			rx_busy <= 1'b0;
		end else if (!rx_busy) begin
			if (si_prev && !si_f) begin
				// A falling edge: the start bit. Its middle is half a bit away.
				rx_busy <= 1'b1;
				rx_cnt  <= CW'(CLKS_PER_BIT / 2 - 1);
				rx_bit  <= 3'd0;
			end
		end else if (rx_cnt != 0) begin
			rx_cnt <= rx_cnt - 1'd1;
		end else begin
			// The middle of bit rx_bit.
			rx_shift <= {si_f, rx_shift[FRAME_BITS-1:1]};
			rx_cnt   <= CW'(CLKS_PER_BIT - 1);
			if (rx_bit == 3'd0 && si_f) begin
				rx_busy <= 1'b0;                     // a glitch, not a start bit
			end else if (rx_bit == FRAME_BITS - 1) begin
				// The stop bit: the frame is complete. Hunt for the next start.
				rx_busy    <= 1'b0;
				fr_done    <= 1'b1;
				fr_payload <= rx_shift[4:2];
				fr_ok      <= si_f &&                                  // stop
				              ^{rx_shift[5:2]};                        // odd parity
			end else begin
				rx_bit <= rx_bit + 1'd1;
			end
		end
	end

	// ---- frames to levels and cable detect -------------------------------
	reg                 rem_txd = 1'b1;
	reg                 rem_rts_n = 1'b1;
	reg                 last_tag = 1'b0;
	reg                 last_ok = 1'b0;
	reg [5:0]           good = 6'd0;
	reg [3:0]           bad = 4'd0;
	reg [QW-1:0]        quiet = {QW{1'b0}};
	reg                 linked = 1'b0;

	// A frame is valid when its framing and parity hold and, if the frame
	// before it was valid too, its tag is the other one.
	wire fr_valid = fr_ok && (!last_ok || fr_payload[2] != last_tag);

	always @(posedge clk) begin
		if (reset || !enable) begin
			rem_txd   <= 1'b1;
			rem_rts_n <= 1'b1;
			last_ok   <= 1'b0;
			good      <= 6'd0;
			bad       <= 4'd0;
			quiet     <= {QW{1'b0}};
			linked    <= 1'b0;
		end else begin
			if (fr_done && fr_valid) begin
				rem_txd   <= fr_payload[0];
				rem_rts_n <= fr_payload[1];
				last_tag  <= fr_payload[2];
				last_ok   <= 1'b1;
				bad       <= 4'd0;
				quiet     <= {QW{1'b0}};
				if (good != PRESENT_FRAMES)
					good <= good + 1'd1;
				else
					linked <= 1'b1;
			end else begin
				if (fr_done) begin
					last_ok <= 1'b0;
					good    <= 6'd0;
					if (bad != BAD_FRAMES)
						bad <= bad + 1'd1;
				end
				if (quiet != QUIET_CLKS)
					quiet <= quiet + 1'd1;
				if ((fr_done && bad == BAD_FRAMES - 1) || quiet == QUIET_CLKS - 1) begin
					linked    <= 1'b0;
					good      <= 6'd0;
					rem_txd   <= 1'b1;
					rem_rts_n <= 1'b1;
				end
			end
		end
	end

	assign present = linked;
	assign rxd     = linked ? rem_txd   : 1'b1;
	assign cts_n   = linked ? rem_rts_n : 1'b1;

endmodule
