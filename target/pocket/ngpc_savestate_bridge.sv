// NGPC for Analogue Pocket -- savestates, and therefore sleep.
//
// On the Pocket these are one feature. Closing the lid makes APF issue host
// command 0x00A0: the core must serialise its entire state and report an
// address and a length, and on wake 0x00A4 hands it back. There is no separate
// "sleep" to implement -- a core that can produce and consume a state blob can
// sleep, and one that cannot, cannot.
//
// Upstream's engine (savestates.sv) already does the hard part: it walks the
// machine's internals bus and its memories and turns them into a stream of
// 64-bit words. On MiSTer that stream goes into DDR3 and Main writes the file.
// Here it goes into a FIFO that APF drains through the bridge, and on restore
// APF fills a FIFO that the engine reads back. The engine cannot tell the
// difference: its bus_out_* port is a request/done mailbox and never learns
// what is on the other side.
//
// CARTRIDGE FLASH, and why it is not in here.
//
// The engine is configured with savetype3_size = 0, so the state does NOT
// contain cartridge flash. Upstream carries flash separately in a sparse Type3
// tail -- 1,752 lines of manifest and store that this device has no room for.
//
// That matters because sleep powers the FPGA down and SDRAM loses the
// cartridge. On wake APF reloads it from its file, which is the PRISTINE image:
// every block the game wrote during the session would be gone, and the restored
// machine state would describe flash that no longer exists.
//
// ngpc_cart_save handles that independently and continuously -- it stages dirty
// blocks into the nonvolatile slot whenever the flash goes quiet, so by the time
// APF asks for a state the cartridge side is already saved. This module used to
// trigger a save and wait for it; with staging always current there is nothing
// to trigger.
//
// On wake the order still matters and still holds: the cartridge is reloaded,
// the staged blocks are applied while the machine is held in reset, and only
// then is the state restored.
//
// A state blob is only coherent with the save staged at the same moment.
// Nothing here detects a mismatched pair, which is worth fixing before this is
// relied upon.

`default_nettype none

module ngpc_savestate_bridge #(
	// Where APF reads and writes the blob in the core's bridge address space.
	parameter [3:0] BLOB_ADDR_NIBBLE = 4'h4
) (
	input  wire        clk_sys,
	input  wire        clk_74a,
	input  wire        reset,

	// ---- APF savestate handshake, clk_74a ---------------------------------
	input  wire        savestate_start,
	output wire        savestate_start_ack,
	output wire        savestate_start_busy,
	output wire        savestate_start_ok,
	output wire        savestate_start_err,

	input  wire        savestate_load,
	output wire        savestate_load_ack,
	output wire        savestate_load_busy,
	output wire        savestate_load_ok,
	output wire        savestate_load_err,

	// ---- APF bridge -------------------------------------------------------
	input  wire        bridge_wr,
	input  wire        bridge_rd,
	input  wire [31:0] bridge_addr,
	input  wire [31:0] bridge_wr_data,
	output wire [31:0] bridge_rd_data,

	// ---- The engine (savestates.sv), clk_sys ------------------------------
	output reg         ss_save,
	output reg         ss_load,
	input  wire        ss_busy,

	input  wire [63:0] bus_out_Din,     // engine -> here, on a save
	output wire [63:0] bus_out_Dout,    // here -> engine, on a restore
	input  wire [25:0] bus_out_Adr,
	input  wire        bus_out_rnw,     // 1 = read (restore), 0 = write (save)
	input  wire        bus_out_ena,
	input  wire  [7:0] bus_out_be,
	output reg         bus_out_done
);

	// ---- APF-side status, crossed back to clk_74a -------------------------

	reg start_ack_q, start_busy_q, start_ok_q, start_err_q;
	reg load_ack_q,  load_busy_q,  load_ok_q,  load_err_q;

	synch_3 #(
		.WIDTH(8)
	) status_sync (
		{start_ack_q, start_busy_q, start_ok_q, start_err_q,
		 load_ack_q,  load_busy_q,  load_ok_q,  load_err_q},
		{savestate_start_ack, savestate_start_busy, savestate_start_ok, savestate_start_err,
		 savestate_load_ack,  savestate_load_busy,  savestate_load_ok,  savestate_load_err},
		clk_74a
	);

	wire start_s, load_s;

	synch_3 #(
		.WIDTH(2)
	) req_sync (
		{savestate_start, savestate_load},
		{start_s, load_s},
		clk_sys
	);

	// ---- Save path: engine -> FIFO -> APF reads ---------------------------
	//
	// APF reads the blob sequentially, so a FIFO is the whole mechanism: every
	// bridge read at the blob address pops the next 32-bit half. The engine
	// produces 64-bit words, so the FIFO is width-converting and the halves
	// come out in the order APF asked for them.

	wire        save_fifo_full;
	wire        save_fifo_rdempty;
	reg         save_fifo_wr;
	reg         save_fifo_rd;
	wire [31:0] save_fifo_q;

	// bridge_endian_little is low, so APF's 32-bit words arrive and leave
	// big-endian. The swizzle here and its inverse on the load path are each
	// other's mirror; nothing outside this module sees the byte order, so the
	// only requirement is that the two agree.
	wire [63:0] save_fifo_data = {
		bus_out_Din[39:32], bus_out_Din[47:40], bus_out_Din[55:48], bus_out_Din[63:56],
		bus_out_Din[ 7: 0], bus_out_Din[15: 8], bus_out_Din[23:16], bus_out_Din[31:24]
	};

	dcfifo_mixed_widths save_fifo (
		.data   (save_fifo_data),
		.wrclk  (clk_sys),
		.wrreq  (save_fifo_wr),
		.rdclk  (clk_74a),
		.rdreq  (save_fifo_rd),
		.q      (save_fifo_q),
		.wrfull (save_fifo_full),
		.rdempty(save_fifo_rdempty)
	);
	defparam save_fifo.intended_device_family = "Cyclone V",
	         save_fifo.lpm_numwords = 256, save_fifo.lpm_showahead = "ON",
	         save_fifo.lpm_type = "dcfifo_mixed_widths",
	         save_fifo.lpm_width = 64, save_fifo.lpm_widthu = 8,
	         save_fifo.lpm_width_r = 32, save_fifo.lpm_widthu_r = 9,
	         save_fifo.overflow_checking = "ON", save_fifo.underflow_checking = "ON",
	         save_fifo.rdsync_delaypipe = 5, save_fifo.wrsync_delaypipe = 5,
	         save_fifo.use_eab = "ON";

	// ---- Load path: APF writes -> FIFO -> engine --------------------------

	wire        load_fifo_wrfull;
	wire        load_fifo_empty;
	reg         load_fifo_rd;
	wire [63:0] load_fifo_q;
	reg         load_fifo_clr;

	dcfifo_mixed_widths load_fifo (
		.data   (bridge_wr_data),
		.wrclk  (clk_74a),
		.wrreq  (bridge_wr && bridge_addr[31:28] == BLOB_ADDR_NIBBLE),
		.rdclk  (clk_sys),
		.rdreq  (load_fifo_rd),
		.q      (load_fifo_q),
		.rdempty(load_fifo_empty),
		.wrfull (load_fifo_wrfull),
		.aclr   (load_fifo_clr)
	);
	defparam load_fifo.intended_device_family = "Cyclone V",
	         load_fifo.lpm_numwords = 512, load_fifo.lpm_showahead = "ON",
	         load_fifo.lpm_type = "dcfifo_mixed_widths",
	         load_fifo.lpm_width = 32, load_fifo.lpm_widthu = 9,
	         load_fifo.lpm_width_r = 64, load_fifo.lpm_widthu_r = 8,
	         load_fifo.overflow_checking = "ON", load_fifo.underflow_checking = "ON",
	         load_fifo.rdsync_delaypipe = 5, load_fifo.wrsync_delaypipe = 5,
	         load_fifo.write_aclr_synch = "ON", load_fifo.use_eab = "ON";

	assign bus_out_Dout = {
		load_fifo_q[39:32], load_fifo_q[47:40], load_fifo_q[55:48], load_fifo_q[63:56],
		load_fifo_q[ 7: 0], load_fifo_q[15: 8], load_fifo_q[23:16], load_fifo_q[31:24]
	};

	// A bridge read at the blob address pops the save FIFO. showahead means the
	// head is already on q, so the value returned belongs to this read and the
	// pop advances for the next one.
	reg prev_bridge_rd;
	wire blob_rd = bridge_rd && bridge_addr[31:28] == BLOB_ADDR_NIBBLE;

	always @(posedge clk_74a) begin
		prev_bridge_rd <= blob_rd;
		save_fifo_rd   <= blob_rd && !prev_bridge_rd && !save_fifo_rdempty;
	end

	assign bridge_rd_data = save_fifo_q;

	// ---- Sequencing --------------------------------------------------------

	localparam S_IDLE       = 3'd0;
	localparam S_SAVE_RUN   = 3'd2;
	localparam S_LOAD_RUN   = 3'd3;
	localparam S_DONE       = 3'd4;

	reg [2:0] state;
	reg       prev_start, prev_load, prev_ss_busy;

	always @(posedge clk_sys) begin
		ss_save       <= 1'b0;
		ss_load       <= 1'b0;
		save_fifo_wr  <= 1'b0;
		load_fifo_rd  <= 1'b0;
		bus_out_done  <= 1'b0;
		load_fifo_clr <= 1'b0;

		prev_start   <= start_s;
		prev_load    <= load_s;
		prev_ss_busy <= ss_busy;

		// The engine's mailbox. A write hands us a word; a read wants one.
		if (bus_out_ena) begin
			if (!bus_out_rnw) begin
				if (!save_fifo_full) begin
					save_fifo_wr <= 1'b1;
					bus_out_done <= 1'b1;
				end
			end else begin
				if (!load_fifo_empty) begin
					load_fifo_rd <= 1'b1;
					bus_out_done <= 1'b1;
				end
			end
		end

		if (reset) begin
			state        <= S_IDLE;
			start_ack_q  <= 1'b0; start_busy_q <= 1'b0;
			start_ok_q   <= 1'b0; start_err_q  <= 1'b0;
			load_ack_q   <= 1'b0; load_busy_q  <= 1'b0;
			load_ok_q    <= 1'b0; load_err_q   <= 1'b0;
		end else begin
			case (state)
				S_IDLE: begin
					start_ack_q <= 1'b0;
					load_ack_q  <= 1'b0;

					if (start_s && !prev_start) begin
						start_ack_q  <= 1'b1;
						start_busy_q <= 1'b1;
						start_ok_q   <= 1'b0;
						start_err_q  <= 1'b0;
						ss_save      <= 1'b1;
						state        <= S_SAVE_RUN;
					end else if (load_s && !prev_load) begin
						load_ack_q  <= 1'b1;
						load_busy_q <= 1'b1;
						load_ok_q   <= 1'b0;
						load_err_q  <= 1'b0;
						ss_load     <= 1'b1;
						state       <= S_LOAD_RUN;
					end
				end

				S_SAVE_RUN: begin
					start_ack_q <= 1'b0;
					if (prev_ss_busy && !ss_busy) begin
						start_busy_q <= 1'b0;
						start_ok_q   <= 1'b1;
						state        <= S_DONE;
					end
				end

				S_LOAD_RUN: begin
					load_ack_q <= 1'b0;
					if (prev_ss_busy && !ss_busy) begin
						load_busy_q   <= 1'b0;
						load_ok_q     <= 1'b1;
						load_fifo_clr <= 1'b1;
						state         <= S_DONE;
					end
				end

				S_DONE: begin
					if (!start_s && !load_s) state <= S_IDLE;
				end

				default: state <= S_IDLE;
			endcase
		end
	end

	wire unused_ok = &{1'b0, bus_out_Adr, bus_out_be, save_fifo_full,
	                   load_fifo_wrfull, 1'b0};

endmodule

`default_nettype wire
