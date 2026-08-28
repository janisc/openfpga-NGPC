// APF wall clock -> MSM6242B packet adapter.
//
// The Pocket firmware writes the user's local time into core_bridge_cmd once,
// shortly after core load: rtc_date_bcd = 0xYYYYMMDD, rtc_time_bcd =
// 0x00HHMMSS, both BCD, and rtc_valid latches 1. This block turns that into
// the 65-bit packet ngp_host_clock captures:
//
//   [7:0] sec  [15:8] min  [23:16] hour  [31:24] day  [39:32] month
//   [47:40] year (2-digit BCD)  [50:48] weekday (binary, 0 = Sunday)
//   [63:56] 8'h40 flag byte      [64] capture toggle
//
// Everything is a field shuffle except the weekday, which APF does not
// provide. It is computed here with Zeller's congruence from the LOCAL BCD
// date -- deriving it from rtc_epoch_seconds instead would be off by one day
// whenever UTC and local time sit on different calendar days. The weekday
// convention (0 = Sunday) is MiSTer's hps_io convention, which is what
// ngp_setup_seed was written against.
//
// Area discipline: this boots once on a machine at 99% device occupancy, so
// it is built serial-first. One shared BCD-pair-to-binary converter walks the
// four date fields, one 9-bit accumulator gathers the Zeller terms one per
// clock, and the packet is wired combinationally from the latched words --
// rtc_ready itself is the capture toggle, flipping 0 to 1 exactly once.
//
// Clock domains: the three bridge registers are written in clk_74a, all on
// the same edge as rtc_valid, and never change afterwards. rtc_valid is
// synchronized into clk_sys and the words are sampled 31 cycles later --
// a quasi-static crossing of data that has been stable for milliseconds.
//
// rtc_ready gates ngp_setup_seed's use_hps_rtc, so a Pocket with no clock
// delivery behaves exactly as before this block existed.

module ngpc_apf_rtc
(
	input  wire        clk_74a,
	input  wire        clk_sys,

	// clk_74a domain, from core_bridge_cmd
	input  wire        rtc_valid,
	input  wire [31:0] rtc_date_bcd,     // 0xYYYYMMDD
	input  wire [31:0] rtc_time_bcd,     // 0x00HHMMSS

	// clk_sys domain
	output wire [64:0] hps_rtc,
	output reg         rtc_ready
);

	initial begin
		rtc_ready = 1'b0;
	end

	// floor(13 * (m + 1) / 5) for the Zeller month term, m = 3..14
	function automatic [5:0] zeller_t(input [4:0] m);
	begin
		case (m)
			5'd3:    zeller_t = 6'd10;
			5'd4:    zeller_t = 6'd13;
			5'd5:    zeller_t = 6'd15;
			5'd6:    zeller_t = 6'd18;
			5'd7:    zeller_t = 6'd20;
			5'd8:    zeller_t = 6'd23;
			5'd9:    zeller_t = 6'd26;
			5'd10:   zeller_t = 6'd28;
			5'd11:   zeller_t = 6'd31;
			5'd12:   zeller_t = 6'd33;
			5'd13:   zeller_t = 6'd36;
			default: zeller_t = 6'd39;  // m = 14
		endcase
	end
	endfunction

	// rtc_valid into clk_sys
	reg [2:0] valid_sync = 3'd0;
	always @(posedge clk_sys) begin
		valid_sync <= {valid_sync[1:0], rtc_valid};
	end
	wire valid_s = valid_sync[2];

	localparam [3:0] S_IDLE   = 4'd0;
	localparam [3:0] S_SAMPLE = 4'd1;
	localparam [3:0] S_BIN    = 4'd2;   // shared BCD->binary walk, 4 fields
	localparam [3:0] S_ADJUST = 4'd3;
	localparam [3:0] S_ACC    = 4'd4;   // Zeller terms, one per clock
	localparam [3:0] S_MOD    = 4'd5;
	localparam [3:0] S_PACK   = 4'd6;
	localparam [3:0] S_DONE   = 4'd7;

	reg [3:0]  state  = S_IDLE;
	reg [4:0]  settle = 5'd0;

	reg [31:0] date_q;
	reg [23:0] time_q;

	reg [1:0]  bin_sel;   // 0 day, 1 month, 2 year, 3 century
	reg [6:0]  zj;        // century
	reg [6:0]  zk;        // year within century
	reg [4:0]  zm;        // month, 3..14 after the Jan/Feb shift
	reg [4:0]  zq;        // day of month
	reg [2:0]  acc_sel;
	reg [8:0]  zsum;
	reg [2:0]  dow_q;

	// The one shared BCD-pair-to-binary converter
	wire [7:0] bcd_pair = (bin_sel == 2'd0) ? date_q[7:0]   :
	                      (bin_sel == 2'd1) ? date_q[15:8]  :
	                      (bin_sel == 2'd2) ? date_q[23:16] : date_q[31:24];
	wire [6:0] bcd_bin  = {3'd0, bcd_pair[7:4]} * 7'd10 + {3'd0, bcd_pair[3:0]};

	// The one shared accumulator operand
	wire [8:0] acc_term = (acc_sel == 3'd0) ? {4'd0, zq}         :
	                      (acc_sel == 3'd1) ? {3'd0, zeller_t(zm)} :
	                      (acc_sel == 3'd2) ? {2'd0, zk}         :
	                      (acc_sel == 3'd3) ? {4'd0, zk[6:2]}    :
	                      (acc_sel == 3'd4) ? {4'd0, zj[6:2]}    :
	                      (acc_sel == 3'd5) ? {2'd0, zj}         :
	                                          {zj, 2'd0};          // 4J
	always @(posedge clk_sys) begin
		case (state)
			S_IDLE: begin
				// Data words settle for 31 cycles after the synchronized valid.
				if (valid_s) begin
					settle <= settle + 5'd1;
					if (settle == 5'd31) begin
						state <= S_SAMPLE;
					end
				end
			end

			S_SAMPLE: begin
				date_q  <= rtc_date_bcd;
				time_q  <= rtc_time_bcd[23:0];
				bin_sel <= 2'd0;
				state   <= S_BIN;
			end

			S_BIN: begin
				case (bin_sel)
					2'd0: zq <= bcd_bin[4:0];
					2'd1: zm <= bcd_bin[4:0];
					2'd2: zk <= bcd_bin;
					2'd3: zj <= bcd_bin;
				endcase
				bin_sel <= bin_sel + 2'd1;
				if (bin_sel == 2'd3) begin
					state <= S_ADJUST;
				end
			end

			S_ADJUST: begin
				// January and February count as months 13 and 14 of the
				// previous year, the borrow carried into the century at xx00.
				if (zm < 5'd3) begin
					zm <= zm + 5'd12;
					if (zk == 7'd0) begin
						zk <= 7'd99;
						zj <= zj - 7'd1;
					end else begin
						zk <= zk - 7'd1;
					end
				end
				zsum    <= 9'd0;
				acc_sel <= 3'd0;
				state   <= S_ACC;
			end

			S_ACC: begin
				// h = (q + T[m] + K + K/4 + J/4 + J + 4J) mod 7, 0 = Saturday
				zsum    <= zsum + acc_term;
				acc_sel <= acc_sel + 3'd1;
				if (acc_sel == 3'd6) begin
					state <= S_MOD;
				end
			end

			S_MOD: begin
				if (zsum >= 9'd7) begin
					zsum <= zsum - 9'd7;
				end else begin
					state <= S_PACK;
				end
			end

			S_PACK: begin
				// Zeller 0 = Saturday -> hps 0 = Sunday is (h + 6) mod 7
				dow_q     <= (zsum[2:0] == 3'd0) ? 3'd6 : (zsum[2:0] - 3'd1);
				state     <= S_DONE;
			end

			S_DONE: begin
				// rtc_ready is the capture toggle: it flips 0 -> 1 exactly
				// once, and ngp_host_clock keeps the time from there.
				rtc_ready <= 1'b1;
			end

			default: begin
				state <= S_IDLE;
			end
		endcase
	end

	assign hps_rtc = {rtc_ready, 8'h40, 5'd0, dow_q,
	                  date_q[23:16], date_q[15:8], date_q[7:0], time_q};

endmodule
