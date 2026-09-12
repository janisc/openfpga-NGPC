// Bounded cartridge persistence, format V3. The transport remains 0xFE00 bytes.
// Complete dirty erase blocks are encoded in die/block order. A word other
// than FFFF is literal; FFFF followed by a nonzero 16-bit count emits erased
// words. Runs cannot cross a block boundary. Header words 16/17 give total
// image words / die geometry; 18/19 carry payload CRC32, 20/21 header CRC32.
// CRC32 is reflected IEEE, low byte first, initial FFFFFFFF (no final XOR).
//
// A candidate is written to the other 64 KiB PSRAM bank. Overflow, a flash
// event or host activity discards it. Publishing is a single bank swap.
// This preserves the previous complete image during background work.
// Restore performs a complete bounds/geometry/CRC validation pass BEFORE
// touching cartridge memory. Bounded V2 raw images remain readable.
// A state restore arrives in the inactive bank, and publishes only on success.
// Rewinding to a bitmap that omits currently dirty blocks is rejected: the
// original ROM bytes for those blocks are not retained by the existing core.
`default_nettype none
module ngpc_cart_save #(
	// Encoded payload capacity; header plus payload must stay below 64 KiB.
	parameter [24:0] STAGE_BYTES = 25'h000FC00,
	// Flash idle time before staging starts. ~20 ms at 49.152 MHz: long enough
	// that a burst of block writes is over, short enough that a save is staged
	// well before anyone reaches for the power switch. A parameter so the
	// simulation bench can shrink it.
	parameter [19:0] QUIET_CLOCKS = 20'd1_000_000
) (
	input  wire        clk,
	input  wire        reset,

	// ---- Cartridge identity ----------------------------------------------
	input  wire        cart_ready_i,
	input  wire        cart_replace_i,     // cart_download_start
	input  wire [31:0] cart_crc32_i,
	input  wire [24:0] cart_bytes_i,
	input  wire  [1:0] size_code0_i,
	input  wire  [1:0] size_code1_i,

	// ---- Flash write reports ----------------------------------------------
	input  wire        event0_i,
	input  wire  [5:0] block0_i,
	input  wire        event1_i,
	input  wire  [5:0] block1_i,
	input  wire  [1:0] die_busy_i,

	// ---- Host activity -----------------------------------------------------
	// While APF is moving the slot in or out it owns the staging region, and
	// background staging stands aside.
	input  wire        host_busy_i,

	// Savestate restore: the copier has written the inactive bank with the state's
	// embedded image; re-arm the boot apply for it. Same validation, same
	// hold, same bitmap restore as at power-on.
	input  wire        state_apply_i,

	// APF has delivered every data slot: no loader region has seen a bridge
	// write for a long settle window. The apply MUST wait for this. Slots
	// stream in id order, so at cartridge-ready the save slot has not even
	// begun to arrive -- an apply fired at cart_ready reads power-up garbage,
	// fails the magic check, consumes its one chance, and the real save data
	// lands moments later with nobody listening. That race is why in-game
	// saves never restored in any earlier build.
	input  wire        slots_settled_i,

	// Retained interface diagnostics; V3 uses these header words for bounds/CRC.
	input  wire [15:0] diag_beats_i,
	input  wire [15:0] diag_drops_i,


	// ---- Machine control ---------------------------------------------------
	output reg         boot_hold_o,        // holds reset while a save is applied
	output reg         busy_o,
	// A save exists for this cartridge -- some block is dirty, either because
	// the game wrote flash this session or because a staged image was applied
	// at boot. This is what the core reports to APF's data-slot size table:
	// present -> the slot flushes 0xFE00 bytes at shutdown, absent -> zero
	// bytes and no file is created for games that never save.
	output wire        save_present_o,
	output wire        stage_current_o,
	output reg         stage_bank_o,      // committed PSRAM bank; swap only after complete encoding
	output reg         save_error_o,      // capture cannot represent current flash
	output reg         apply_error_o,     // rejected last restore, before any flash writes

	// ---- Cartridge SDRAM, background port ----------------------------------
	output reg         p2_req_o,
	output reg         p2_we_o,
	output reg  [24:0] p2_addr_o,
	output reg  [15:0] p2_wdata_o,
	output wire  [1:0] p2_be_o,
	input  wire        p2_ready_i,
	input  wire        p2_done_i,
	input  wire [15:0] p2_rdata_i,

	// ---- Staging region, in PSRAM ------------------------------------------
	output reg         stage_req_o,
	output reg         stage_we_o,
	output reg  [24:0] stage_addr_o,
	output reg  [15:0] stage_wdata_o,
	input  wire        stage_ready_i,
	input  wire        stage_done_i,
	input  wire [15:0] stage_rdata_i
);

    localparam [15:0] MAGIC0=16'h4E47, MAGIC1=16'h5043,
                      MAGIC2=16'h5341, V2=16'h5632, V3=16'h5633;
    localparam [16:0] LIMIT_WORDS = (STAGE_BYTES + 25'd512) >> 1;
    localparam [5:0] IDLE=0, ENC_SCAN=1, ENC_READ=2, ENC_READ_WAIT=3,
        ENC_WORD=4, ENC_MARK=5, ENC_COUNT=6, ENC_LITERAL=7, ENC_NEXT=8,
        PUT=9, PUT_WAIT=10, ENC_HEADER=11, ENC_HEADER_WAIT=12, COMMIT=13,
        HDR_READ=14, HDR_WAIT=15, HDR_CHECK=16, DEC_SCAN=17,
        DEC_READ=18, DEC_READ_WAIT=19, DEC_COUNT=20, DEC_COUNT_WAIT=21,
        DEC_WRITE=22, DEC_WRITE_WAIT=23, DEC_NEXT=24, DEC_END=25,
        REJECT=26, FINISH=27;
    reg [5:0] state, after_put;
    reg [63:0] dirty0, dirty1, image0, image1;
    reg needs_build, candidate_changed, valid_image, apply_pending, state_restore;
    reg validate_only, legacy;
    reg [19:0] quiet;
    reg geo_die;
    reg [5:0] geo_block;
    wire [1:0] geo_code = geo_die ? size_code1_i : size_code0_i;
    wire geo_valid;
    wire [20:0] geo_base;
    wire [15:0] geo_words;
    ngp_cart_overlay_geometry geometry (
        .size_code_i(geo_code), .block_i(geo_block), .valid_o(geo_valid),
        .base_o(geo_base), .bytes_o(), .words_o(geo_words));
    wire selected = geo_die ? image1[geo_block] : image0[geo_block];
    wire [24:0] block_addr = {3'd0, geo_die, geo_base};
    reg [15:0] word_index, erased_count, value, run_left;
    reg [16:0] cursor, image_words;
    reg [4:0] hdr_index;
    reg [31:0] crc_acc, expected_crc;
    reg header_ok;
    wire flash_event = event0_i || event1_i;
    wire flash_quiet = !(|die_busy_i) && !flash_event;
    wire [24:0] read_bank = (stage_bank_o ^ state_restore) ? 25'h10000 : 25'd0;
    wire [24:0] write_bank = stage_bank_o ? 25'd0 : 25'h10000;
    assign p2_be_o = 2'b11;
    assign save_present_o = valid_image;
    assign stage_current_o = state==IDLE && !needs_build && !apply_pending &&
                             !save_error_o && cart_ready_i && flash_quiet;

    function [31:0] crc_word;
        input [31:0] crc;
        input [15:0] data;
        reg [31:0] c;
        integer bit_index;
        begin
            c=crc;
            for (bit_index=0;bit_index<16;bit_index=bit_index+1)
                c=(c>>1) ^ ((c[0]^data[bit_index]) ? 32'hEDB88320 : 32'd0);
            crc_word=c;
        end
    endfunction

    // Header and payload are processed sequentially. Share one CRC datapath
    // and accumulator; the expected payload CRC is retained across the header.
    wire [15:0] crc_data = stage_we_o ? stage_wdata_o : stage_rdata_i;
    wire [31:0] crc_next = crc_word(crc_acc, crc_data);
    reg [15:0] header_word;
    always @* begin
        case(hdr_index)
            0:header_word=MAGIC0; 1:header_word=MAGIC1;
            2:header_word=MAGIC2; 3:header_word=V3;
            4:header_word=cart_crc32_i[15:0]; 5:header_word=cart_crc32_i[31:16];
            6:header_word={7'd0,cart_bytes_i[24:16]}; 7:header_word=cart_bytes_i[15:0];
            8:header_word=image0[15:0]; 9:header_word=image0[31:16];
            10:header_word=image0[47:32]; 11:header_word=image0[63:48];
            12:header_word=image1[15:0]; 13:header_word=image1[31:16];
            14:header_word=image1[47:32]; 15:header_word=image1[63:48];
            16:header_word=cursor[15:0];
            17:header_word={12'd0,size_code1_i,size_code0_i};
            18:header_word=expected_crc[15:0]; 19:header_word=expected_crc[31:16];
            20:header_word=crc_acc[15:0]; 21:header_word=crc_acc[31:16];
            default:header_word=16'd0;
        endcase
    end

    always @(posedge clk) begin
        p2_req_o<=0; stage_req_o<=0;
        if (flash_quiet && quiet!=QUIET_CLOCKS) quiet<=quiet+1'b1;
        else if (!flash_quiet) quiet<=0;
        if (event0_i) dirty0[block0_i]<=1;
        if (event1_i) dirty1[block1_i]<=1;
        if (flash_event) begin
            needs_build<=1; candidate_changed<=1; save_error_o<=0;
        end
        if (state_apply_i) begin apply_pending<=1; state_restore<=1; end
        if (reset || cart_replace_i) begin
            state<=IDLE; busy_o<=0; boot_hold_o<=0; stage_bank_o<=0;
            save_error_o<=0; apply_error_o<=0;
            dirty0<=0; dirty1<=0; image0<=0; image1<=0;
            needs_build<=0; candidate_changed<=0; valid_image<=0;
            apply_pending<=1; state_restore<=0; quiet<=0;
            p2_we_o<=0; stage_we_o<=0;
        end else case(state)
            IDLE: begin
                busy_o<=0; boot_hold_o<=0;
                if(cart_ready_i && apply_pending) begin
                    busy_o<=1; boot_hold_o<=1;
                    if(slots_settled_i) begin
                        apply_pending<=0; apply_error_o<=0;
                        hdr_index<=0; header_ok<=1; legacy<=0;
                        image0<=0; image1<=0; image_words<=0;
                        crc_acc<=32'hFFFFFFFF;
                        state<=HDR_READ;
                    end
                end else if(cart_ready_i && needs_build && !save_error_o &&
                            !host_busy_i && flash_quiet && quiet==QUIET_CLOCKS) begin
                    busy_o<=1; image0<=dirty0; image1<=dirty1;
                    geo_die<=0; geo_block<=0; cursor<=17'd256;
                    crc_acc<=32'hFFFFFFFF; candidate_changed<=0;
                    state<=ENC_SCAN;
                end
            end
            ENC_SCAN: begin
                if(selected && !geo_valid) begin save_error_o<=1; state<=FINISH; end
                else if(selected) begin word_index<=0; erased_count<=0; state<=ENC_READ; end
                else state<=ENC_NEXT;
            end
            ENC_READ: if(p2_ready_i) begin
                p2_req_o<=1; p2_we_o<=0;
                p2_addr_o<=block_addr+{8'd0,word_index,1'b0}; state<=ENC_READ_WAIT;
            end
            ENC_READ_WAIT: if(p2_done_i) begin value<=p2_rdata_i; state<=ENC_WORD; end
            ENC_WORD: begin
                if(value==16'hFFFF) begin
                    erased_count<=erased_count+1'b1;
                    if(word_index+16'd1==geo_words) state<=ENC_MARK;
                    else begin word_index<=word_index+1'b1; state<=ENC_READ; end
                end else if(erased_count!=0) state<=ENC_MARK;
                else state<=ENC_LITERAL;
            end
            ENC_MARK: begin stage_wdata_o<=16'hFFFF; after_put<=ENC_COUNT; state<=PUT; end
            ENC_COUNT: begin stage_wdata_o<=erased_count;
                after_put<= value==16'hFFFF ? ENC_NEXT : ENC_LITERAL;
                erased_count<=0; state<=PUT;
            end
            ENC_LITERAL: begin stage_wdata_o<=value;
                after_put<=word_index+16'd1==geo_words ? ENC_NEXT : ENC_READ;
                word_index<=word_index+1'b1; state<=PUT;
            end
            PUT: begin
                if(cursor>=LIMIT_WORDS) begin
                    if(!candidate_changed && !flash_event) save_error_o<=1;
                    state<=FINISH;
                end
                else if(stage_ready_i) begin
                    stage_req_o<=1; stage_we_o<=1;
                    stage_addr_o<=write_bank+{7'd0,cursor,1'b0}; state<=PUT_WAIT;
                end
            end
            PUT_WAIT: if(stage_done_i) begin
                crc_acc<=crc_next;
                cursor<=cursor+1'b1; state<=after_put;
            end
            ENC_NEXT: begin
                if(geo_block==63) begin
                    if(geo_die) begin hdr_index<=0; expected_crc<=crc_acc; crc_acc<=32'hFFFFFFFF; state<=ENC_HEADER; end
                    else begin geo_die<=1; geo_block<=0; state<=ENC_SCAN; end
                end else begin geo_block<=geo_block+1'b1; state<=ENC_SCAN; end
            end
            ENC_HEADER: if(stage_ready_i) begin
                stage_req_o<=1; stage_we_o<=1;
                stage_addr_o<=write_bank+{19'd0,hdr_index,1'b0};
                stage_wdata_o<=header_word; state<=ENC_HEADER_WAIT;
            end
            ENC_HEADER_WAIT: if(stage_done_i) begin
                if(hdr_index<20) crc_acc<=crc_next;
                if(hdr_index==21) state<=COMMIT;
                else begin hdr_index<=hdr_index+1'b1; state<=ENC_HEADER; end
            end
            COMMIT: begin
                // Never publish a candidate containing a concurrent flash write.
                // Host reads retain the old bank throughout an interrupted pass.
                if(!candidate_changed && !flash_event && flash_quiet && !host_busy_i) begin
                    stage_bank_o<=~stage_bank_o; needs_build<=0;
                    valid_image<=|image0 || |image1; save_error_o<=0;
                end
                state<=FINISH;
            end
            HDR_READ: if(stage_ready_i) begin
                stage_req_o<=1; stage_we_o<=0;
                stage_addr_o<=read_bank+{19'd0,hdr_index,1'b0}; state<=HDR_WAIT;
            end
            HDR_WAIT: if(stage_done_i) begin
                if(hdr_index<20) crc_acc<=crc_next;
                case(hdr_index)
                    0:if(stage_rdata_i!=MAGIC0) header_ok<=0;
                    1:if(stage_rdata_i!=MAGIC1) header_ok<=0;
                    2:if(stage_rdata_i!=MAGIC2) header_ok<=0;
                    3:begin legacy<=stage_rdata_i==V2;
                        if(stage_rdata_i!=V2 && stage_rdata_i!=V3) header_ok<=0; end
                    4:if(stage_rdata_i!=cart_crc32_i[15:0]) header_ok<=0;
                    5:if(stage_rdata_i!=cart_crc32_i[31:16]) header_ok<=0;
                    6:if(stage_rdata_i!={7'd0,cart_bytes_i[24:16]}) header_ok<=0;
                    7:if(stage_rdata_i!=cart_bytes_i[15:0]) header_ok<=0;
                    8:image0[15:0]<=stage_rdata_i; 9:image0[31:16]<=stage_rdata_i;
                    10:image0[47:32]<=stage_rdata_i; 11:image0[63:48]<=stage_rdata_i;
                    12:image1[15:0]<=stage_rdata_i; 13:image1[31:16]<=stage_rdata_i;
                    14:image1[47:32]<=stage_rdata_i; 15:image1[63:48]<=stage_rdata_i;
                    16:image_words<={1'b0,stage_rdata_i};
                    17:if(stage_rdata_i!={12'd0,size_code1_i,size_code0_i}) header_ok<=0;
                    18:expected_crc[15:0]<=stage_rdata_i; 19:expected_crc[31:16]<=stage_rdata_i;
                    20:if(stage_rdata_i!=crc_acc[15:0]) header_ok<=0;
                    21:if(stage_rdata_i!=crc_acc[31:16]) header_ok<=0;
                    default: ;
                endcase
                if((legacy && hdr_index==15) || hdr_index==21) state<=HDR_CHECK;
                else begin hdr_index<=hdr_index+1'b1; state<=HDR_READ; end
            end
            HDR_CHECK: begin
                if(!header_ok || (!legacy && (image_words<256 || image_words>LIMIT_WORDS)) ||
                   (state_restore && (((dirty0 & ~image0)!=0) || ((dirty1 & ~image1)!=0)))) state<=REJECT;
                else begin
                    geo_die<=0; geo_block<=0; cursor<=256; validate_only<=1;
                    crc_acc<=32'hFFFFFFFF; state<=DEC_SCAN;
                end
            end
            DEC_SCAN: begin
                if(selected && !geo_valid) state<=REJECT;
                else if(selected) begin word_index<=0; state<=DEC_READ; end
                else state<=DEC_NEXT;
            end
            DEC_READ: begin
                if(cursor>=LIMIT_WORDS || (!legacy && cursor>=image_words)) state<=REJECT;
                else if(stage_ready_i) begin
                    stage_req_o<=1; stage_we_o<=0;
                    stage_addr_o<=read_bank+{7'd0,cursor,1'b0}; state<=DEC_READ_WAIT;
                end
            end
            DEC_READ_WAIT: if(stage_done_i) begin
                cursor<=cursor+1'b1; crc_acc<=crc_next;
                value<=stage_rdata_i; run_left<=1;
                state<=(!legacy && stage_rdata_i==16'hFFFF) ? DEC_COUNT : DEC_WRITE;
            end
            DEC_COUNT: begin
                if(cursor>=image_words) state<=REJECT;
                else if(stage_ready_i) begin
                    stage_req_o<=1; stage_we_o<=0;
                    stage_addr_o<=read_bank+{7'd0,cursor,1'b0}; state<=DEC_COUNT_WAIT;
                end
            end
            DEC_COUNT_WAIT: if(stage_done_i) begin
                cursor<=cursor+1'b1; crc_acc<=crc_next;
                if(stage_rdata_i==0 || {1'b0,stage_rdata_i}+{1'b0,word_index}>{1'b0,geo_words}) state<=REJECT;
                else begin run_left<=stage_rdata_i; state<=DEC_WRITE; end
            end
            DEC_WRITE: begin
                if(validate_only) begin
                    word_index<=word_index+run_left;
                    state<=word_index+run_left==geo_words ? DEC_NEXT : DEC_READ;
                end else if(p2_ready_i) begin
                    p2_req_o<=1; p2_we_o<=1; p2_addr_o<=block_addr+{8'd0,word_index,1'b0};
                    p2_wdata_o<=value; state<=DEC_WRITE_WAIT;
                end
            end
            DEC_WRITE_WAIT: if(p2_done_i) begin
                word_index<=word_index+1'b1; run_left<=run_left-1'b1;
                if(word_index+16'd1==geo_words) state<=DEC_NEXT;
                else state<=run_left==1 ? DEC_READ : DEC_WRITE;
            end
            DEC_NEXT: begin
                if(geo_block==63) begin
                    if(geo_die) state<=DEC_END;
                    else begin geo_die<=1; geo_block<=0; state<=DEC_SCAN; end
                end else begin geo_block<=geo_block+1'b1; state<=DEC_SCAN; end
            end
            DEC_END: begin
                if(validate_only) begin
                    if(!legacy && (cursor!=image_words || crc_acc!=expected_crc)) state<=REJECT;
                    else begin
                        validate_only<=0; geo_die<=0; geo_block<=0; cursor<=256;
                        crc_acc<=32'hFFFFFFFF; state<=DEC_SCAN;
                    end
                end else begin
                    dirty0<=image0; dirty1<=image1; needs_build<=legacy;
                    save_error_o<=0; valid_image<=|image0 || |image1;
                    if(state_restore) stage_bank_o<=~stage_bank_o;
                    state_restore<=0; state<=FINISH;
                end
            end
            REJECT: begin
                apply_error_o<=1;
                if(!state_restore) begin dirty0<=0; dirty1<=0; needs_build<=1; valid_image<=0; end
                state_restore<=0; state<=FINISH;
            end
            FINISH: begin busy_o<=0; boot_hold_o<=0; quiet<=0; state<=IDLE; end
            default: state<=IDLE;
        endcase
    end
    wire unused_diag = &{1'b0,diag_beats_i,diag_drops_i,1'b0};
endmodule
`default_nettype wire
