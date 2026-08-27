//
// NGPC for Analogue Pocket -- user core top level.
//
// Instantiated by the real top level, apf_top. The port list below is APF's
// and is not ours to change; everything after it is this core.
//
// The machine itself lives in ngpc_machine.sv, which is the Pocket's answer to
// upstream's NGPC.sv. This file is the framework face: clocks, the bridge, data
// slots, controls, and the video/audio pads.
//
`default_nettype none

module core_top (

    //
    // physical connections
    //

    ///////////////////////////////////////////////////
    // clock inputs 74.25mhz. not phase aligned, so treat these domains as asynchronous

    input wire clk_74a,  // mainclk1
    input wire clk_74b,  // mainclk1

    ///////////////////////////////////////////////////
    // cartridge interface
    // switches between 3.3v and 5v mechanically
    // output enable for multibit translators controlled by pic32

    // GBA AD[15:8]
    inout  wire [7:0] cart_tran_bank2,
    output wire       cart_tran_bank2_dir,

    // GBA AD[7:0]
    inout  wire [7:0] cart_tran_bank3,
    output wire       cart_tran_bank3_dir,

    // GBA A[23:16]
    inout  wire [7:0] cart_tran_bank1,
    output wire       cart_tran_bank1_dir,

    // GBA [7] PHI#
    // GBA [6] WR#
    // GBA [5] RD#
    // GBA [4] CS1#/CS#
    //     [3:0] unwired
    inout  wire [7:4] cart_tran_bank0,
    output wire       cart_tran_bank0_dir,

    // GBA CS2#/RES#
    inout  wire cart_tran_pin30,
    output wire cart_tran_pin30_dir,
    // when GBC cart is inserted, this signal when low or weak will pull GBC /RES low with a special circuit
    // the goal is that when unconfigured, the FPGA weak pullups won't interfere.
    // thus, if GBC cart is inserted, FPGA must drive this high in order to let the level translators
    // and general IO drive this pin.
    output wire cart_pin30_pwroff_reset,

    // GBA IRQ/DRQ
    inout  wire cart_tran_pin31,
    output wire cart_tran_pin31_dir,

    // infrared
    input  wire port_ir_rx,
    output wire port_ir_tx,
    output wire port_ir_rx_disable,

    // GBA link port
    inout  wire port_tran_si,
    output wire port_tran_si_dir,
    inout  wire port_tran_so,
    output wire port_tran_so_dir,
    inout  wire port_tran_sck,
    output wire port_tran_sck_dir,
    inout  wire port_tran_sd,
    output wire port_tran_sd_dir,

    ///////////////////////////////////////////////////
    // cellular psram 0 and 1, two chips (64mbit x2 dual die per chip)

    output wire [21:16] cram0_a,
    inout  wire [ 15:0] cram0_dq,
    input  wire         cram0_wait,
    output wire         cram0_clk,
    output wire         cram0_adv_n,
    output wire         cram0_cre,
    output wire         cram0_ce0_n,
    output wire         cram0_ce1_n,
    output wire         cram0_oe_n,
    output wire         cram0_we_n,
    output wire         cram0_ub_n,
    output wire         cram0_lb_n,

    output wire [21:16] cram1_a,
    inout  wire [ 15:0] cram1_dq,
    input  wire         cram1_wait,
    output wire         cram1_clk,
    output wire         cram1_adv_n,
    output wire         cram1_cre,
    output wire         cram1_ce0_n,
    output wire         cram1_ce1_n,
    output wire         cram1_oe_n,
    output wire         cram1_we_n,
    output wire         cram1_ub_n,
    output wire         cram1_lb_n,

    ///////////////////////////////////////////////////
    // sdram, 512mbit 16bit

    output wire [12:0] dram_a,
    output wire [ 1:0] dram_ba,
    inout  wire [15:0] dram_dq,
    output wire [ 1:0] dram_dqm,
    output wire        dram_clk,
    output wire        dram_cke,
    output wire        dram_ras_n,
    output wire        dram_cas_n,
    output wire        dram_we_n,

    ///////////////////////////////////////////////////
    // sram, 1mbit 16bit

    output wire [16:0] sram_a,
    inout  wire [15:0] sram_dq,
    output wire        sram_oe_n,
    output wire        sram_we_n,
    output wire        sram_ub_n,
    output wire        sram_lb_n,

    ///////////////////////////////////////////////////
    // vblank driven by dock for sync in a certain mode

    input wire vblank,

    ///////////////////////////////////////////////////
    // i/o to 6515D breakout usb uart

    output wire dbg_tx,
    input  wire dbg_rx,

    ///////////////////////////////////////////////////
    // i/o pads near jtag connector user can solder to

    output wire user1,
    input  wire user2,

    ///////////////////////////////////////////////////
    // RFU internal i2c bus

    inout  wire aux_sda,
    output wire aux_scl,

    ///////////////////////////////////////////////////
    // RFU, do not use
    output wire vpll_feed,


    //
    // logical connections
    //

    ///////////////////////////////////////////////////
    // video, audio output to scaler
    output wire [23:0] video_rgb,
    output wire        video_rgb_clock,
    output wire        video_rgb_clock_90,
    output wire        video_de,
    output wire        video_skip,
    output wire        video_vs,
    output wire        video_hs,

    output wire audio_mclk,
    input  wire audio_adc,
    output wire audio_dac,
    output wire audio_lrck,

    ///////////////////////////////////////////////////
    // bridge bus connection
    // synchronous to clk_74a
    output wire        bridge_endian_little,
    input  wire [31:0] bridge_addr,
    input  wire        bridge_rd,
    output reg  [31:0] bridge_rd_data,
    input  wire        bridge_wr,
    input  wire [31:0] bridge_wr_data,

    ///////////////////////////////////////////////////
    // controller data
    //
    // key bitmap:
    //   [0]    dpad_up
    //   [1]    dpad_down
    //   [2]    dpad_left
    //   [3]    dpad_right
    //   [4]    face_a
    //   [5]    face_b
    //   [6]    face_x
    //   [7]    face_y
    //   [8]    trig_l1
    //   [9]    trig_r1
    //   [10]   trig_l2
    //   [11]   trig_r2
    //   [12]   trig_l3
    //   [13]   trig_r3
    //   [14]   face_select
    //   [15]   face_start
    // joy values - unsigned
    //   [ 7: 0] lstick_x
    //   [15: 8] lstick_y
    //   [23:16] rstick_x
    //   [31:24] rstick_y
    // trigger values - unsigned
    //   [ 7: 0] ltrig
    //   [15: 8] rtrig
    //
    input wire [15:0] cont1_key,
    input wire [15:0] cont2_key,
    input wire [15:0] cont3_key,
    input wire [15:0] cont4_key,
    input wire [31:0] cont1_joy,
    input wire [31:0] cont2_joy,
    input wire [31:0] cont3_joy,
    input wire [31:0] cont4_joy,
    input wire [15:0] cont1_trig,
    input wire [15:0] cont2_trig,
    input wire [15:0] cont3_trig,
    input wire [15:0] cont4_trig

);

  // ----------------------------------------------------------------------
  //  Unused physical connections
  // ----------------------------------------------------------------------

  // No IR: turn off the LED and disable the receive circuit to save power.
  assign port_ir_tx              = 0;
  assign port_ir_rx_disable      = 1;

  assign bridge_endian_little    = 0;

  // No cartridge adapter. Directions are 0:IN, 1:OUT.
  assign cart_tran_bank3         = 8'hzz;
  assign cart_tran_bank3_dir     = 1'b0;
  assign cart_tran_bank2         = 8'hzz;
  assign cart_tran_bank2_dir     = 1'b0;
  assign cart_tran_bank1         = 8'hzz;
  assign cart_tran_bank1_dir     = 1'b0;
  assign cart_tran_bank0         = 4'hf;
  assign cart_tran_bank0_dir     = 1'b1;
  assign cart_tran_pin30         = 1'b0;
  assign cart_tran_pin30_dir     = 1'bz;
  assign cart_pin30_pwroff_reset = 1'b0;
  assign cart_tran_pin31         = 1'bz;
  assign cart_tran_pin31_dir     = 1'b0;

  // The NGP link port is a real feature of the machine and the core models it
  // (ngp_sio, 19200 baud). Wiring it to the Pocket's link connector is a later
  // exercise; for now the machine sees an unplugged cable, which ngpc_machine
  // states as the pad pull-ups rather than as a tie-off.
  assign port_tran_so            = 1'bz;
  assign port_tran_so_dir        = 1'b0;
  assign port_tran_si            = 1'bz;
  assign port_tran_si_dir        = 1'b0;
  assign port_tran_sck           = 1'bz;
  assign port_tran_sck_dir       = 1'b0;
  assign port_tran_sd            = 1'bz;
  assign port_tran_sd_dir        = 1'b0;

  // `dram` is the cartridge backing store, driven by the machine. The PSRAM and
  // SRAM stay unused: the cartridge is at most 4 MB and the SDRAM is 64 MB, so
  // the pristine shadow the MiSTer core keeps in DDR3 will fit alongside the
  // live image in this same chip when phase 3 needs it.
  //
  // Note the missing chip select: the Pocket ties SDRAM CS low on the board, so
  // there is no pin for it. ngpc_machine's header explains why that is safe
  // with this controller.

  // cram0 is the save staging region -- see ngpc_stage_mem. cram1 stays free.

  assign cram1_a                 = 'h0;
  assign cram1_dq                = {16{1'bZ}};
  assign cram1_clk               = 0;
  assign cram1_adv_n             = 1;
  assign cram1_cre               = 0;
  assign cram1_ce0_n             = 1;
  assign cram1_ce1_n             = 1;
  assign cram1_oe_n              = 1;
  assign cram1_we_n              = 1;
  assign cram1_ub_n              = 1;
  assign cram1_lb_n              = 1;

  assign sram_a                  = 'h0;
  assign sram_dq                 = {16{1'bZ}};
  assign sram_oe_n               = 1;
  assign sram_we_n               = 1;
  assign sram_ub_n               = 1;
  assign sram_lb_n               = 1;

  assign dbg_tx                  = 1'bZ;
  assign user1                   = 1'bZ;
  assign aux_scl                 = 1'bZ;
  assign vpll_feed               = 1'bZ;

  // ----------------------------------------------------------------------
  //  Bridge read mux
  // ----------------------------------------------------------------------

  always @(*) begin
    casex (bridge_addr)
      default: begin
        bridge_rd_data <= 0;
      end
      32'hF8xxxxxx: begin
        bridge_rd_data <= cmd_bridge_rd_data;
      end
    endcase

    // The save block buffer, which APF drains during a target write.
    if (bridge_addr[31:28] == 4'h1) begin
      bridge_rd_data <= stage_bridge_rd_data;
    end else if (bridge_addr[31:28] == 4'h4) begin
      // The savestate blob, which APF drains after asking for a state.
      bridge_rd_data <= savestate_rd_data;
    end
  end

  // ----------------------------------------------------------------------
  //  Settings
  // ----------------------------------------------------------------------
  //
  // Written by APF from interact.json, in clk_74a. Each one is the Pocket's
  // stand-in for a CONF_STR status bit; the comment gives the MiSTer bit so the
  // two menus can be kept in step.

  reg [1:0] opt_system = 2'd0;      // status[2:1]  0 NGPC, 1 Auto, 2 NGP
  reg       opt_language_jp = 0;    // status[3]
  reg [2:0] opt_palette = 3'd0;     // status[16:14]
  reg       opt_skip_anim = 0;      // !status[19]
  reg       opt_use_host_rtc = 0;   // !status[17]   PHASE 3: needs the APF RTC
  reg       opt_auto_power = 1;     // status[18]
  reg       opt_lcd_response = 0;   // status[20]    accepted, presenter ignores


  // Cartridge saves. The two actions are toggles rather than levels: APF
  // writes a value on every menu selection, and the machine wants an edge.
  reg       opt_autosave_off = 0;
  reg       save_pulse_74 = 0;
  reg       load_pulse_74 = 0;

  reg [31:0] reset_delay = 0;
  wire       external_reset = reset_delay > 0;

  always @(posedge clk_74a) begin
    if (reset_delay > 0) reset_delay <= reset_delay - 1;

    if (bridge_wr) begin
      case (bridge_addr)
        32'h050: reset_delay      <= 32'h100000;
        32'h100: opt_system       <= bridge_wr_data[1:0];
        32'h104: opt_language_jp  <= bridge_wr_data[0];
        32'h108: opt_palette      <= bridge_wr_data[2:0];
        32'h10C: opt_skip_anim    <= bridge_wr_data[0];
        32'h110: opt_auto_power   <= bridge_wr_data[0];
        32'h114: opt_lcd_response <= bridge_wr_data[0];
        32'h118: opt_use_host_rtc <= bridge_wr_data[0];
        32'h120: opt_autosave_off <= bridge_wr_data[0];
        32'h124: save_pulse_74    <= ~save_pulse_74;
        32'h128: load_pulse_74    <= ~load_pulse_74;
      endcase
    end
  end

  // Settings change orders of magnitude more slowly than they are read and are
  // consumed as level inputs, so two flops each is the whole crossing.
  wire [1:0] opt_system_s;
  wire       opt_language_jp_s;
  wire [2:0] opt_palette_s;
  wire       opt_skip_anim_s;
  wire       opt_use_host_rtc_s;
  wire       opt_auto_power_s;
  wire       opt_lcd_response_s;
  wire       opt_autosave_off_s;
  wire       save_pulse_s;
  wire       load_pulse_s;

  synch_3 #(
      .WIDTH(13)
  ) settings_sync (
      {opt_system, opt_language_jp, opt_palette, opt_skip_anim,
       opt_use_host_rtc, opt_auto_power, opt_lcd_response,
       opt_autosave_off, save_pulse_74, load_pulse_74},
      {opt_system_s, opt_language_jp_s, opt_palette_s, opt_skip_anim_s,
       opt_use_host_rtc_s, opt_auto_power_s, opt_lcd_response_s,
       opt_autosave_off_s, save_pulse_s, load_pulse_s},
      clk_sys
  );

  // Edge-detect the two action toggles in the machine's own domain.
  reg  save_pulse_q, load_pulse_q;
  wire save_request = save_pulse_s ^ save_pulse_q;
  wire load_request = load_pulse_s ^ load_pulse_q;

  always @(posedge clk_sys) begin
    save_pulse_q <= save_pulse_s;
    load_pulse_q <= load_pulse_s;
  end

  // ----------------------------------------------------------------------
  //  Host/target command handler
  // ----------------------------------------------------------------------

  wire        reset_n;
  wire [31:0] cmd_bridge_rd_data;

  wire status_boot_done  = pll_core_locked;
  wire status_setup_done = pll_core_locked;
  wire status_running    = reset_n;

  wire        dataslot_requestread;
  wire [15:0] dataslot_requestread_id;
  wire        dataslot_requestread_ack = 1;
  wire        dataslot_requestread_ok = 1;

  wire        dataslot_requestwrite;
  wire [15:0] dataslot_requestwrite_id;
  wire        dataslot_requestwrite_ack = 1;
  wire        dataslot_requestwrite_ok = 1;

  wire        dataslot_allcomplete;

  // 8,416 words of internals at 8 bytes each, plus the three memory regions.
  // Cartridge flash is deliberately NOT in the blob; ngpc_savestate_bridge
  // explains where it goes instead and why the ordering works.
  wire        savestate_supported = 1;
  wire [31:0] savestate_addr = 32'h40000000;
  // What the engine actually emits, counted the way savestates.sv counts it.
  // bus_out_Adr is in 32-bit words:
  //
  //   header      HEADERCOUNT             = 2 words
  //   internals   INTERNALSCOUNT * 2      = 224 words   (112 64-bit words)
  //   memories    (12288+4096+16384) / 4  = 8192 words  (savetype 0,1,2)
  //                                       ---------
  //                                         8418 words = 33,672 bytes
  //
  // This was previously state_size_i * 8 plus the memory sizes, which confused
  // state_size_i -- a validation field stamped into the header -- with the
  // internal register count that actually governs the transfer. It declared
  // 100,096 bytes for a 33,672 byte state, so APF read three times the blob and
  // the tail was whatever the store happened to hold.
  // 33,672 is the engine's state. The extra 24 bytes are two pad words plus
  // the identity block ngpc_savestate_bridge stamps at words 8420-8423: magic,
  // cartridge CRC32, layout version, inverted CRC. A load checks it before the
  // engine starts, so a state from a different cartridge is rejected cleanly.
  wire [31:0] savestate_size = 32'd33696;   // 8424 words: 8418 state + pad + identity
  wire [31:0] savestate_maxloadsize = savestate_size + 32'h1000;

  wire        savestate_start;
  wire        savestate_start_ack;
  wire        savestate_start_busy;
  wire        savestate_start_ok;
  wire        savestate_start_err;

  wire        savestate_load;
  wire        savestate_load_ack;
  wire        savestate_load_busy;
  wire        savestate_load_ok;
  wire        savestate_load_err;

  // THE DATA-SLOT SIZE TABLE, and why no save file ever appeared without it.
  //
  // At shutdown APF flushes a nonvolatile slot by asking THIS table how many
  // bytes to read -- "size of the file is determined by the Dataslot ID/Size
  // Table BRAM in the core" (Analogue data.json docs). With no file loaded at
  // boot the entry holds zero, so every flush wrote zero bytes: no file, no
  // error, forever. The core must claim the size itself; the reference NES
  // core does exactly this, continuously.
  //
  // Table layout is [index*2] = id, [index*2 + 1] = size, indexed by the
  // slot's POSITION in data.json, not its id. Save is the fourth slot, so its
  // size lives at address 7. The size is claimed only while a save actually
  // exists, so games that never touch flash never leave a file behind.
  reg  [9:0] datatable_addr;
  reg        datatable_wren;
  reg [31:0] datatable_data;

  wire save_present_s;

  synch_3 save_present_sync (save_present, save_present_s, clk_74a);

  // WRITE THE ENTRY ONLY WHILE A SAVE EXISTS -- never write zero. APF uses
  // this same table as its own bookkeeping during slot DELIVERY, and the
  // first version of this block stomped the entry to 0 while the save slot
  // was still streaming in: APF delivered exactly one 512-byte sector and
  // cleanly stopped (measured by the ingest counters: 256 beats, 0 drops).
  // The reference NES core writes its entry continuously without breaking
  // loads only because its has_save is known from the cartridge header
  // before the save slot streams; ours cannot be true that early. Leaving
  // the entry alone keeps APF's own value -- the loaded file's size -- so a
  // restored save flushes correctly even before the game writes flash, and
  // a game with no save leaves no file behind.
  // 0xFE00: the slot deliberately sits UNDER 64 KB. Every probe agreed the
  // firmware delivers exactly (size mod 0x10000) bytes of a nonvolatile slot
  // -- our 0x40200 slot got 0x200 bytes, the file's tail, deterministically,
  // cold boot included -- and no working core on this card has a save file
  // over ~64 KB, so nobody had ever crossed the boundary. 512 bytes of
  // header plus 63 KB of payload is roughly double the largest real NGP
  // save. NOTE: staging is not yet clamped to the smaller payload; a game
  // dirtying more than 63 KB of flash would stage past the flushed region
  // and restore junk for the overflow blocks. No known game does; clamp
  // before calling this done.
  always @(posedge clk_74a) begin
    datatable_wren <= save_present_s;
    datatable_addr <= 10'd7;                 // slot index 3 (Save), size word
    datatable_data <= 32'h0000FE00;
  end

  core_bridge_cmd icb (
      .clk    (clk_74a),
      .reset_n(reset_n),

      .bridge_endian_little(bridge_endian_little),
      .bridge_addr         (bridge_addr),
      .bridge_rd           (bridge_rd),
      .bridge_rd_data      (cmd_bridge_rd_data),
      .bridge_wr           (bridge_wr),
      .bridge_wr_data      (bridge_wr_data),

      .status_boot_done (status_boot_done),
      .status_setup_done(status_setup_done),
      .status_running   (status_running),

      .dataslot_requestread    (dataslot_requestread),
      .dataslot_requestread_id (dataslot_requestread_id),
      .dataslot_requestread_ack(dataslot_requestread_ack),
      .dataslot_requestread_ok (dataslot_requestread_ok),

      .dataslot_requestwrite    (dataslot_requestwrite),
      .dataslot_requestwrite_id (dataslot_requestwrite_id),
      .dataslot_requestwrite_ack(dataslot_requestwrite_ack),
      .dataslot_requestwrite_ok (dataslot_requestwrite_ok),

      .dataslot_allcomplete(dataslot_allcomplete),

      .savestate_supported  (savestate_supported),
      .savestate_addr       (savestate_addr),
      .savestate_size       (savestate_size),
      .savestate_maxloadsize(savestate_maxloadsize),

      .savestate_start     (savestate_start),
      .savestate_start_ack (savestate_start_ack),
      .savestate_start_busy(savestate_start_busy),
      .savestate_start_ok  (savestate_start_ok),
      .savestate_start_err (savestate_start_err),

      .savestate_load     (savestate_load),
      .savestate_load_ack (savestate_load_ack),
      .savestate_load_busy(savestate_load_busy),
      .savestate_load_ok  (savestate_load_ok),
      .savestate_load_err (savestate_load_err),

      .datatable_addr(datatable_addr),
      .datatable_wren(datatable_wren),
      .datatable_data(datatable_data),
      .datatable_q   (),

      .dataslot_update          (dataslot_update),
      .dataslot_update_id       (dataslot_update_id),
      .dataslot_update_size     (dataslot_update_size),

      .osnotify_inmenu(osnotify_inmenu),

      // A nonvolatile slot needs no target commands: APF moves it in and out
      // on its own schedule.
      .target_dataslot_read      (1'b0),
      .target_dataslot_write     (1'b0),
      .target_dataslot_getfile   (1'b0),
      .target_dataslot_openfile  (1'b0),
      .target_dataslot_ack       (),
      .target_dataslot_done      (),
      .target_dataslot_err       (),
      .target_dataslot_id        (16'd0),
      .target_dataslot_slotoffset(32'd0),
      .target_dataslot_bridgeaddr(32'd0),
      .target_dataslot_length    (32'd0),
      .target_buffer_param_struct(32'h60000000),
      .target_buffer_resp_struct (32'h60000400)
  );

  // ---- Cartridge saves --------------------------------------------------

  wire        osnotify_inmenu;
  wire        dataslot_update;
  wire [15:0] dataslot_update_id;
  wire [31:0] dataslot_update_size;


  // ---- Save staging: a nonvolatile slot, served from PSRAM ---------------
  //
  // APF writes the slot into this region at core start and reads it back at
  // exit. Neither direction involves a command from us: the core owns the
  // memory, the host owns the file. That is the whole mechanism.

  wire        stage_req;
  wire        stage_we;
  wire [24:0] stage_addr;
  wire [15:0] stage_wdata;
  wire        stage_ready;
  wire        stage_done;
  wire [15:0] stage_rdata;
  wire        host_busy;
  wire [15:0] stage_diag_beats, stage_diag_drops, stage_diag_depth;
  wire [15:0] stage_diag_first, stage_diag_last, stage_diag_reads;

  wire        stage_host_wr;
  wire [27:0] stage_host_wr_addr;
  wire [15:0] stage_host_wr_data;

  wire        stage_host_rd;
  wire [27:0] stage_host_rd_addr;
  wire [15:0] stage_host_rd_data;
  wire [31:0] stage_bridge_rd_data;

  // PSRAM answers in a bounded ~70 ns with no refresh, so the unloader's fixed
  // read latency is honest here. Against cartridge SDRAM it would not be --
  // a refresh or a burst of CPU fetches would stretch the access and this
  // would latch whatever happened to be on the bus.
  // The flush reads arrive at the slot's address too -- nibble 1 now. APF
  // never reads the BIOS or cartridge slots back, so every nibble-1 read is
  // the save flush and the mask can stay a whole-nibble one.
  data_unloader #(
      .ADDRESS_MASK_UPPER_4(4'h1),
      .INPUT_WORD_SIZE(2),
      .READ_MEM_CLOCK_DELAY(32)
  ) stage_drain (
      .clk_74a   (clk_74a),
      .clk_memory(clk_sys),

      .bridge_rd           (bridge_rd),
      .bridge_endian_little(bridge_endian_little),
      .bridge_addr         (bridge_addr),
      .bridge_rd_data      (stage_bridge_rd_data),

      .read_en  (stage_host_rd),
      .read_addr(stage_host_rd_addr),
      .read_data(stage_host_rd_data)
  );

  // Has APF finished delivering data slots? Slots stream in id order --
  // cartridge, BIOSes, then the nonvolatile save -- with SD file-open gaps
  // between them, and the save-apply in the machine must not run until the
  // save slot has actually landed in the staging region. Every slot write
  // (BIOS/cart at nibbles 1 and 3, staging at 5) resets this counter; when it
  // saturates, nothing has streamed for ~500 ms and delivery is over. Command
  // traffic at 0xF8 deliberately does not reset it.
  // Every slot -- BIOSes, cartridge, save -- now streams through nibble 1.
  wire slot_wr_any = bridge_wr && (bridge_addr[31:28] == 4'h1);

  localparam [25:0] SLOTS_SETTLE = 26'd37_125_000;   // ~500 ms at 74.25 MHz

  reg [25:0] slot_idle = 26'd0;

  always @(posedge clk_74a) begin
    if (slot_wr_any)                    slot_idle <= 26'd0;
    else if (slot_idle != SLOTS_SETTLE) slot_idle <= slot_idle + 26'd1;
  end

  wire slots_settled_74 = (slot_idle == SLOTS_SETTLE);
  wire slots_settled;

  synch_3 settle_sync (slots_settled_74, slots_settled, clk_sys);

  ngpc_stage_mem stage_mem (
      .clk  (clk_sys),
      .reset(reset_in),

      .host_wr_i     (stage_host_wr),
      .host_wr_addr_i(stage_host_wr_addr[24:0]),
      .host_wr_data_i(stage_host_wr_data),

      .host_rd_i     (stage_host_rd),
      .host_rd_addr_i(stage_host_rd_addr[24:0]),
      .host_rd_data_o(stage_host_rd_data),

      .host_busy_o(host_busy),
      .diag_beats_o(stage_diag_beats),
      .diag_drops_o(stage_diag_drops),
      .diag_depth_o(stage_diag_depth),
      .diag_first_o(stage_diag_first),
      .diag_last_o (stage_diag_last),
      .diag_reads_o(stage_diag_reads),

      .eng_req_i  (stage_req),
      .eng_we_i   (stage_we),
      .eng_addr_i (stage_addr),
      .eng_wdata_i(stage_wdata),
      .eng_ready_o(stage_ready),
      .eng_done_o (stage_done),
      .eng_rdata_o(stage_rdata),

      .cram_a    (cram0_a),
      .cram_dq   (cram0_dq),
      .cram_wait (cram0_wait),
      .cram_clk  (cram0_clk),
      .cram_adv_n(cram0_adv_n),
      .cram_cre  (cram0_cre),
      .cram_ce0_n(cram0_ce0_n),
      .cram_ce1_n(cram0_ce1_n),
      .cram_oe_n (cram0_oe_n),
      .cram_we_n (cram0_we_n),
      .cram_ub_n (cram0_ub_n),
      .cram_lb_n (cram0_lb_n)
  );

  // ----------------------------------------------------------------------
  //  BIOS load
  // ----------------------------------------------------------------------
  //
  // Slot 0 is the colour BIOS (MiSTer's boot0.rom), slot 1 the mono one
  // (boot1.rom). MiSTer distinguishes them by ioctl_index; here they are told
  // apart by which bridge address the words arrive on, and `bios_sel` picks the
  // destination BRAM inside the machine.

  // Slot 2 is the cartridge. Track it separately from the BIOS slots: the two
  // hold the machine in reset for different reasons, and a cartridge load is
  // additionally a cold session that clears work RAM.
  reg is_downloading_bios = 0;
  reg is_downloading_cart = 0;

  always @(posedge clk_74a) begin
    if (dataslot_requestwrite) begin
      if (dataslot_requestwrite_id == 16'd0) is_downloading_cart <= 1;
      else                                   is_downloading_bios <= 1;
    end else if (dataslot_allcomplete) begin
      is_downloading_bios <= 0;
      is_downloading_cart <= 0;
    end
  end

  wire bios_downloading;
  wire cart_downloading;

  synch_3 #(
      .WIDTH(2)
  ) download_sync (
      {is_downloading_bios, is_downloading_cart},
      {bios_downloading, cart_downloading},
      clk_sys
  );

  // Both BIOS images arrive through ONE loader, at two offsets inside the same
  // bridge nibble: the colour image at 0x10000000 and the mono image at
  // 0x10010000.
  //
  // They used to have a loader each, and the reason was real: the loader
  // crosses into clk_sys through a FIFO, so the last words of one image can
  // still be draining when APF announces the next slot, and switching the
  // destination on a slot id would land those words in the wrong ROM. The
  // destination has to be a property of the data, not of what the host is
  // currently pointing at.
  //
  // A single loader keeps that property. The write address travels through the
  // FIFO beside the data, so bit 16 of the address that comes OUT is the image
  // that word belongs to, whatever the host has moved on to. One FIFO also
  // removes the two-loader race entirely rather than dodging it -- there is now
  // one queue, and it drains in order.
  //
  // This is worth about 150 ALMs, which is the difference between fitting with
  // register retiming and not. See the retiming note in ngpc_pocket.qsf.
  //
  // OUTPUT_WORD_SIZE 2 reproduces hps_io's WIDE(1) behaviour exactly: with
  // bridge_endian_little low the loader byte-swaps, so write_data is
  // {file_byte1, file_byte0} and write_addr counts bytes -- the same little
  // endian 16-bit word and the same addr[15:1] the MiSTer top level feeds the
  // BIOS BRAM.
  wire        bios_wr_raw;
  wire [27:0] bios_addr_raw;
  wire [15:0] bios_data_raw;

  data_loader #(
      .ADDRESS_MASK_UPPER_4(4'h1),
      .OUTPUT_WORD_SIZE(2)
  ) bios_loader (
      .clk_74a   (clk_74a),
      .clk_memory(clk_sys),

      .bridge_wr          (bridge_wr),
      .bridge_endian_little(bridge_endian_little),
      .bridge_addr        (bridge_addr),
      .bridge_wr_data     (bridge_wr_data),

      .write_en  (bios_wr_raw),
      .write_addr(bios_addr_raw),
      .write_data(bios_data_raw)
  );

  // The cartridge shares this loader too, at a 16 MB offset inside the same
  // nibble (0x11000000). Three slots, one FIFO: they are loaded one at a time
  // and each was costing about 170 ALMs, most of it dcfifo. The destination is
  // still carried by the address rather than by a slot id, which is the
  // property that makes one loader safe -- see the note above.
  //
  //   0x0000000 - 0x000FFFF   colour BIOS
  //   0x0010000 - 0x001FFFF   mono BIOS
  //   0x1000000 - 0x13FFFFF   cartridge (4 MB maximum)
  //
  // So bit 24 says cartridge, and below it bit 16 says which BIOS image.
  // Bit 25 says save slot: the fourth consumer of the ONE slot loader. All
  // slots stream one at a time, and a third private dcfifo for the save path
  // was the ~150 ALMs that pushed the device past full. The flush direction
  // keeps its own unloader below -- reads cannot share a write FIFO.
  //
  //   0x0000000 - 0x000FFFF   colour BIOS
  //   0x0010000 - 0x001FFFF   mono BIOS
  //   0x1000000 - 0x13FFFFF   cartridge (4 MB maximum)
  //   0x2000000 - 0x203FFFF   nonvolatile save -> PSRAM staging region
  wire        ld_is_save = bios_addr_raw[25];
  wire        ld_is_cart = !ld_is_save && bios_addr_raw[24];

  // A BIOS image is 64 KiB, so bit 16 selects the image and bits 15:1 address
  // within it. The guard rejects anything past the mono image's end, which is
  // what the MiSTer top level's address guard does for a single image: a file
  // longer than its slot cannot wrap onto the start of either ROM.
  wire        bios_sel     = bios_addr_raw[16];
  wire        bios_wr      = bios_wr_raw && !ld_is_cart && !ld_is_save &&
                             (bios_addr_raw < 28'h20000);
  wire [14:0] bios_addr    = bios_addr_raw[15:1];
  wire [15:0] bios_ld_data = bios_data_raw;

  // The cartridge stream. Same 16-bit word shape; the machine buffers it before
  // ngp_cart_rom, which back-pressures. Bit 24 comes off to give the loader's
  // byte address within the image.
  wire        cart_wr      = bios_wr_raw && ld_is_cart;
  wire [27:0] cart_wr_addr = {4'd0, bios_addr_raw[23:0]};
  wire [15:0] cart_wr_data = bios_data_raw;

  // The save slot's writes, demuxed off the same stream. The [24:0] slice is
  // the byte offset within the slot, since bit 25 is the region select.
  assign stage_host_wr      = bios_wr_raw && ld_is_save;
  assign stage_host_wr_addr = {3'd0, bios_addr_raw[24:0]};
  assign stage_host_wr_data = bios_data_raw;

  // ----------------------------------------------------------------------
  //  Controls
  // ----------------------------------------------------------------------
  //
  // cont1_key is the APF layout: 0 up, 1 down, 2 left, 3 right, 4 A, 5 B,
  // 6 X, 7 Y, 8 L1, 9 R1, ... 14 select, 15 start.
  //
  // ngpc_machine wants the MiSTer joystick_0 order: 0 right, 1 left, 2 down,
  // 3 up, 4 A, 5 B, 6 Option, 7 Power.

  wire [15:0] cont1_key_s;

  synch_3 #(
      .WIDTH(16)
  ) controls_sync (
      cont1_key,
      cont1_key_s,
      clk_sys
  );

  // Assigned a bit at a time rather than by concatenation, on purpose. The
  // first version of this was a concatenation whose entries were commented
  // Right/Left/Down/Up reading downward -- but a concatenation's LAST entry is
  // bit 0, so the APF indices went in in APF order while carrying MiSTer
  // labels. The two orders differ by a transpose, and the machine came up
  // playing Up as Right and Down as Left. Indexed assignment makes the
  // destination bit explicit and the mistake unrepresentable.
  wire [7:0] joystick;

  assign joystick[0] = cont1_key_s[3];   // Right
  assign joystick[1] = cont1_key_s[2];   // Left
  assign joystick[2] = cont1_key_s[1];   // Down
  assign joystick[3] = cont1_key_s[0];   // Up
  assign joystick[4] = cont1_key_s[4];   // A
  assign joystick[5] = cont1_key_s[5];   // B
  assign joystick[6] = cont1_key_s[15];  // Option <- Start
  assign joystick[7] = cont1_key_s[14];  // Power  <- Select

  // ----------------------------------------------------------------------
  //  Reset
  // ----------------------------------------------------------------------

  wire external_reset_s;

  synch_3 reset_sync (
      external_reset,
      external_reset_s,
      clk_sys
  );

  wire reset_in = external_reset_s || ~pll_core_locked;

  // ----------------------------------------------------------------------
  //  The machine
  // ----------------------------------------------------------------------

  wire        ce_pix;
  wire [7:0]  vga_r, vga_g, vga_b;
  wire        vga_de, vga_hs, vga_vs, vga_hbl, vga_vbl;
  wire [15:0] audio_l, audio_r;
  wire        led_user;

  wire cart_fifo_overflow;

  // ---- Savestates, and therefore sleep ----------------------------------

  wire [31:0] savestate_rd_data;
  wire        ss_save;
  wire        ss_load;
  wire        ss_busy;
  wire        ss_loading;
  wire [31:0] ss_cart_crc32;
  wire        save_present;

  wire [63:0] bus_out_Din;
  wire [63:0] bus_out_Dout;
  wire [25:0] bus_out_Adr;
  wire        bus_out_rnw;
  wire        bus_out_ena;
  wire  [7:0] bus_out_be;
  wire        bus_out_done;

  ngpc_savestate_bridge savestate_bridge (
      .clk_sys(clk_sys),
      .clk_74a(clk_74a),
      .reset  (reset_in),

      .savestate_start     (savestate_start),
      .savestate_start_ack (savestate_start_ack),
      .savestate_start_busy(savestate_start_busy),
      .savestate_start_ok  (savestate_start_ok),
      .savestate_start_err (savestate_start_err),

      .savestate_load     (savestate_load),
      .savestate_load_ack (savestate_load_ack),
      .savestate_load_busy(savestate_load_busy),
      .savestate_load_ok  (savestate_load_ok),
      .savestate_load_err (savestate_load_err),

      .bridge_wr     (bridge_wr),
      .bridge_rd     (bridge_rd),
      .bridge_addr   (bridge_addr),
      .bridge_wr_data(bridge_wr_data),
      .bridge_rd_data(savestate_rd_data),

      .ss_save(ss_save),
      .ss_load(ss_load),
      .ss_busy(ss_busy),
      .ss_loading(ss_loading),
      .cart_crc32(ss_cart_crc32),

      .bus_out_Din (bus_out_Din),
      .bus_out_Dout(bus_out_Dout),
      .bus_out_Adr (bus_out_Adr),
      .bus_out_rnw (bus_out_rnw),
      .bus_out_ena (bus_out_ena),
      .bus_out_be  (bus_out_be),
      .bus_out_done(bus_out_done)
  );

  ngpc_machine machine (
      .clk_sys (clk_sys),
      .clk_ram (clk_ram),
      .reset_in(reset_in),

      .opt_system      (opt_system_s),
      .opt_language_jp (opt_language_jp_s),
      .opt_palette     (opt_palette_s),
      .opt_skip_anim   (opt_skip_anim_s),
      .opt_use_host_rtc(opt_use_host_rtc_s),
      .opt_auto_power  (opt_auto_power_s),
      .opt_lcd_response(opt_lcd_response_s),

      .bios_downloading(bios_downloading),
      .bios_sel        (bios_sel),
      .bios_wr         (bios_wr),
      .bios_addr       (bios_addr),
      .bios_data       (bios_ld_data),

      .cart_downloading  (cart_downloading),
      .cart_wr           (cart_wr),
      .cart_wr_addr      (cart_wr_addr[26:0]),
      .cart_wr_data      (cart_wr_data),
      .cart_fifo_overflow(cart_fifo_overflow),

      // PHASE 3: build this from APF host command 0x0090 in the MSM6242B
      // packet shape ngp_host_clock expects. Until then opt_use_host_rtc
      // defaults low and the BIOS seeds its own default date.
      .hps_rtc(65'd0),

      .joystick(joystick),

      .ce_pix (ce_pix),
      .vga_r  (vga_r),
      .vga_g  (vga_g),
      .vga_b  (vga_b),
      .vga_de (vga_de),
      .vga_hs (vga_hs),
      .vga_vs (vga_vs),
      .vga_hbl(vga_hbl),
      .vga_vbl(vga_vbl),

      .audio_l(audio_l),
      .audio_r(audio_r),

      .stage_req  (stage_req),
      .stage_we   (stage_we),
      .stage_addr (stage_addr),
      .stage_wdata(stage_wdata),
      .stage_ready(stage_ready),
      .stage_done (stage_done),
      .stage_rdata(stage_rdata),
      .host_busy  (host_busy),
      .slots_settled(slots_settled),
      .stage_diag_beats(stage_diag_beats),
      .stage_diag_drops(stage_diag_drops),
      .stage_diag_depth(stage_diag_depth),
      .stage_diag_first(stage_diag_first),
      .stage_diag_last (stage_diag_last),
      .stage_diag_reads(stage_diag_reads),

      .ss_save_i       (ss_save),
      .ss_load_i       (ss_load),
      .ss_busy_o       (ss_busy),
      .ss_loading_o(ss_loading),
      .cart_crc32_o(ss_cart_crc32),
      .save_present_o(save_present),

      .bus_out_Din (bus_out_Din),
      .bus_out_Dout(bus_out_Dout),
      .bus_out_Adr (bus_out_Adr),
      .bus_out_rnw (bus_out_rnw),
      .bus_out_ena (bus_out_ena),
      .bus_out_be  (bus_out_be),
      .bus_out_done(bus_out_done),

      .SDRAM_A   (dram_a),
      .SDRAM_BA  (dram_ba),
      .SDRAM_DQ  (dram_dq),
      .SDRAM_DQML(dram_dqm[0]),
      .SDRAM_DQMH(dram_dqm[1]),
      .SDRAM_CKE (dram_cke),
      .SDRAM_CLK (dram_clk),
      .SDRAM_nCAS(dram_cas_n),
      .SDRAM_nRAS(dram_ras_n),
      .SDRAM_nWE (dram_we_n),

      .led_user(led_user)
  );

  // ----------------------------------------------------------------------
  //  Video
  // ----------------------------------------------------------------------
  //
  // The core's raster goes out as-is: 515 dots x 199 lines at clk_sys/8, with
  // 160 x 152 active. video_rgb_clock is clk_sys itself, so nothing crosses a
  // clock domain here; `video_skip` suppresses the latch on the seven of every
  // eight cycles that do not carry a pixel, and on the dots inside the active
  // window that the panel spends on its /3 cadence. The Pocket therefore sees
  // exactly 160 pixels per line.

  assign video_rgb_clock    = clk_sys;
  assign video_rgb_clock_90 = clk_sys_90;

  reg        video_de_reg;
  reg        video_skip_reg;
  reg        video_hs_reg;
  reg        video_vs_reg;
  reg [23:0] video_rgb_reg;

  assign video_de   = video_de_reg;
  assign video_skip = video_skip_reg;
  assign video_hs   = video_hs_reg;
  assign video_vs   = video_vs_reg;
  assign video_rgb  = video_rgb_reg;

  reg hs_prev;
  reg vs_prev;
  reg [2:0] hs_delay;

  always @(posedge clk_sys) begin
    video_hs_reg   <= 0;
    video_de_reg   <= 0;
    video_skip_reg <= 0;
    video_rgb_reg  <= 24'h0;

    // DE is held across the active window and video_skip suppresses the
    // cycles that carry no new pixel. Confirmed correct on hardware
    // 2026-08-25; the runtime alternative it used to offer is gone.
    if (vga_de) begin
      video_de_reg   <= 1;
      video_skip_reg <= ~ce_pix;
      video_rgb_reg  <= {vga_r, vga_g, vga_b};
    end

    // Hold HSync off for a few cycles after the core raises it so it cannot
    // land on the same cycle as VSync.
    if (hs_delay > 0)  hs_delay     <= hs_delay - 1;
    if (hs_delay == 1) video_hs_reg <= 1;
    if (~hs_prev && vga_hs) hs_delay <= 7;

    video_vs_reg <= ~vs_prev && vga_vs;

    hs_prev <= vga_hs;
    vs_prev <= vga_vs;
  end

  // ----------------------------------------------------------------------
  //  Audio
  // ----------------------------------------------------------------------

  sound_i2s #(
      .CHANNEL_WIDTH(16),
      .SIGNED_INPUT (1)
  ) sound (
      .clk_74a  (clk_74a),
      .clk_audio(clk_sys),

      .audio_l(audio_l),
      .audio_r(audio_r),

      .audio_mclk(audio_mclk),
      .audio_lrck(audio_lrck),
      .audio_dac (audio_dac)
  );

  // ----------------------------------------------------------------------
  //  Clocks
  // ----------------------------------------------------------------------

  wire clk_sys;      // 49.152 MHz -- the machine, and the APF video clock
  wire clk_sys_90;   // 49.152 MHz, +90 deg
  wire clk_ram;      // 98.304 MHz -- the SDRAM command clock
  wire clk_dot;      //  6.144 MHz -- spare
  wire pll_core_locked;

  ngpc_pll mp1 (
      .refclk  (clk_74a),
      .rst     (0),
      .outclk_0(clk_sys),
      .outclk_1(clk_ram),
      .outclk_2(clk_sys_90),
      .outclk_3(clk_dot),
      .locked  (pll_core_locked)
  );

  // cart_fifo_overflow is latched but has no reader yet: APF gives a core no
  // way to raise a diagnostic the user can see, short of putting it in the
  // picture. It stays wired so the analysis in ngpc_cart_fifo is falsifiable
  // the moment there is somewhere to report it.
  wire unused_ok = &{1'b0, cart_fifo_overflow,
                     dataslot_requestread, dataslot_requestread_id,
                     clk_dot,
                     led_user, vga_hbl, vga_vbl, audio_adc, dbg_rx, user2,
                     cont1_joy, cont2_joy, cont3_joy, cont4_joy,
                     cont1_trig, cont2_trig, cont3_trig, cont4_trig,
                     cont2_key, cont3_key, cont4_key, vblank,
                     cram0_wait, cram1_wait, port_ir_rx,
                     dataslot_update_size, 1'b0};

endmodule
