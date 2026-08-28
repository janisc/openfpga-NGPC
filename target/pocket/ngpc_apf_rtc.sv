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
// Clock domains: the three bridge registers are written in clk_74a, all on
// the same edge as rtc_valid, and never change afterwards. rtc_valid is
// synchronized into clk_sys and the words are sampled 31 cycles later --
// a quasi-static crossing of data that has been stable for milliseconds.
//
// The FSM runs once. If the firmware ever re-sent the time (it does not),
// the packet would simply stay at the first delivery; ngp_host_clock keeps
// it ticking either way. rtc_ready gates ngp_setup_seed's use_hps_rtc, so
// a Pocket with no clock delivery behaves exactly as before this block.

module ngpc_apf_rtc
(
	input  wire        clk_74a,
	input  wire        clk_sys,

	// clk_74a domain, from core_bridge_cmd
	input  wire        rtc_valid,
	input  wire [31:0] rtc_date_bcd,     // 0xYYYYMMDD
	input  wire [31:0] rtc_time_bcd,     // 0x00HHMMSS

	// clk_sys domain
	output reg  [64:0] hps_rtc,
	output reg         rtc_ready
);

	initial begin
		hps_rtc   = 65'd0;
		rtc_ready = 1'b0;
	end

	// BCD pair -> binary, enough for two digits (result 0..99)
	function automatic [6:0] bcd2bin(input [7:0] v);
	begin
		bcd2bin = {3'd0, v[7:4]} * 7'd10 + {3'd0, v[3:0]};
	end
	endfunction

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

	localparam [2:0] S_IDLE   = 3'd0;
	localparam [2:0] S_SAMPLE = 3'd1;
	localparam [2:0] S_ADJUST = 3'd2;
	localparam [2:0] S_SUM    = 3'd3;
	localparam [2:0] S_MOD    = 3'd4;
	localparam [2:0] S_PACK   = 3'd5;
	localparam [2:0] S_DONE   = 3'd6;

	reg [2:0]  state  = S_IDLE;
	reg [4:0]  settle = 5'd0;

	reg [31:0] date_q;
	reg [31:0] time_q;

	reg [6:0]  zj;      // century (e.g. 20)
	reg [6:0]  zk;      // year within century
	reg [4:0]  zm;      // month, 3..14 after the Jan/Feb shift
	reg [4:0]  zq;      // day of month
	reg [8:0]  zsum;

	// Binary views of the latched BCD date digits
	wire [6:0] bin_day = bcd2bin(date_q[7:0]);
	wire [6:0] bin_mon = bcd2bin(date_q[15:8]);
	wire [6:0] bin_yr  = bcd2bin(date_q[23:16]);
	wire [6:0] bin_cen = bcd2bin(date_q[31:24]);

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
				date_q <= rtc_date_bcd;
				time_q <= rtc_time_bcd;
				state  <= S_ADJUST;
			end

			S_ADJUST: begin
				// Digits out of 0xYYYYMMDD; January and February count as
				// months 13 and 14 of the previous year, with the borrow
				// carried into the century when the year is xx00.
				zq <= bin_day[4:0];
				if (bin_mon < 7'd3) begin
					zm <= bin_mon[4:0] + 5'd12;
					if (bin_yr == 7'd0) begin
						zk <= 7'd99;
						zj <= bin_cen - 7'd1;
					end else begin
						zk <= bin_yr - 7'd1;
						zj <= bin_cen;
					end
				end else begin
					zm <= bin_mon[4:0];
					zk <= bin_yr;
					zj <= bin_cen;
				end
				state <= S_SUM;
			end

			S_SUM: begin
				// h = (q + T[m] + K + K/4 + J/4 + 5J) mod 7, 0 = Saturday
				zsum  <= {4'd0, zq}
				       + {3'd0, zeller_t(zm)}
				       + {2'd0, zk}
				       + {4'd0, zk[6:2]}
				       + {4'd0, zj[6:2]}
				       + ({2'd0, zj} << 2) + {2'd0, zj};
				state <= S_MOD;
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
				hps_rtc <= {1'b1,                                   // toggle
				            8'h40, 5'd0,                            // flags
				            (zsum[2:0] == 3'd0) ? 3'd6 : (zsum[2:0] - 3'd1),
				            date_q[23:16],                          // year
				            date_q[15:8],                           // month
				            date_q[7:0],                            // day
				            time_q[23:0]};                          // h:m:s
				rtc_ready <= 1'b1;
				state     <= S_DONE;
			end

			S_DONE: begin
				// One shot; ngp_host_clock keeps the time from here.
			end

			default: begin
				state <= S_IDLE;
			end
		endcase
	end

endmodule
