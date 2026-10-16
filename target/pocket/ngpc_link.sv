// The NGP link cable over the Pocket's link port and an ordinary Game Boy
// link cable: a GBC cable, or a GBA cable between two Pockets.
//
// THE PROBLEM
//
// The NGP's link connector (CON2) carries four signals: TxD0 and RxD0 of the
// TMP95C061's serial channel 0 (19200 bps 8N1 in every SNK title), RTS_n out of
// system register 0xB2 bit 0, and CTS0_n in. A Game Boy link cable gives each
// direction ONE wire, and there are two signals to carry on it.
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
// A frame is twelve bits at CLKS_PER_BIT clk_sys cycles per bit, LSB first:
//
//   start (0) | TxD ~TxD | RTS_n ~RTS_n | tag ~tag | parent ~parent | 1 1 1
//
// Each payload bit goes out as a Manchester pair (10 or 01), so inside a frame
// the line is never high for more than two bits, while the three stop bits put
// at least three highs before every start. The receiver starts a frame only on
// a falling edge that follows 2.5 bits of high, so it can only ever lock on to
// a real frame boundary -- an NRZ frame can be read in step with itself from
// the wrong offset, this one cannot -- and a pair that is not 10 or 01 marks
// the frame bad. `tag` alternates from frame to frame; `parent` is explained
// below. Frames are sent back to back and the receiver resynchronises on every
// one, so the two Pockets' clocks never need to agree beyond a bit-time.
//
// At 32 cycles per bit (1.536 Mbit/s on the wire) a frame is 7.8 us, so a TxD
// edge is rebuilt 8-16 us late with up to 7.8 us of jitter -- 15% of a 52 us
// bit at 19200 bps, well inside what the NGP's 16x-oversampling receiver
// tolerates.
//
// THE CABLES (`mode`: 0 off, 1 GBC cable, 2 GBA cable)
//
// A GBC cable crosses SO and SI: each side's SO lands on the other's SI. Both
// sides send on SO and receive on SI.
//
// A GBA cable chains SO to SI from the parent plug (the small one) to the
// child plug, ties the parent's SI low, and joins SD (and SC) of both plugs.
// So in GBA mode the side whose SI has been held low is the PARENT: it says so
// in its frames, sends on SO and receives on SD. The side that receives frames
// saying "parent" is the CHILD: it sends on SO (into the cable's middle socket,
// where nothing listens) and on SD, and receives on SI. Only a child ever
// drives SD, and a side cannot be both -- a parent receives nothing on SI and a
// child does -- so of two Pockets at most one drives SD. On a GBC cable nobody
// claims to be the parent, so GBA mode behaves exactly like GBC mode and SD is
// never driven.
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
// This module can drive two pins, SO and (GBA mode, child only) SD, and never
// SI or SC. Every standard cable lands a driven pin on an input or on nothing.
// For anything else -- a home-made cable joining SO to SO, say -- each driven
// pin goes through ngpc_link_guard: it listens first and drives only if no one
// else's frames are on that wire, and while no partner is linked it keeps
// pausing briefly to listen again, so two Pockets that started driving the
// same wire together separate within a few milliseconds. While a link is up it
// never pauses. With `mode` 0 every pin is released and the receiver reports an
// unplugged cable.

// Two synchroniser stages, then a five-sample majority so a glitch of up to two
// clk_sys cycles cannot start a frame or flip a bit.
module ngpc_link_filter
(
	input  wire clk,
	input  wire in,          // asynchronous pin
	output wire out
);
	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
	reg [1:0] sync = 2'b11;
	reg [4:0] hist = 5'b11111;
	wire [2:0] ones = hist[0] + hist[1] + hist[2] + hist[3] + hist[4];

	always @(posedge clk) begin
		sync <= {sync[0], in};
		hist <= {hist[3:0], sync[1]};
	end

	assign out = (ones >= 3'd3);
endmodule

// The frame receiver: one finished frame per `done` pulse, with `ok` when its
// start, Manchester pairs and first two stop bits hold. `payload` is
// {parent, tag, rts_n, txd}.
module ngpc_link_rx
#(
	parameter integer CLKS_PER_BIT = 32
)
(
	input  wire       clk,
	input  wire       reset,
	input  wire       in,      // filtered
	output reg        done = 1'b0,
	output reg        ok = 1'b0,
	output reg  [3:0] payload = 4'd0
);
	localparam integer CW   = $clog2(CLKS_PER_BIT + 1);
	localparam integer SYNC = (CLKS_PER_BIT * 5) / 2;       // 2.5 bits of high
	localparam integer HW   = $clog2(SYNC + 1);

	reg          prev = 1'b1;
	reg [HW-1:0] high = {HW{1'b0}};     // clocks the line has been high, saturating
	reg          busy = 1'b0;
	reg [CW-1:0] cnt = {CW{1'b0}};
	reg [3:0]    bit_i = 4'd0;
	reg [7:0]    sh = 8'hFF;            // the four Manchester pairs
	reg          stop1 = 1'b1;

	always @(posedge clk) begin
		prev <= in;
		if (!in)               high <= {HW{1'b0}};
		else if (high != SYNC) high <= high + 1'd1;

		done <= 1'b0;
		if (reset) begin
			busy <= 1'b0;
		end else if (!busy) begin
			if (prev && !in && high == SYNC) begin
				// A falling edge after the stop run: a start bit. Its middle is
				// half a bit away.
				busy  <= 1'b1;
				cnt   <= CW'(CLKS_PER_BIT / 2 - 1);
				bit_i <= 4'd0;
			end
		end else if (cnt != 0) begin
			cnt <= cnt - 1'd1;
		end else begin
			// The middle of bit bit_i.
			cnt <= CW'(CLKS_PER_BIT - 1);
			if (bit_i == 4'd0) begin
				if (in) busy <= 1'b0;                 // a glitch, not a start bit
			end else if (bit_i <= 4'd8) begin
				sh <= {in, sh[7:1]};
			end else if (bit_i == 4'd9) begin
				stop1 <= in;
			end else begin
				// The second stop bit: the frame is complete. Hunt for the next
				// start, which the third stop bit leads into.
				busy    <= 1'b0;
				done    <= 1'b1;
				payload <= {sh[6], sh[4], sh[2], sh[0]};
				ok      <= stop1 && in &&
				           (sh[0] != sh[1]) && (sh[2] != sh[3]) &&
				           (sh[4] != sh[5]) && (sh[6] != sh[7]);
			end
			if (bit_i != 4'd10) bit_i <= bit_i + 1'd1;
		end
	end
endmodule

// Drive a pin only when no one else is driving it. `want` asks for the pin;
// `oe` grants it. Before granting, and -- while `recheck` is set -- every
// RECHECK_CLKS or so while driving, the pin is released and watched: two or
// more valid link frames on it mean another transmitter owns the wire, and the
// pin stays released until a BACKOFF_CLKS window passes without any. That
// window is longer than the gap between the other side's own checks, so its
// brief pauses never look like a free wire. The waits carry a pseudo-random
// part so two Pockets started together fall out of step.
module ngpc_link_guard
#(
	parameter integer CLKS_PER_BIT = 32,
	parameter integer LISTEN_CLKS  = 9830,     // 200 us before first driving
	parameter integer CHECK_CLKS   = 1600,     // 33 us: four frames
	parameter integer RECHECK_CLKS = 49152,    // 1 ms between checks
	parameter integer BACKOFF_CLKS = 122880,   // 2.5 ms: listen this long after backing off
	parameter [15:0]  SEED         = 16'hACE1
)
(
	input  wire clk,
	input  wire reset,
	input  wire want,
	input  wire recheck,
	input  wire pin,          // the pin as an input, filtered
	output wire oe
);
	localparam [1:0] S_IDLE = 2'd0, S_LISTEN = 2'd1, S_DRIVE = 2'd2;

	reg  [1:0]  st = S_IDLE;
	reg  [17:0] t = 18'd0;
	reg  [1:0]  seen = 2'd0;
	reg  [15:0] lfsr = SEED;

	wire        done, ok;
	wire [3:0]  payload_unused;

	ngpc_link_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_watch
	(
		.clk(clk), .reset(reset || st != S_LISTEN), .in(pin),
		.done(done), .ok(ok), .payload(payload_unused)
	);

	always @(posedge clk) begin
		lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
		if (reset || !want) begin
			st   <= S_IDLE;
			t    <= 18'd0;
			seen <= 2'd0;
		end else begin
			case (st)
				S_IDLE: begin
					st   <= S_LISTEN;
					t    <= 18'(LISTEN_CLKS) + {8'd0, lfsr[9:0]};
					seen <= 2'd0;
				end
				S_LISTEN: begin
					if (done && ok && seen != 2'd3) seen <= seen + 2'd1;
					if (t != 0) begin
						t <= t - 1'd1;
					end else if (seen >= 2'd2) begin
						// Someone else is on this wire: keep listening, for longer
						// than the other side ever pauses.
						t    <= 18'(BACKOFF_CLKS) + {4'd0, lfsr[13:0]};
						seen <= 2'd0;
					end else begin
						st <= S_DRIVE;
						t  <= 18'(RECHECK_CLKS) + {4'd0, lfsr[13:0]};
					end
				end
				S_DRIVE: begin
					if (!recheck) begin
						t <= 18'(RECHECK_CLKS) + {4'd0, lfsr[13:0]};
					end else if (t != 0) begin
						t <= t - 1'd1;
					end else begin
						st   <= S_LISTEN;
						t    <= 18'(CHECK_CLKS);
						seen <= 2'd0;
					end
				end
				default: st <= S_IDLE;
			endcase
		end
	end

	assign oe = (st == S_DRIVE);
endmodule

module ngpc_link
#(
	parameter integer CLKS_PER_BIT   = 32,
	parameter integer PRESENT_FRAMES = 32,
	parameter integer BAD_FRAMES     = 8,
	parameter integer QUIET_CLKS     = 8 * 12 * 32,
	parameter integer GROUND_CLKS    = 3072,     // 62 us of SI low: the parent plug
	parameter [15:0]  SEED           = 16'hACE1  // pseudo-random waits (see the guard)
)
(
	input  wire       clk,
	input  wire       reset,
	input  wire [1:0] mode,        // 0 off, 1 GBC cable, 2 GBA cable

	// The machine's side of CON2.
	input  wire       txd,         // TxD0, resolved pin level
	input  wire       rts_n,       // 0xB2 bit 0
	output wire       rxd,         // RxD0
	output wire       cts_n,       // CTS0_n
	output wire       present,     // cable detect, active high

	// The link port. The inputs are the raw, asynchronous pins; `so_pin` is
	// the SO pin read back, which is what the guard watches while released.
	output wire       so,
	output wire       so_oe,
	input  wire       so_pin,
	input  wire       si,
	output wire       sd,
	output wire       sd_oe,
	input  wire       sd_pin
);

	localparam integer FB = 12;
	localparam integer CW = $clog2(CLKS_PER_BIT + 1);
	localparam integer QW = $clog2(QUIET_CLKS + 1);
	localparam integer GW = $clog2(GROUND_CLKS + 1);

	wire on  = (mode == 2'd1) || (mode == 2'd2);
	wire gba = (mode == 2'd2);

	// ---- the pins, filtered ------------------------------------------------
	wire si_f, sd_f, so_f;
	ngpc_link_filter u_fsi (.clk(clk), .in(si),     .out(si_f));
	ngpc_link_filter u_fsd (.clk(clk), .in(sd_pin), .out(sd_f));
	ngpc_link_filter u_fso (.clk(clk), .in(so_pin), .out(so_f));

	// ---- the parent plug: SI held low ---------------------------------------
	// No frame holds the line low longer than two bits, so 62 us is a cable,
	// not traffic. Once set, it clears only after SI has been high for two bits:
	// a real frame on SI does that within one frame (its stop run is three bits),
	// while a spike on the grounded wire never does, so a spike cannot make the
	// parent forget its plug and stall the link while it re-learns it.
	localparam integer CLEAR_CLKS = 2 * CLKS_PER_BIT;
	localparam integer HW = $clog2(CLEAR_CLKS + 1);
	reg [GW-1:0] low_cnt = {GW{1'b0}};
	reg [HW-1:0] high_cnt = {HW{1'b0}};
	reg          si_grounded = 1'b0;
	always @(posedge clk) begin
		if (reset || !gba) begin
			low_cnt     <= {GW{1'b0}};
			high_cnt    <= {HW{1'b0}};
			si_grounded <= 1'b0;
		end else if (si_f) begin
			low_cnt <= {GW{1'b0}};
			if (high_cnt != CLEAR_CLKS) high_cnt <= high_cnt + 1'd1;
			else                        si_grounded <= 1'b0;
		end else begin
			high_cnt <= {HW{1'b0}};
			if (low_cnt != GROUND_CLKS) low_cnt <= low_cnt + 1'd1;
			else                        si_grounded <= 1'b1;
		end
	end

	// ---- transmit ------------------------------------------------------------
	reg [FB-1:0] tx_shift = {FB{1'b1}};
	reg [3:0]    tx_bit = 4'd0;
	reg [CW-1:0] tx_cnt = {CW{1'b0}};
	reg          tx_tag = 1'b0;

	always @(posedge clk) begin
		if (reset || !on) begin
			tx_shift <= {FB{1'b1}};
			tx_bit   <= 4'd0;
			tx_cnt   <= {CW{1'b0}};
			tx_tag   <= 1'b0;
		end else if (tx_cnt != CLKS_PER_BIT - 1) begin
			tx_cnt <= tx_cnt + 1'd1;
		end else begin
			tx_cnt <= {CW{1'b0}};
			if (tx_bit == FB - 1) begin
				// Next frame: sample the levels now, so the frame carries them.
				tx_bit   <= 4'd0;
				tx_tag   <= ~tx_tag;
				tx_shift <= {3'b111, ~si_grounded, si_grounded, tx_tag, ~tx_tag,
				             ~rts_n, rts_n, ~txd, txd, 1'b0};
			end else begin
				tx_bit   <= tx_bit + 1'd1;
				tx_shift <= {1'b1, tx_shift[FB-1:1]};
			end
		end
	end

	// ---- receive: on SI, or on SD for the parent plug ----------------------
	wire       fr_done, fr_ok;
	wire [3:0] fr_payload;          // {parent, tag, rts_n, txd}

	ngpc_link_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx
	(
		.clk(clk), .reset(reset || !on), .in(si_grounded ? sd_f : si_f),
		.done(fr_done), .ok(fr_ok), .payload(fr_payload)
	);

	reg          rem_txd = 1'b1;
	reg          rem_rts_n = 1'b1;
	reg          rem_parent = 1'b0;
	reg          last_tag = 1'b0;
	reg          last_ok = 1'b0;
	reg [5:0]    good = 6'd0;
	reg [3:0]    bad = 4'd0;
	reg [QW-1:0] quiet = {QW{1'b0}};
	reg          linked = 1'b0;

	// A frame is valid when its framing and pairs hold and, if the frame
	// before it was valid too, its tag is the other one.
	wire fr_valid = fr_ok && (!last_ok || fr_payload[2] != last_tag);

	always @(posedge clk) begin
		if (reset || !on) begin
			rem_txd    <= 1'b1;
			rem_rts_n  <= 1'b1;
			rem_parent <= 1'b0;
			last_ok    <= 1'b0;
			good       <= 6'd0;
			bad        <= 4'd0;
			quiet      <= {QW{1'b0}};
			linked     <= 1'b0;
		end else begin
			if (fr_done && fr_valid) begin
				rem_txd    <= fr_payload[0];
				rem_rts_n  <= fr_payload[1];
				rem_parent <= fr_payload[3];
				last_tag   <= fr_payload[2];
				last_ok    <= 1'b1;
				bad        <= 4'd0;
				quiet      <= {QW{1'b0}};
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
					linked     <= 1'b0;
					good       <= 6'd0;
					rem_txd    <= 1'b1;
					rem_rts_n  <= 1'b1;
					rem_parent <= 1'b0;
				end
			end
		end
	end

	// ---- the drivers -----------------------------------------------------------
	// SO: whenever the link is on; re-checked while no partner is linked.
	// SD: only a GBA-mode child, i.e. linked to a partner that is the parent.
	wire child = gba && linked && rem_parent && !si_grounded;

	ngpc_link_guard #(.CLKS_PER_BIT(CLKS_PER_BIT), .SEED(SEED)) u_gso
	(
		.clk(clk), .reset(reset), .want(on), .recheck(!linked),
		.pin(so_f), .oe(so_oe)
	);

	ngpc_link_guard #(.CLKS_PER_BIT(CLKS_PER_BIT), .SEED(SEED ^ 16'h5A5A)) u_gsd
	(
		.clk(clk), .reset(reset), .want(child), .recheck(1'b0),
		.pin(sd_f), .oe(sd_oe)
	);

	assign so = tx_shift[0];
	assign sd = tx_shift[0];

	assign present = linked;
	assign rxd     = linked ? rem_txd   : 1'b1;
	assign cts_n   = linked ? rem_rts_n : 1'b1;

endmodule
