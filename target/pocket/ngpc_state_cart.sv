// The state-cart copier: moves the .sav image between the savestate blob's
// cart section and the PSRAM staging area, so a savestate alone carries the
// cartridge flash delta.
//
// It creates no new machinery on either end. The background stager keeps a
// complete, current .sav image in staging at all times; capture is therefore
// a read of what already exists, taken only when the stager reports itself
// converged and idle (stage_current_i), with the machine held paused across
// the whole operation so machine state and cart image form an atomic pair.
// Restore writes the section back through the SAME host-write path a
// delivered .sav takes -- skid, pacing and all -- then pulses the cart save
// engine's apply, which validates the staged header exactly as it does at
// boot, rewrites flash under its own machine hold, and restores the dirty
// bitmap from the header so the next flush carries the restored timeline.
//
// Word geometry: blob cart section word w (32-bit) <-> staging bytes 4w and
// 4w+2 (two 16-bit halves, little-endian like the delivery path).
//
// Handshakes (all clk_sys):
//   bridge:    cart_save_req -> ... -> cart_save_done
//              cart_load_req -> ... -> cart_load_done
//   staging:   read via the cart-save engine port (borrowed while idle),
//              write via the host skid (sc_host_*)
//   apply:     state_apply_o pulse; completion observed as apply_busy_i
//              rising then falling
//   hold_o:    keeps the machine parked from capture request to done

`default_nettype none

module ngpc_state_cart
(
	input  wire        clk,
	input  wire        reset,

	// ---- bridge side (ngpc_savestate_bridge cart section) ------------------
	input  wire        cart_save_req,
	output reg         cart_save_done,
	output reg         cart_img_wr,
	output reg  [13:0] cart_img_addr,
	output reg  [31:0] cart_img_data,

	input  wire        cart_load_req,
	output reg         cart_load_done,
	output reg  [13:0] cart_img_rd_addr,
	input  wire [31:0] cart_img_rd_data,   // valid 3 clks after the address

	// ---- staging read (borrowed cart-save engine port) ---------------------
	output reg         sc_rd_req,
	output reg  [24:0] sc_rd_addr,
	input  wire        sc_rd_ready,
	input  wire        sc_rd_done,
	input  wire [15:0] sc_rd_data,
	output wire        sc_rd_active,   // core_top muxes the port while high
	output wire        draining_o,     // drain owns staging: host-busy this

	// ---- staging write (host skid path, delivery-identical) ----------------
	output reg         sc_host_wr,
	output reg  [24:0] sc_host_addr,
	output reg  [15:0] sc_host_data,

	// ---- cart save engine --------------------------------------------------
	input  wire        stage_current_i,   // stager idle with nothing pending
	output reg         state_apply_o,     // pulse: apply the staged image
	input  wire        apply_busy_i,

	// ---- machine -----------------------------------------------------------
	output wire        hold_o             // keep the machine parked (capture)
);

	localparam integer CART_WORDS = 16256;   // 0xFE00 bytes

	localparam [3:0] I_IDLE      = 4'd0;
	localparam [3:0] I_CUR_WAIT  = 4'd1;
	localparam [3:0] I_RD_LO     = 4'd2;
	localparam [3:0] I_RD_LO_W   = 4'd3;
	localparam [3:0] I_RD_HI     = 4'd4;
	localparam [3:0] I_RD_HI_W   = 4'd5;
	localparam [3:0] I_EMIT      = 4'd6;
	localparam [3:0] I_DR_ADDR   = 4'd7;
	localparam [3:0] I_DR_SAMPLE = 4'd8;
	localparam [3:0] I_DR_WR_LO  = 4'd9;
	localparam [3:0] I_DR_WR_HI  = 4'd10;
	localparam [3:0] I_APPLY_REQ = 4'd11;
	localparam [3:0] I_APPLY_RUN = 4'd12;
	localparam [3:0] I_DR_WAIT   = 4'd13;

	reg [3:0]  st;
	reg [14:0] w;          // section word index, 0..CART_WORDS-1
	reg [15:0] lo_half;
	reg [31:0] word_q;
	reg [1:0]  smp;
	reg        capturing;
	reg        apply_seen;
	reg        draining;

	assign sc_rd_active = capturing;
	assign hold_o       = capturing;
	assign draining_o   = draining;

	always @(posedge clk) begin
		cart_save_done <= 1'b0;
		cart_load_done <= 1'b0;
		cart_img_wr    <= 1'b0;
		sc_rd_req      <= 1'b0;
		sc_host_wr     <= 1'b0;
		state_apply_o  <= 1'b0;

		if (reset) begin
			st        <= I_IDLE;
			capturing <= 1'b0;
			draining  <= 1'b0;
		end else begin
			case (st)
				I_IDLE: begin
					if (cart_save_req) begin
						capturing <= 1'b1;
						w         <= 15'd0;
						st        <= I_CUR_WAIT;
					end else if (cart_load_req) begin
						draining <= 1'b1;
						w        <= 15'd0;
						st       <= I_DR_WAIT;
					end
				end

				// The machine is parked (hold_o), so no new flash events can
				// arrive; the stager finishes whatever it owed and goes idle.
				I_CUR_WAIT: begin
					if (stage_current_i) begin
						st <= I_RD_LO;
					end
				end

				// The drain overwrites staging, so the stager must not be
				// mid-walk; once draining_o raises host-busy it cannot start
				// another one either.
				I_DR_WAIT: begin
					if (stage_current_i) begin
						st <= I_DR_ADDR;
					end
				end

				// ---- capture: staging -> blob, two halves per word ----------
				I_RD_LO: begin
					if (sc_rd_ready) begin
						sc_rd_req  <= 1'b1;
						sc_rd_addr <= {8'd0, w, 2'b00};
						st         <= I_RD_LO_W;
					end
				end

				I_RD_LO_W: begin
					if (sc_rd_done) begin
						lo_half <= sc_rd_data;
						st      <= I_RD_HI;
					end
				end

				I_RD_HI: begin
					if (sc_rd_ready) begin
						sc_rd_req  <= 1'b1;
						sc_rd_addr <= {8'd0, w, 2'b00} + 25'd2;
						st         <= I_RD_HI_W;
					end
				end

				I_RD_HI_W: begin
					if (sc_rd_done) begin
						word_q <= {sc_rd_data, lo_half};
						st     <= I_EMIT;
					end
				end

				I_EMIT: begin
					cart_img_wr   <= 1'b1;
					cart_img_addr <= w[13:0];
					cart_img_data <= word_q;
					if (w == CART_WORDS[14:0] - 15'd1) begin
						cart_save_done <= 1'b1;
						capturing      <= 1'b0;
						st             <= I_IDLE;
					end else begin
						w  <= w + 15'd1;
						st <= I_RD_LO;
					end
				end

				// ---- restore: blob -> staging, then the boot apply ----------
				I_DR_ADDR: begin
					cart_img_rd_addr <= w[13:0];
					smp              <= 2'd0;
					st               <= I_DR_SAMPLE;
				end

				I_DR_SAMPLE: begin
					smp <= smp + 2'd1;
					if (smp == 2'd3) begin
						word_q <= cart_img_rd_data;
						st     <= I_DR_WR_LO;
					end
				end

				I_DR_WR_LO: begin
					sc_host_wr   <= 1'b1;
					sc_host_addr <= {8'd0, w, 2'b00};
					sc_host_data <= word_q[15:0];
					st           <= I_DR_WR_HI;
				end

				I_DR_WR_HI: begin
					sc_host_wr   <= 1'b1;
					sc_host_addr <= {8'd0, w, 2'b00} + 25'd2;
					sc_host_data <= word_q[31:16];
					if (w == CART_WORDS[14:0] - 15'd1) begin
						st <= I_APPLY_REQ;
					end else begin
						w  <= w + 15'd1;
						st <= I_DR_ADDR;
					end
				end

				I_APPLY_REQ: begin
					state_apply_o <= 1'b1;
					apply_seen    <= 1'b0;
					st            <= I_APPLY_RUN;
				end

				// The apply holds the machine itself (boot_hold) and validates
				// the staged header before writing a single flash word; a blob
				// with no cart data fails the magic and applies nothing, which
				// is exactly the cartless-state semantic. Busy must be seen to
				// RISE before its fall means anything -- the pulse-to-busy
				// latency is several cycles.
				I_APPLY_RUN: begin
					if (apply_busy_i) begin
						apply_seen <= 1'b1;
					end else if (apply_seen) begin
						cart_load_done <= 1'b1;
						draining       <= 1'b0;
						st             <= I_IDLE;
					end
				end

				default: st <= I_IDLE;
			endcase
		end
	end

endmodule

`default_nettype wire
