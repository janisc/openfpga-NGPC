// NGPC for Analogue Pocket -- 512-byte sector access to a data slot.
//
// APF's target commands ask the host to move bytes between a data slot and the
// core's own bridge address space:
//
//   target_dataslot_read   file -> core     slotoffset, bridgeaddr, length
//   target_dataslot_write  core -> file     same
//   target_dataslot_ack/done/err            completion
//
// This wraps that as a sector device: name an LBA, pulse rd or wr, wait for
// busy to fall. The 512-byte staging buffer is exposed directly to the client
// rather than walked with a strobe protocol.
//
// An earlier version of this module emulated MiSTer's sd_lba/sd_ack/sd_buff
// interface so upstream's ngp_cart_overlay could drive it unchanged. That
// overlay does not fit on this FPGA -- 4,600 lines of it put the design 17%
// over -- so the protocol it needed went with it, along with the second copy
// of this buffer that the emulation required.
//
// The buffer is filled and drained by data_loader / data_unloader, the
// idiomatic APF primitives, which already contain the clk_74a <-> clk_sys
// crossing. That leaves this module in one clock domain apart from the command
// handshake.

`default_nettype none

module ngpc_sd_bridge #(
	parameter [15:0] SAVE_SLOT_ID = 16'd10,
	parameter [31:0] BUFFER_BRIDGE_ADDR = 32'h5000_0000
) (
	input  wire        clk_sys,
	input  wire        clk_74a,
	input  wire        reset,

	// ---- APF bridge, for the buffer's own contents ------------------------
	input  wire        bridge_wr,
	input  wire        bridge_rd,
	input  wire        bridge_endian_little,
	input  wire [31:0] bridge_addr,
	input  wire [31:0] bridge_wr_data,
	output wire [31:0] bridge_rd_data,

	// ---- APF target commands ----------------------------------------------
	output wire        target_dataslot_read,
	output wire        target_dataslot_write,
	input  wire        target_dataslot_ack,
	input  wire        target_dataslot_done,
	input  wire  [2:0] target_dataslot_err,
	output wire [15:0] target_dataslot_id,
	output wire [31:0] target_dataslot_slotoffset,
	output wire [31:0] target_dataslot_bridgeaddr,
	output wire [31:0] target_dataslot_length,

	// ---- Sector device, toward ngpc_cart_save -----------------------------
	input  wire [22:0] lba_i,
	input  wire        rd_i,          // one-cycle pulse, only while !busy_o
	input  wire        wr_i,
	output reg         busy_o,
	output reg         err_o,

	// The staging buffer, 256 x 16 bits. Owned by the client between transfers.
	input  wire  [7:0] buf_addr_i,
	input  wire [15:0] buf_wdata_i,
	input  wire        buf_we_i,
	output reg  [15:0] buf_rdata_o
);

	reg [15:0] buffer [0:255];

	// ---- APF's side of the buffer -----------------------------------------

	wire        apf_wr;
	wire [27:0] apf_wr_addr;
	wire [15:0] apf_wr_data;

	data_loader #(
		.ADDRESS_MASK_UPPER_4(BUFFER_BRIDGE_ADDR[31:28]),
		.OUTPUT_WORD_SIZE(2)
	) u_fill (
		.clk_74a             (clk_74a),
		.clk_memory          (clk_sys),
		.bridge_wr           (bridge_wr),
		.bridge_endian_little(bridge_endian_little),
		.bridge_addr         (bridge_addr),
		.bridge_wr_data      (bridge_wr_data),
		.write_en            (apf_wr),
		.write_addr          (apf_wr_addr),
		.write_data          (apf_wr_data)
	);

	reg  [15:0] apf_rd_data;
	wire        apf_rd;
	wire [27:0] apf_rd_addr;

	data_unloader #(
		.ADDRESS_MASK_UPPER_4(BUFFER_BRIDGE_ADDR[31:28]),
		.INPUT_WORD_SIZE(2)
	) u_drain (
		.clk_74a             (clk_74a),
		.clk_memory          (clk_sys),
		.bridge_rd           (bridge_rd),
		.bridge_endian_little(bridge_endian_little),
		.bridge_addr         (bridge_addr),
		.bridge_rd_data      (bridge_rd_data),
		.read_en             (apf_rd),
		.read_addr           (apf_rd_addr),
		.read_data           (apf_rd_data)
	);

	// APF owns the buffer while a transfer is in flight; the client owns it
	// otherwise. The two never write on the same cycle because the client is
	// required to hold off while busy_o is high.
	always @(posedge clk_sys) begin
		if (apf_wr)      buffer[apf_wr_addr[8:1]] <= apf_wr_data;
		else if (buf_we_i) buffer[buf_addr_i]     <= buf_wdata_i;

		apf_rd_data <= buffer[apf_rd_addr[8:1]];
		buf_rdata_o <= buffer[buf_addr_i];
	end

	// ---- Command handshake -------------------------------------------------

	reg  req_read;
	reg  req_write;
	wire done_s;
	wire ack_s;

	synch_3 u_done (target_dataslot_done, done_s, clk_sys);
	synch_3 u_ack  (target_dataslot_ack,  ack_s,  clk_sys);

	// core_bridge_cmd edge-detects these in clk_74a, so the request is held as
	// a level until the host acknowledges rather than pulsed across domains.
	wire req_read_74a;
	wire req_write_74a;

	synch_3 u_rd_req (req_read,  req_read_74a,  clk_74a);
	synch_3 u_wr_req (req_write, req_write_74a, clk_74a);

	assign target_dataslot_read  = req_read_74a;
	assign target_dataslot_write = req_write_74a;

	reg [22:0] lba_q;

	assign target_dataslot_id         = SAVE_SLOT_ID;
	assign target_dataslot_slotoffset = {lba_q, 9'd0};   // lba * 512
	assign target_dataslot_bridgeaddr = BUFFER_BRIDGE_ADDR;
	assign target_dataslot_length     = 32'd512;

	localparam S_IDLE = 2'd0;
	localparam S_RUN  = 2'd1;
	localparam S_WAIT = 2'd2;

	reg [1:0] state;
	reg       saw_ack;

	always @(posedge clk_sys) begin
		if (reset) begin
			state     <= S_IDLE;
			req_read  <= 1'b0;
			req_write <= 1'b0;
			busy_o    <= 1'b0;
			err_o     <= 1'b0;
			saw_ack   <= 1'b0;
		end else begin
			case (state)
				S_IDLE: begin
					busy_o  <= 1'b0;
					saw_ack <= 1'b0;

					if (rd_i || wr_i) begin
						lba_q     <= lba_i;
						req_read  <= rd_i;
						req_write <= wr_i;
						busy_o    <= 1'b1;
						state     <= S_RUN;
					end
				end

				S_RUN: begin
					if (ack_s) saw_ack <= 1'b1;

					// done can only be believed after the host has taken the
					// request; otherwise the previous transfer's done is still
					// standing and this one appears to finish instantly.
					if (saw_ack && done_s) begin
						req_read  <= 1'b0;
						req_write <= 1'b0;
						err_o     <= |target_dataslot_err;
						state     <= S_WAIT;
					end
				end

				S_WAIT: begin
					// Let the host see the request drop before another can be
					// raised.
					if (!ack_s) state <= S_IDLE;
				end

				default: state <= S_IDLE;
			endcase
		end
	end

endmodule

`default_nettype wire
