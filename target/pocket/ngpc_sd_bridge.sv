// NGPC for Analogue Pocket -- MiSTer's SD block interface, served by APF.
//
// ngp_cart_overlay stores cartridge saves through MiSTer's block device: a
// 32-bit LBA, a read strobe, a write strobe, and a 512-byte buffer walked one
// 16-bit word at a time while `sd_ack` is high. That module and the ~4,600
// lines behind it are the save format, and they port unchanged if something
// answers on this interface.
//
// APF can answer. Its target commands ask the host to move bytes between a data
// slot and the core's own bridge address space:
//
//   target_dataslot_read   file -> core     slotoffset, bridgeaddr, length
//   target_dataslot_write  core -> file     same
//   target_dataslot_ack/done/err            completion
//
// So a block read becomes: ask APF to drop 512 bytes at our buffer's bridge
// address, wait for done, then walk the buffer out to the overlay. A block
// write is the same in reverse. LBA maps to slotoffset as lba * 512.
//
// The buffer is filled and drained by data_loader / data_unloader rather than
// by hand. They are the idiomatic APF primitives for exactly this and they
// already contain the clk_74a <-> clk_sys crossing, which leaves this module
// with one clock domain and no CDC of its own beyond the command handshake.
//
// WHAT THIS DOES NOT DO
//
//   Multi-block transfers. hps_io supports up to 16 KB per request via
//   sd_blk_cnt; upstream instantiates it at BLKSZ=2 (512 bytes) and the overlay
//   drives no block count, so one block per request is the whole contract.
//   If upstream ever starts batching, this module must grow with it -- the
//   symptom would be saves that are silently truncated to their first sector.

`default_nettype none

module ngpc_sd_bridge #(
	// Which data slot holds the .sav, and where our block buffer lives in the
	// bridge address space. The upper nibble must agree with the data_loader
	// and data_unloader masks below.
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

	// ---- APF target commands, clk_74a ------------------------------------
	output wire        target_dataslot_read,
	output wire        target_dataslot_write,
	input  wire        target_dataslot_ack,
	input  wire        target_dataslot_done,
	input  wire  [2:0] target_dataslot_err,
	output wire [15:0] target_dataslot_id,
	output wire [31:0] target_dataslot_slotoffset,
	output wire [31:0] target_dataslot_bridgeaddr,
	output wire [31:0] target_dataslot_length,

	// ---- MiSTer block device, toward ngp_cart_overlay --------------------
	input  wire [31:0] sd_lba_i,
	input  wire        sd_rd_i,
	input  wire        sd_wr_i,
	output reg         sd_ack_o,
	output reg  [12:0] sd_buff_addr_o,
	output reg  [15:0] sd_buff_dout_o,   // toward the core, on a read
	output reg         sd_buff_wr_o,
	input  wire [15:0] sd_buff_din_i,    // from the core, on a write

	output reg         err_o             // last transfer reported a host error
);

	localparam int unsigned WORDS = 256;   // 512 bytes as 16-bit words

	// ---- The block buffer -------------------------------------------------
	//
	// Two write sources that never overlap in time: APF filling it before a
	// block read, and the overlay filling it before a block write.

	reg [15:0] buffer [0:WORDS-1];

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

	// ---- Command handshake, crossed into clk_sys --------------------------

	reg  req_read;
	reg  req_write;
	wire done_s;
	wire ack_s;

	synch_3 u_done (target_dataslot_done, done_s, clk_sys);
	synch_3 u_ack  (target_dataslot_ack,  ack_s,  clk_sys);

	// core_bridge_cmd edge-detects these in clk_74a, so they cross as levels
	// through its own synchronisers' equivalent: two flops here, then its edge
	// detector. A pulse shorter than a clk_74a period could be missed, so the
	// request is HELD until the host acknowledges it.
	wire req_read_74a;
	wire req_write_74a;

	synch_3 u_rd_req (req_read,  req_read_74a,  clk_74a);
	synch_3 u_wr_req (req_write, req_write_74a, clk_74a);

	assign target_dataslot_read  = req_read_74a;
	assign target_dataslot_write = req_write_74a;

	reg [31:0] lba_q;

	assign target_dataslot_id         = SAVE_SLOT_ID;
	assign target_dataslot_slotoffset = {lba_q[22:0], 9'd0};  // lba * 512
	assign target_dataslot_bridgeaddr = BUFFER_BRIDGE_ADDR;
	assign target_dataslot_length     = 32'd512;

	// ---- Transfer state machine ------------------------------------------

	localparam S_IDLE       = 3'd0;
	localparam S_HOST_READ  = 3'd1;   // APF is filling the buffer
	localparam S_TO_CORE    = 3'd2;   // walk the buffer out to the overlay
	localparam S_FROM_CORE  = 3'd3;   // walk the overlay's data into the buffer
	localparam S_HOST_WRITE = 3'd4;   // APF is draining the buffer
	localparam S_SETTLE     = 3'd5;

	reg [2:0] state;
	reg [8:0] idx;
	reg       saw_ack;

	always @(posedge clk_sys) begin
		sd_buff_wr_o <= 1'b0;

		if (apf_wr && (apf_wr_addr[8:1] < WORDS[7:0] || apf_wr_addr < 28'd512)) begin
			buffer[apf_wr_addr[8:1]] <= apf_wr_data;
		end

		apf_rd_data <= buffer[apf_rd_addr[8:1]];

		if (reset) begin
			state     <= S_IDLE;
			req_read  <= 1'b0;
			req_write <= 1'b0;
			sd_ack_o  <= 1'b0;
			err_o     <= 1'b0;
			idx       <= 9'd0;
			saw_ack   <= 1'b0;
		end else begin
			case (state)
				S_IDLE: begin
					sd_ack_o <= 1'b0;
					saw_ack  <= 1'b0;
					idx      <= 9'd0;

					if (sd_rd_i) begin
						lba_q    <= sd_lba_i;
						req_read <= 1'b1;
						state    <= S_HOST_READ;
					end else if (sd_wr_i) begin
						lba_q    <= sd_lba_i;
						// The core supplies the data first; ask the host to
						// take it only once the buffer is full.
						sd_ack_o <= 1'b1;
						state    <= S_FROM_CORE;
					end
				end

				// ---- file -> buffer -> core --------------------------------
				S_HOST_READ: begin
					if (ack_s) saw_ack <= 1'b1;
					if (saw_ack && done_s) begin
						req_read <= 1'b0;
						err_o    <= |target_dataslot_err;
						saw_ack  <= 1'b0;
						sd_ack_o <= 1'b1;
						state    <= S_TO_CORE;
					end
				end

				S_TO_CORE: begin
					sd_buff_addr_o <= {4'd0, idx};
					sd_buff_dout_o <= buffer[idx[7:0]];
					sd_buff_wr_o   <= 1'b1;

					if (idx == WORDS - 1) begin
						state <= S_SETTLE;
					end else begin
						idx <= idx + 9'd1;
					end
				end

				// ---- core -> buffer -> file --------------------------------
				S_FROM_CORE: begin
					sd_buff_addr_o <= {4'd0, idx};
					// One cycle of latency: the overlay presents din for the
					// address asserted last cycle.
					if (idx != 9'd0) buffer[idx[7:0] - 8'd1] <= sd_buff_din_i;

					if (idx == WORDS) begin
						sd_ack_o  <= 1'b0;
						req_write <= 1'b1;
						state     <= S_HOST_WRITE;
					end else begin
						idx <= idx + 9'd1;
					end
				end

				S_HOST_WRITE: begin
					if (ack_s) saw_ack <= 1'b1;
					if (saw_ack && done_s) begin
						req_write <= 1'b0;
						err_o     <= |target_dataslot_err;
						saw_ack   <= 1'b0;
						state     <= S_SETTLE;
					end
				end

				S_SETTLE: begin
					sd_ack_o <= 1'b0;
					// Do not accept another request until the overlay has
					// dropped this one, or a single strobe would be served
					// twice.
					if (!sd_rd_i && !sd_wr_i) state <= S_IDLE;
				end

				default: state <= S_IDLE;
			endcase
		end
	end

endmodule

`default_nettype wire
