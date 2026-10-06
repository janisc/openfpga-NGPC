// NGPC for Analogue Pocket -- cartridge flash persistence.
//
// HOW SAVING WORKS HERE, AND WHY IT LOOKS NOTHING LIKE MiSTer'S
//
// Saves on this machine are cartridge flash: a game writes progress into the
// cartridge, so persistence means remembering which physical erase blocks it
// changed and putting those bytes somewhere that survives a power cycle.
//
// MiSTer's core drives the SD card itself, so it needs a moment to decide when
// to write -- hence its manual and menu-triggered saves. The Pocket does not
// work that way. A data slot marked `nonvolatile` is loaded into the core by
// APF at start and read back out at exit or power-off. The core simply owns a
// region of memory; the host owns the file.
//
// Two earlier designs here failed for exactly the reasons that model removes.
// The first ported upstream's ngp_cart_overlay and did not fit: 21,599 ALMs
// against 18,480. The second wrote sectors itself through APF target commands,
// which meant a state machine that could stall (it did, holding the machine
// paused and freezing the console) and a file that had to be created before it
// could be written (it never was, so nothing reached the card). Neither failure
// is possible now, because neither mechanism exists.
//
// THE LAYOUT
//
//   staging[0]                 header: magic, cartridge CRC32 and size, the
//                              dirty-block bitmap, and the payload's CRC32
//   staging[512 ...]           the dirty blocks, run-length packed, in the
//                              fixed order both directions walk, so no
//                              directory is needed
//
// The header's cartridge CRC32 and byte count are what stop one game's save
// reaching another's flash: a staged image is applied only if both match the
// cartridge actually loaded.
//
// The payload's own CRC32 is what stops a DAMAGED file reaching it. The
// encoder folds each word in as it writes it and the decoder folds each word
// in as it reads it, so nothing walks staging twice to compute it. The dirty
// bitmap comes along for free: the decoder consumes payload words according
// to the bitmap, so a bitmap that has been corrupted consumes a different
// number of words and the checksum cannot match.
//
// The apply runs its decode TWICE -- once with the flash writes held off, and
// again for real only if the checksum agreed. That order is the whole point:
// the decoder writes flash as it walks, so a checksum finished after the
// decode could only ever confirm damage already done. A file that fails is
// refused whole: no flash written, no bitmap kept, and the save slot left
// unclaimed, so APF does not overwrite the file either and it survives on the
// card to be recovered.
//
// WHEN THE COPY HAPPENS
//
// APF reads our memory at exit without announcing it, so staging has to be
// current by then. It cannot wait for a trigger and it must not pause the
// machine -- a visible stutter every time a game saves would be worse than the
// problem it solves.
//
// So blocks are staged in the background, on flash quiescence. Games write
// flash in bursts; once the dies have been idle for QUIET_CLOCKS the pending
// blocks are copied one at a time. If the game writes a block while it is being
// staged, that block is simply marked pending again and re-copied later, so a
// torn copy corrects itself rather than persisting. No pause, no handshake with
// the machine at all.
//
// Restoring is the one place the machine is held: at cartridge-ready the staged
// blocks are applied while reset is still asserted, so the BIOS and the game
// only ever observe restored flash.

`default_nettype none

module ngpc_cart_save #(
	// Payload capacity of the staging region. A die's four top blocks come to
	// 64 KB, so this holds those plus three 64 KB blocks -- far beyond what NGP
	// saves use. It costs no FPGA resource, only slot transfer time at core
	// start and exit.
	parameter [24:0] STAGE_BYTES = 25'h0040000,
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

	// The cartridge's OWN identity, as a real NGPC reads it from the cart
	// header. Stamped into the save so an orphaned file -- one whose ROM was
	// renamed or moved, which is all it takes for APF to stop finding it --
	// says in plain text which game it belongs to.
	input  wire [95:0] cart_title_i,
	input  wire [15:0] cart_catalog_i,
	input  wire  [7:0] cart_subcat_i,
	input  wire  [1:0] size_code0_i,
	input  wire  [1:0] size_code1_i,

	// ---- Flash write reports ----------------------------------------------
	input  wire        event0_i,
	input  wire  [5:0] block0_i,
	input  wire        event1_i,
	input  wire  [5:0] block1_i,
	input  wire  [1:0] die_busy_i,

	// ---- Host activity -----------------------------------------------------
	// The staging region's host port is busy: APF moving the slot in or out,
	// or the copier's drain writes, with a ~10 ms tail (ngpc_stage_mem's
	// host_busy_o). Background staging stands aside for it and for
	// draining_i. It must NOT carry draining_i itself: the state commit in
	// S_FINISH waits on this alone, and draining falls only on the
	// state_done that same step raises (rc6, L2).
	input  wire        host_busy_i,
	// APF's read strobe on the staging port (data_unloader read_en, a clk_sys
	// register). host_busy_i follows a read one clock late, so the bank
	// flips also look at the strobe itself (rc6).
	input  wire        host_rd_i,

	// Savestate restore: the copier has drained the state's embedded image
	// into the SPARE bank; request an apply of it. The request is queued, so
	// a pulse that lands while another apply runs -- or in the very cycle
	// one starts -- is served by the next one instead of being lost.
	input  wire        state_apply_i,

	// The copier is draining a state's image into the spare bank. A boot
	// apply must not start under it: it would take the pending apply the
	// state needs and read the committed bank while the state's image is
	// still arriving in the other one.
	input  wire        draining_i,

	// The state being loaded was captured in a frozen session (the bridge
	// read layout 3 from its identity block). Valid from before the
	// state_apply_i pulse until state_done_o. See S11 in S_IDLE.
	input  wire        state_frozen_i,

	// The bridge reported a savestate load as failed, for any reason --
	// including failures the engine never saw (identity, incomplete blob,
	// copier timeout). At a wake that failure leaves the game cold-booted
	// without its save, so it freezes the session like a refused image does.
	input  wire        state_fail_i,

	// The session is frozen. The bridge stamps it into every capture, so a
	// frozen session that sleeps wakes up frozen instead of unfrozen.
	output wire        frozen_o,

	// APF is writing the save slot's staging region this cycle. Watching
	// the delivery directly is what makes the apply self-healing: if the
	// slot arrives after the settle window already fired the apply, the
	// burst re-arms it (issue #3 -- the 500 ms settle timer is a bet that
	// the cart-to-save delivery gap stays short; on slow cards it loses).
	input  wire        save_slot_wr_i,

	// The last apply refused to run: the staged bitmap omits blocks that
	// are dirty right now, and the original ROM bytes for those blocks
	// exist nowhere on the device. Loading such a state would silently
	// leave them un-rewound, so the load is rejected instead -- explicit
	// limits over haunted edge cases. It is raised for EVERY refused state
	// image now, not only for a bitmap that misses dirty blocks: a state whose
	// flash could not be restored must not have its machine state restored
	// over flash that was never rewound (review, and issue #3's wake path).
	output reg         apply_reject_o,

	// One pulse when an apply that was started for a state request has
	// finished, accepted or refused; apply_reject_o is valid with it. The
	// copier used to take busy falling as completion, and two chained
	// applies leave busy low for exactly one cycle in between.
	output reg         state_done_o,

	// APF has delivered every data slot: no loader region has seen a bridge
	// write for a long settle window. The apply MUST wait for this. Slots
	// stream in id order, so at cartridge-ready the save slot has not even
	// begun to arrive -- an apply fired at cart_ready reads power-up garbage,
	// fails the magic check, consumes its one chance, and the real save data
	// lands moments later with nobody listening. That race is why in-game
	// saves never restored in any earlier build.
	input  wire        slots_settled_i,

	// Ingestion diagnostics from ngpc_stage_mem, stamped verbatim into header
	// words 16-18 of every staged save so the flushed file carries them out.
	input  wire [15:0] diag_beats_i,
	input  wire [15:0] diag_drops_i,
	// How many of those beats were the copier draining a savestate's image
	// rather than APF delivering the file. Without it a file cannot say
	// which of the two arrived -- which is what left issue #3 ambiguous.
	input  wire [15:0] diag_drain_i,


	// ---- Machine control ---------------------------------------------------
	output reg         boot_hold_o,        // holds reset while a save is applied
	output reg         busy_o,
	// A save exists for this cartridge -- some block is dirty, either because
	// the game wrote flash this session or because a staged image was applied
	// at boot. This is what the core reports to APF's data-slot size table:
	// present -> the slot flushes 0xFE00 bytes at shutdown, absent -> zero
	// bytes and no file is created for games that never save.
	output wire        save_present_o,
	// The PSRAM set-up report (ngpc_stage_mem psram_report_o), stamped into
	// header words 32/33 of every staged save.
	input  wire [31:0] psram_report_i,
	output wire        stage_current_o,   // idle with nothing left to stage
	output reg         stage_bank_o,      // committed bank: what APF sees

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

	assign p2_be_o = 2'b11;

	localparam [15:0] MAGIC0 = 16'h4E47;  // "NG"
	localparam [15:0] MAGIC1 = 16'h5043;  // "PC"
	localparam [15:0] MAGIC2 = 16'h5341;  // "SA"
	// "V4": erased runs are packed. The tag skips V3 on purpose -- the PR #5
	// test build wrote files tagged V3 with a different header layout, and a
	// tag has to mean one layout. Those files fail the magic and are refused.
	localparam [15:0] MAGIC3    = 16'h5634;  // "V4" -- erased runs are packed
	localparam [15:0] MAGIC3_V2 = 16'h5632;  // "V2" -- raw blocks, still read

	// ---- Dirty and pending bitmaps -----------------------------------------
	//
	// `dirty` is what the save contains -- it only ever grows, and it is what
	// the header carries.

	reg [63:0] dirty0,   dirty1;

	// WHAT STILL NEEDS COPYING used to be a second pair of 64-bit bitmaps,
	// cleared a block at a time as the walk passed. Since a pass rebuilds the
	// WHOLE image -- which banking requires, because the spare bank holds an
	// older layout -- per-block bookkeeping answers a question nobody asks:
	// either the image is current or the entire pass has to run again. One
	// flag says that, and it says the other thing the per-block version was
	// there for as well. A write that lands mid-pass can dirty a block the
	// walk has already gone past, so the header would claim it while the
	// payload lacked it and every block after it would decode from the wrong
	// place -- a checksum cannot catch that, it would cover the broken image
	// faithfully. The flag being set again at the end of a pass IS that
	// condition, so the bank simply does not flip and the pass runs again.
	// This replaced 128 registers, two 6-to-64 decoders and a 128-input OR.
	wire flash_event = event0_i || event1_i;
	reg  stage_pending;

	// The staged image is complete and current: nothing owed and the walker
	// parked. The savestate capture waits on this with the machine paused, so
	// it converges instead of chasing.
	//
	// After an overflow nothing is staged again this session, so a pending
	// pass would never come: waiting for it would hold the machine paused
	// forever and hang sleep. The committed image is the last one that fit,
	// and that is what a capture gets.
	//
	// A pending apply is deliberately NOT waited for: the state LOAD waits on
	// this too, and on wake from sleep the boot apply is pending until the
	// slots settle. A drain that runs first goes to the spare bank and the
	// apply then takes the state's image, which is the right outcome.
	//
	// A frozen session (refused_q) stages nothing either, for the same reason.
	assign stage_current_o = (state == S_IDLE) && cart_ready_i &&
	                         (!stage_pending || pack_overflow || refused_q);

	// A SAVE MUST CONTAIN SOMETHING. A dirty bit alone is not a save: a game
	// that merely erases a block during startup -- Card Fighters does exactly
	// this when it finds no save -- dirties it with nothing in it. Claiming
	// the slot for that image makes APF write a 65 KB file of erased flash,
	// and if a real save file was already on the card, IT IS OVERWRITTEN AND
	// GONE. One missed apply then costs the player everything, permanently
	// (issue #3: a good save destroyed on the relaunch that failed to
	// restore it, then frozen because an already-erased block is never
	// erased again). So the claim also requires that the COMMITTED image --
	// the one APF would write -- holds a word that is not erased. An
	// all-0xFF image is indistinguishable from no save.
	//
	// The flag used to be sticky for the session: any non-erased word that
	// had passed through counted. Issue #3 lost a save a second time that
	// way -- after a failed restore the game wrote scratch data into a block
	// and erased it again, and the empty image that followed still claimed
	// the slot. Now each published pass and each accepted apply sets the
	// flag from its own image, and nothing else touches it.
	//
	// None of that is enough on its own, because the claim is not what
	// decides the flush: core_top can only ever RAISE the slot's size in
	// APF's table, and after a delivery APF holds the file's own size there
	// anyway. What APF writes back at exit is simply the committed bank. So
	// the real protection is refused_q below, which keeps that bank exactly
	// as delivered once a file has been refused.
	assign save_present_o = (|dirty0 || |dirty1) && image_has_data && !refused_q;
	assign frozen_o       = refused_q;

	// Nothing in this session has been restored yet and nothing written: the
	// shape of a wake, where a savestate is the only copy of the save the
	// session will get. A refusal or failure in this shape freezes.
	wire wake_shaped = !base_q && !(|dirty0 || |dirty1);

	// Program or erase? flash_die reports both with the same event, but not
	// with the same busy time: a program is a read-modify-write of ~350 ns
	// (~17 clk_sys), an erase is paced at 75 clk_sys per word, so even the
	// smallest block (8 KB) is busy >= 307,200 clocks. A 12-bit count of the
	// busy window, saturating at 4095 (~83 us), sits orders of magnitude from
	// both. The count restarts when busy rises and is cleared by the event,
	// so an event without a busy window of its own reads as a program -- the
	// safe side, which only refuses. This is a property of OUR flash model,
	// not of real chips: software emulators model no busy time at all, and no
	// game depends on it. If flash_die's ERASE_WORD_PERIOD or its program path
	// ever changes, revisit the threshold.
	reg  [11:0] busy_cnt0 = 12'd0, busy_cnt1 = 12'd0;
	reg   [1:0] busy_prev = 2'b00;
	reg         prog_since_publish = 1'b0;
	wire        prog_event = (event0_i && !(&busy_cnt0)) || (event1_i && !(&busy_cnt1));

	// A session with no save of its own and nothing that could become one:
	// no file delivered (this epoch or before a reload), no apply accepted,
	// the committed image holds no data, and nothing was PROGRAMMED since it
	// was published -- only erased -- and no pass was abandoned by an
	// overflow. A state that carries no image of this game may load over such
	// flash: there is no data there for the restored machine to depend on, and
	// no file to lose. A sleep or Memory taken before a save-less session's
	// first flash write embeds whatever the committed bank still held from an
	// earlier session; the loading session has usually run the BIOS power-up
	// erase by then, and without this the load was refused after boot_hold had
	// already reset the game (rc6, R1; 1.0.2 always loaded such a state).
	//
	// It asks about programs, not about stage_pending: an erase that the
	// flash-idle guard (S_IDLE) let finish reports while the drain blocks
	// every pass, so its block is always still pending when the state is
	// decided -- and an erased block is exactly what this allows (review).
	wire saveless_erased = !apf_delivered && !pre_delivered && !base_q &&
	                       !image_has_data && !prog_since_publish && !pack_overflow;


	// ---- Block geometry -----------------------------------------------------

	reg        geo_die;
	reg  [5:0] geo_block;
	wire [1:0] geo_size_code = geo_die ? size_code1_i : size_code0_i;
	wire        geo_valid;
	wire [20:0] geo_base;
	wire [15:0] geo_words;

	ngp_cart_overlay_geometry geometry
	(
		.size_code_i (geo_size_code),
		.block_i     (geo_block),
		.valid_o     (geo_valid),
		.base_o      (geo_base),
		.bytes_o     (),
		.words_o     (geo_words)
	);

	// A stage walks the live dirty bitmap; an apply walks the IMAGE's bitmap,
	// so the live one is only replaced once the apply is known to be good.
	// Committing the image's bitmap up front -- the old way -- left a refused
	// image's bitmap in dirty, and could not express a boot apply that keeps
	// blocks the unrestored session had already dirtied.
	wire block_dirty = geo_valid &&
		(geo_die ? (in_apply ? img1[geo_block] : dirty1[geo_block])
		         : (in_apply ? img0[geo_block] : dirty0[geo_block]));
	// Linear cartridge byte address, die1 starting at 2 MiB -- the mapping
	// ngp_cart_overlay_mover uses.
	wire [24:0] block_base_addr = {geo_die ? 4'd1 : 4'd0, geo_base};

	// Where this block sits in the staging payload: blocks are laid out in walk
	// order, so the offset is the running total of the dirty blocks before it.
	reg [24:0] stage_offset;

	// ---- State --------------------------------------------------------------

	localparam S_IDLE        = 5'd0;
	localparam S_STAGE_SCAN  = 5'd1;
	localparam S_STAGE_RD    = 5'd2;
	localparam S_STAGE_RD_W  = 5'd3;
	localparam S_STAGE_WR    = 5'd4;
	localparam S_STAGE_WR_W  = 5'd5;
	localparam S_STAGE_HDR   = 5'd6;
	localparam S_STAGE_HDR_W = 5'd7;
	localparam S_APPLY_HDR   = 5'd8;
	localparam S_APPLY_HDR_W = 5'd9;
	localparam S_APPLY_SCAN  = 5'd10;
	localparam S_APPLY_RD    = 5'd11;
	localparam S_APPLY_RD_W  = 5'd12;
	localparam S_APPLY_WR    = 5'd13;
	localparam S_APPLY_WR_W  = 5'd14;
	localparam S_FINISH      = 5'd15;
	localparam S_STAGE_RUN   = 5'd16;
	localparam S_STAGE_RUN_W = 5'd17;
	localparam S_STAGE_LEN   = 5'd18;
	localparam S_STAGE_LEN_W = 5'd19;
	localparam S_STAGE_NEXT  = 5'd20;
	localparam S_APPLY_CNT   = 5'd21;
	localparam S_APPLY_CNT_W = 5'd22;
	localparam S_CRC_SH      = 5'd23;


	reg [63:0] img0, img1;      // staged bitmap, held apart from dirty
	                            // until the reject check passes
	reg        apply_decide;    // first S_APPLY_SCAN cycle runs the check
	reg        saw_save_wr;     // save-slot writes since the apply began
	// Sticky for the whole cartridge session: APF delivered save data at
	// some point. The staging PSRAM is NOT cleared between core launches --
	// it is external memory and survives reconfiguration -- so a previous
	// session's image can still be sitting there with valid magic and a CRC
	// that matches, and it WILL be accepted and written into a cartridge
	// that has no save of its own. Measured on hardware the moment empty
	// captures stopped creating files: ingest 0 beats, verdict ACCEPTED,
	// 16 KB restored from nothing. No delivery means there is no file.
	//
	// Only APF's own delivery counts now; a state's image needs no such
	// proof -- the copier drained it moments ago.
	//
	// A cartridge reload (cart_replace) starts a new cartridge epoch. A file
	// delivered BEFORE it is still tried (pre_delivered): an order with the
	// save ahead of the cartridge, or a cartridge re-sent after it, used to
	// make the file that had already arrived look undelivered, and the game
	// then ran -- and saved -- over unrestored flash (review). But it is only
	// trusted as far as it matches: if a different game was loaded, the old
	// game's file fails the CRC, and that must read as "no file", not as a
	// refused file that freezes the new game's saving. Reset forgets both.
	reg        apf_delivered;
	reg        pre_delivered;

	// FAIL CLOSED. Set when a delivered file is refused, or when a state's
	// image is refused before the session has any save state of its own (a
	// wake). From then on nothing may change what APF writes back: no pass
	// publishes, no state commits a bank, no claim. APF then flushes the
	// committed bank as it was delivered -- the file on the card comes back
	// byte for byte. Without it, the game's next flash write built an image
	// from unrestored flash and APF wrote THAT over the file it could not
	// read: issue #3, reproduced on hardware by starting 1.0.2 on a file
	// from a newer build. MiSTer's metadata_fault is the same rule.
	reg        refused_q;
	// The session has a save state of its own: some apply was accepted. A
	// refused state image only freezes the session when this is clear and
	// nothing is dirty -- the shape of a wake, where the state was the only
	// copy the session was going to get.
	reg        base_q;
	// A state request not yet served (state_apply_i), and whether the apply
	// now running serves one (from_state, below).
	reg        state_req;
	// Why the running apply was refused, and at which header word.
	localparam [2:0] F_NONE   = 3'd0;
	localparam [2:0] F_NODELV = 3'd1;   // boot apply, nothing delivered
	localparam [2:0] F_NOIMG  = 3'd2;   // no image: magic mismatch
	localparam [2:0] F_HDR    = 3'd3;   // tag or cartridge CRC mismatch
	localparam [2:0] F_CRC    = 3'd4;   // payload checksum mismatch
	localparam [2:0] F_COVER  = 3'd5;   // state bitmap omits dirty blocks
	localparam [2:0] F_FROZEN = 3'd6;   // state captured while frozen: skipped
	reg  [2:0] fail_kind;
	reg  [5:0] fail_idx;
	// Staging is double-banked. A pass rebuilds the WHOLE image into the
	// spare bank and flips only when it is complete, so APF can never read
	// a half-built image and a pass cut short leaves the last good one
	// intact. Every dirty block is copied each pass, not just the newly
	// dirtied ones: the spare bank holds an older image whose payload
	// layout no longer matches the current bitmap.
	wire       build_bank = ~stage_bank_o;

	// The packed payload is a stream, not a set of fixed block slots, so a
	// single word pointer walks it for both the encoder and the decoder.
	localparam [15:0] PAYLOAD_WORDS = 16'd32256;   // 0xFE00 less the header
	reg [15:0] pack_ptr;
	reg [15:0] run_len;
	reg [15:0] fill_rem;
	reg        has_lit;
	reg        pack_overflow;
	// A V2 save is read as it always was and rewritten as V3 by the next
	// staging pass. Migration is one way and needs nothing from the player.
	// It costs one flag and one AND term, because V2's payload is the dirty
	// blocks concatenated -- the same sequential walk the packed stream
	// uses. Only the meaning of 0xFFFF differs: a marker, or just a word.
	// Giving the legacy path its own addressing instead cost an adder, a
	// 25-bit register and a wide mux, and did not fit on any seed.
	// If this path were ever wrong the old file survives it: since 1.0.2 a
	// refused apply is not overwritten.
	reg        legacy;
	// CRC32, one bit per clock. A word-wide CRC32 is a 48-input XOR tree
	// for each of 32 outputs, which this device has no room for; serial
	// costs 16 clocks a word and both walks have milliseconds to spare.
	// crc_ret is where the interrupted walk resumes: the call sites hand
	// their own next state over instead of taking it, so the shifter needs
	// no idea who called it.
	reg [31:0] crc_acc;
	reg [31:0] crc_want;     // what the file says its payload comes to
	reg [15:0] crc_sr;       // the word being shifted out
	reg  [3:0] crc_cnt;
	reg  [4:0] crc_ret;
	// The apply's first pass through the decode: read everything, write
	// nothing. from_state says the running apply serves a savestate restore.
	reg        verify_pass;
	reg        from_state;
	// The bank the apply reads. At boot and on a late delivery that is the
	// committed bank, where APF put the file. A savestate's image is drained
	// into the SPARE bank instead, and becomes committed only if the apply
	// accepts it -- a refused state then leaves the image APF will flush at
	// exit exactly as it was.
	reg        apply_bank;
	reg        in_apply;
	reg [19:0] save_wr_quiet;
	reg        image_has_data;   // the committed image holds a non-erased word
	reg        pass_has_data;    // the image this pass is building does
	reg  [4:0] state;

	// Apply diagnostics, stamped into header words 22-24 of every staged save:
	// how many applies ran since reset, the last apply's outcome, and how many
	// p2 writes COMPLETED during the last apply.
	//
	// Word 23 is {from_state, wr_drain, fail_idx[5:0], verdict[7:0]}, where
	// wr_drain (rc6) is diag_wr_drain below. Verdicts:
	// 0 none yet, 1 accepted, 2 state refused (bitmap omits dirty blocks),
	// 3 refused (payload checksum), 4 refused (tag or cartridge CRC, at
	// fail_idx), 5 nothing delivered, 6 no image (magic, at fail_idx). The
	// verdict is written when the outcome is known; the old one was written
	// only at the end of the header walk, so every early refusal read as
	// "none" -- the single most confusing word in issue #3's file.
	reg [15:0] diag_applies;
	reg [15:0] diag_verdict;
	reg [15:0] diag_p2wr;
	// Sticky: this engine issued a staging write while the copier was
	// draining. No RTL path does -- a pass can neither start nor run while
	// draining -- so a set bit points at hardware, not at the design. It is
	// stamped into word 23 bit 14, written after words 16-18 in every header
	// walk, so a stray header write like issue T7's (word 18 = a live drain
	// count) carries it out in the same header (rc6).
	reg        diag_wr_drain = 1'b0;

	// host_busy_i one clock late, for the state commit's wait (rc6, L2). All
	// its inputs are registered in ngpc_stage_mem; the flop keeps the S_FINISH
	// enable cone short.
	reg        slot_busy_q = 1'b0;

	reg [15:0] block_word;      // position within the block being copied
	reg [15:0] xfer_data;       // the word in flight
	reg  [5:0] hdr_idx;         // position within the header
	reg [19:0] quiet;
	reg        apply_pending;   // apply the staged image once the cart is ready
	reg        apply_ok;        // the header matched this cartridge

	wire flash_quiet = (die_busy_i == 2'b00) && !event0_i && !event1_i;

	// The header as a function of its index, so it needs no storage of its own.
	reg [15:0] hdr_word;

	always @* begin
		case (hdr_idx)
			5'd0:  hdr_word = MAGIC0;
			5'd1:  hdr_word = MAGIC1;
			5'd2:  hdr_word = MAGIC2;
			5'd3:  hdr_word = MAGIC3;
			5'd4:  hdr_word = cart_crc32_i[15:0];
			5'd5:  hdr_word = cart_crc32_i[31:16];
			5'd6:  hdr_word = {7'd0, cart_bytes_i[24:16]};
			5'd7:  hdr_word = cart_bytes_i[15:0];
			5'd8:  hdr_word = dirty0[15:0];
			5'd9:  hdr_word = dirty0[31:16];
			6'd10: hdr_word = dirty0[47:32];
			6'd11: hdr_word = dirty0[63:48];
			6'd12: hdr_word = dirty1[15:0];
			6'd13: hdr_word = dirty1[31:16];
			6'd14: hdr_word = dirty1[47:32];
			6'd15: hdr_word = dirty1[63:48];
			6'd16: hdr_word = diag_beats_i;
			6'd17: hdr_word = diag_drops_i;
			// 18: the drain's share of word 16. (It once held a skid
			// high-water mark that read zero through every test.)
			6'd18: hdr_word = diag_drain_i;
			// The packed payload's CRC32, final by the time the header is
			// written because the payload is written first.
			6'd19: hdr_word = ~crc_acc[15:0];
			6'd20: hdr_word = ~crc_acc[31:16];
			// High byte: the writer revision, so a file says which build
			// wrote it. 0x05 = 1.1.0-rc5, 0x06 = 1.1.0-rc6 and 1.1.0, 0x07 =
			// 1.1.1 (words 32/33 below); older writers left 0.
			6'd21: hdr_word = {8'h07, cart_subcat_i};
			6'd22: hdr_word = diag_applies;
			6'd23: hdr_word = {diag_verdict[15], diag_wr_drain, diag_verdict[13:0]};
			6'd24: hdr_word = diag_p2wr;
			// The cartridge's own header identity, 12 ASCII characters of title
			// plus the catalogue numbers, so the file is self-describing.
			6'd25: hdr_word = cart_title_i[15:0];
			6'd26: hdr_word = cart_title_i[31:16];
			6'd27: hdr_word = cart_title_i[47:32];
			6'd28: hdr_word = cart_title_i[63:48];
			6'd29: hdr_word = cart_title_i[79:64];
			6'd30: hdr_word = cart_title_i[95:80];
			6'd31: hdr_word = cart_catalog_i;
			// 1.1.1: how the PSRAM was found at core start, and whether the
			// set-up read back as written (ngpc_stage_mem psram_report_o).
			6'd32: hdr_word = psram_report_i[15:0];
			6'd33: hdr_word = psram_report_i[31:16];
			default: hdr_word = 16'd0;
		endcase
	end

	// Stage-bank power-up value. It is deliberately NOT reset: a menu Reset
	// or Reset to BIOS drives the same reset as a PLL relock, and putting the
	// committed bank back to 0 then pointed APF's exit flush at whatever the
	// other bank held -- an older image (review, savefix regression). A new
	// core launch reconfigures the FPGA and starts from here anyway.
	initial stage_bank_o = 1'b0;

	always @(posedge clk) begin
		p2_req_o     <= 1'b0;
		stage_req_o  <= 1'b0;
		state_done_o <= 1'b0;

		// Flash reports are taken at all times, including mid-copy: a block
		// written while it is being staged is marked pending again, so the torn
		// copy is replaced rather than kept.
		if (event0_i) dirty0[block0_i] <= 1'b1;
		if (event1_i) dirty1[block1_i] <= 1'b1;
		// Every clear below re-applies this, so an event landing in the same
		// cycle as a pass start is owed, not lost.
		if (flash_event) stage_pending <= 1'b1;

		if (flash_quiet && quiet != QUIET_CLOCKS) quiet <= quiet + 20'd1;
		else if (!flash_quiet)                    quiet <= 20'd0;

		slot_busy_q <= host_busy_i;

		busy_prev <= die_busy_i;
		if (event0_i)                          busy_cnt0 <= 12'd0;
		else if (die_busy_i[0] && !busy_prev[0]) busy_cnt0 <= 12'd1;
		else if (die_busy_i[0] && !(&busy_cnt0)) busy_cnt0 <= busy_cnt0 + 12'd1;
		if (event1_i)                          busy_cnt1 <= 12'd0;
		else if (die_busy_i[1] && !busy_prev[1]) busy_cnt1 <= 12'd1;
		else if (die_busy_i[1] && !(&busy_cnt1)) busy_cnt1 <= busy_cnt1 + 12'd1;

		// The session state below is reset-scoped, and that is only safe
		// because reset_in resets the cartridge loader too: after a menu Reset
		// ngp_cart_rom holds no image (image_bytes 0, no dies), so no flash
		// the old session wrote can be staged again. A change that keeps the
		// cartridge across a menu Reset must move dirty, image_has_data,
		// base_q, refused_q and the delivery flags to the cart_replace epoch.
		if (reset || cart_replace_i) begin
			diag_applies  <= 16'd0;
			diag_verdict  <= 16'd0;
			diag_p2wr     <= 16'd0;
			diag_wr_drain <= 1'b0;
			prog_since_publish <= 1'b0;
			state         <= S_IDLE;
			boot_hold_o   <= 1'b0;
			busy_o        <= 1'b0;
			dirty0        <= 64'd0;
			dirty1        <= 64'd0;
			stage_pending <= 1'b0;
			quiet         <= 20'd0;
			apply_pending <= 1'b1;
			apply_ok      <= 1'b0;
			image_has_data <= 1'b0;
			pack_overflow  <= 1'b0;
			verify_pass    <= 1'b0;
			from_state     <= 1'b0;
			state_req      <= 1'b0;
			refused_q      <= 1'b0;
			base_q         <= 1'b0;
			in_apply       <= 1'b0;
			apply_reject_o <= 1'b0;
			saw_save_wr   <= 1'b0;
			save_wr_quiet <= 20'd0;
			// A cartridge reload drops a state request or a state apply in
			// flight. Answer it as refused, or the copier waits for a
			// state_done that never comes and the new cartridge is held in
			// reset behind the drain (review, FSM-6). A reset clears the
			// copier and the bridge as well, so only cart_replace needs this.
			if (!reset && (state_req || state_apply_i || (in_apply && from_state))) begin
				state_done_o   <= 1'b1;
				apply_reject_o <= 1'b1;
			end
		end else begin
			if (state_apply_i) state_req <= 1'b1;

`ifdef NGPC_SAVE_DIAG
			if (stage_req_o && stage_we_o && draining_i) diag_wr_drain <= 1'b1;
`endif

			// S1(c): a savestate load that failed before this engine could
			// refuse anything (identity, incomplete blob, copier timeout)
			// still leaves a wake without its save. Same rule as a refusal.
			if (state_fail_i && wake_shaped) refused_q <= 1'b1;

			// Save-slot delivery seen after the apply started means the apply
			// ran too early (or mid-delivery): once the burst goes quiet,
			// re-arm and run it again on the now-complete image. A normal
			// boot never trips this -- delivery fully precedes the settled
			// apply, so saw_save_wr is clear by the time the apply starts.
			if (save_slot_wr_i) begin
				apf_delivered <= 1'b1;
				saw_save_wr   <= 1'b1;
				save_wr_quiet <= 20'd0;
			end else if (save_wr_quiet != QUIET_CLOCKS) begin
				save_wr_quiet <= save_wr_quiet + 20'd1;
			end
			if (saw_save_wr && (save_wr_quiet == QUIET_CLOCKS) &&
			    (state == S_IDLE) && !apply_pending) begin
				saw_save_wr   <= 1'b0;
				apply_pending <= 1'b1;
			end

			case (state)
				S_IDLE: begin
					// A state request in a running session (no boot apply pending:
					// a Memory, or a wake load that came after the boot apply)
					// takes the machine only once both dies are idle. boot_hold
					// resets the cartridge, and an erase or program cut by it
					// reports no completion: the block was left half-written,
					// neither dirty nor restored. Waiting lets it finish and report,
					// so the apply's coverage check sees the block -- restored if
					// the state carries it, refused if not (rc6). The dies go idle
					// between the game's commands, so the wait is one operation
					// long: a save the game makes of several operations can still
					// be cut between them, as a reset at that moment would cut it.
					// A wake load inside the boot hold is held already and never
					// waits.
					if (cart_ready_i && (apply_pending ||
					                     (state_req && die_busy_i == 2'b00))) begin
						// Hold the machine in reset from cartridge-ready until
						// the apply has run, and do not run the apply until APF
						// has finished delivering slots -- the save slot streams
						// AFTER the cartridge, so at this moment it is still in
						// flight. The hold covers the wait, so the BIOS and the
						// game still only ever observe restored flash.
						//
						// A boot apply also waits out a savestate drain: the
						// state's image is on its way into the spare bank and
						// its request will follow. One apply of the state then
						// serves both -- the state is what the machine is about
						// to become, so it is the flash that has to match.
						boot_hold_o <= 1'b1;
						busy_o      <= 1'b1;
						if (slots_settled_i && (state_req || !draining_i)) begin
							apply_pending <= 1'b0;
							// A request arriving in this very cycle is not the
							// one being served: keep it for the next apply.
							state_req     <= state_apply_i;
							from_state    <= state_req;
							apply_bank    <= state_req ? ~stage_bank_o : stage_bank_o;
							apply_reject_o <= 1'b0;
							saw_save_wr   <= 1'b0;
							hdr_idx <= 6'd0;
							apply_ok      <= 1'b1;
							fail_kind     <= F_NONE;
							fail_idx      <= 6'd0;
							in_apply      <= 1'b1;
`ifdef NGPC_SAVE_DIAG
							diag_applies  <= diag_applies + 16'd1;
							diag_verdict  <= 16'd0;
							diag_p2wr     <= 16'd0;
`endif
							// A state captured in a frozen session carries the
							// file this build refused, not a save. Apply nothing
							// and stay frozen, but let the machine restore: a
							// frozen session must still be able to sleep and
							// wake. Flash then holds what it held before that
							// sleep -- the refused file was never applied.
							if (state_req && state_frozen_i) begin
								apply_ok  <= 1'b0;
								fail_kind <= F_FROZEN;
								state     <= S_FINISH;
							end else begin
								state     <= S_APPLY_HDR;
							end
						end
					end else if (cart_ready_i && stage_pending && !pack_overflow &&
					             !refused_q && !saw_save_wr && !host_busy_i &&
					             !draining_i && quiet == QUIET_CLOCKS) begin
						// No pass while a late delivery waits for its re-armed
						// apply: host_busy falls ~10 ms after the last beat and
						// the re-arm fires ~20 ms after it, and a pass in that
						// gap published the running game's unrestored flash
						// over the file that had just arrived (review).
						boot_hold_o <= 1'b0;
						busy_o       <= 1'b1;
						geo_die      <= 1'b0;
						geo_block    <= 6'd0;
						pack_ptr     <= 16'd0;
						crc_acc      <= 32'hFFFFFFFF;
						pass_has_data <= 1'b0;
						stage_pending <= flash_event;
						state        <= S_STAGE_SCAN;
					end else begin
						boot_hold_o <= 1'b0;
						busy_o      <= 1'b0;
					end
				end

				// ---------------- stage: cartridge -> staging ----------------
				S_STAGE_SCAN: begin
					if (block_dirty) begin
						block_word   <= 16'd0;
						run_len      <= 16'd0;
						has_lit      <= 1'b0;
						state        <= S_STAGE_RD;
					end else begin
						if (geo_block == 6'd63) begin
							if (geo_die) begin
								hdr_idx <= 6'd0;
								state   <= S_STAGE_HDR;
							end else begin
								geo_die   <= 1'b1;
								geo_block <= 6'd0;
							end
						end else begin
							geo_block <= geo_block + 6'd1;
						end
					end
				end

				S_STAGE_RD: begin
					if (p2_ready_i) begin
						p2_req_o  <= 1'b1;
						p2_we_o   <= 1'b0;
						p2_addr_o <= block_base_addr + {8'd0, block_word, 1'b0};
						state     <= S_STAGE_RD_W;
					end
				end

				// The encoder. A literal passes through; a run of erased words
				// becomes the marker 0xFFFF followed by its length. Runs stop at
				// a block boundary so each block decodes on its own terms.
				S_STAGE_RD_W: begin
					if (p2_done_i) begin
						if (p2_rdata_i != 16'hFFFF) pass_has_data <= 1'b1;
						if (p2_rdata_i == 16'hFFFF) begin
							run_len <= run_len + 16'd1;
							if (block_word + 16'd1 >= geo_words) begin
								state <= S_STAGE_RUN;
							end else begin
								block_word <= block_word + 16'd1;
								state      <= S_STAGE_RD;
							end
						end else begin
							xfer_data <= p2_rdata_i;
							if (run_len != 16'd0) begin
								has_lit <= 1'b1;
								state   <= S_STAGE_RUN;
							end else begin
								state <= S_STAGE_WR;
							end
						end
					end
				end

				// An image that will not fit the slot is abandoned rather than
				// truncated: the bank does not flip, so the last complete image
				// stays committed, and staging stands down until the cartridge
				// changes. Compression is what makes this rare; banking is what
				// makes it safe.
				S_STAGE_RUN: begin
					if (pack_ptr >= PAYLOAD_WORDS - 16'd1) begin
						pack_overflow <= 1'b1;
						stage_pending <= flash_event;
						state         <= S_FINISH;
					end else if (stage_ready_i) begin
						stage_req_o   <= 1'b1;
						stage_we_o    <= 1'b1;
						stage_addr_o  <= {8'd0, build_bank, 16'd0} + 25'd512 +
						                 {8'd0, pack_ptr, 1'b0};
						stage_wdata_o <= 16'hFFFF;
						state         <= S_STAGE_RUN_W;
					end
				end

				S_STAGE_RUN_W: begin
					if (stage_done_i) begin
						pack_ptr <= pack_ptr + 16'd1;
						crc_sr   <= stage_wdata_o;
						crc_cnt  <= 4'd0;
						crc_ret  <= S_STAGE_LEN;
						state    <= S_CRC_SH;
					end
				end

				S_STAGE_LEN: begin
					if (stage_ready_i) begin
						stage_req_o   <= 1'b1;
						stage_we_o    <= 1'b1;
						stage_addr_o  <= {8'd0, build_bank, 16'd0} + 25'd512 +
						                 {8'd0, pack_ptr, 1'b0};
						stage_wdata_o <= run_len;
						state         <= S_STAGE_LEN_W;
					end
				end

				S_STAGE_LEN_W: begin
					if (stage_done_i) begin
						pack_ptr <= pack_ptr + 16'd1;
						run_len  <= 16'd0;
						has_lit  <= 1'b0;
						crc_sr   <= stage_wdata_o;
						crc_cnt  <= 4'd0;
						crc_ret  <= has_lit ? S_STAGE_WR : S_STAGE_NEXT;
						state    <= S_CRC_SH;
					end
				end

				S_STAGE_WR: begin
					if (pack_ptr >= PAYLOAD_WORDS - 16'd1) begin
						pack_overflow <= 1'b1;
						stage_pending <= flash_event;
						state         <= S_FINISH;
					end else if (stage_ready_i) begin
						stage_req_o   <= 1'b1;
						stage_we_o    <= 1'b1;
						stage_addr_o  <= {8'd0, build_bank, 16'd0} + 25'd512 +
						                 {8'd0, pack_ptr, 1'b0};
						stage_wdata_o <= xfer_data;
						state         <= S_STAGE_WR_W;
					end
				end

				S_STAGE_WR_W: begin
					if (stage_done_i) begin
						pack_ptr <= pack_ptr + 16'd1;
						crc_sr   <= stage_wdata_o;
						crc_cnt  <= 4'd0;
						if (block_word + 16'd1 >= geo_words) begin
							crc_ret <= S_STAGE_NEXT;
						end else begin
							block_word <= block_word + 16'd1;
							crc_ret    <= S_STAGE_RD;
						end
						state <= S_CRC_SH;
					end
				end

				// One block is encoded; on to the next.
				S_STAGE_NEXT: begin
					if (geo_block == 6'd63) begin
						if (geo_die) begin
							hdr_idx <= 6'd0;
							state   <= S_STAGE_HDR;
						end else begin
							geo_die   <= 1'b1;
							geo_block <= 6'd0;
							state     <= S_STAGE_SCAN;
						end
					end else begin
						geo_block <= geo_block + 6'd1;
						state     <= S_STAGE_SCAN;
					end
				end
				S_STAGE_HDR: begin
					if (stage_ready_i) begin
						stage_req_o   <= 1'b1;
						stage_we_o    <= 1'b1;
						stage_addr_o  <= {8'd0, build_bank, 16'd0} + {18'd0, hdr_idx, 1'b0};
						stage_wdata_o <= hdr_word;
						state         <= S_STAGE_HDR_W;
					end
				end

				S_STAGE_HDR_W: begin
					if (stage_done_i) begin
						if (hdr_idx == 6'd33) begin
							// The image is whole: publish it in one step -- unless
							// the game wrote flash while the pass was running, in
							// which case the older image in the other bank is the
							// one that still makes sense. Nor while APF is moving
							// the slot: it reads and writes the committed bank, and
							// a flip mid-transfer would put half of one image and
							// half of the other in the file. The pass is owed
							// again and runs once the transfer is over.
							//
							// Nor while a die is busy: an erase reports itself
							// only when it completes, so a block copied while it
							// was half erased raised no event yet -- and was
							// published torn (review; MiSTer's mover treats a
							// busy die the same way).
							//
							// Nor while a late delivery waits for its re-armed
							// apply: a pass that started before the delivery
							// would publish its unrestored image over the file
							// that had just arrived, and the apply would then read
							// the pass (review, FSM-2).
							if (!stage_pending && flash_quiet && !host_busy_i &&
							    !host_rd_i && !draining_i && !refused_q && !saw_save_wr) begin
								stage_bank_o   <= build_bank;
								image_has_data <= pass_has_data;
								prog_since_publish <= 1'b0;
							end else begin
								stage_pending <= 1'b1;
							end
							state <= S_FINISH;
						end
						else begin
							hdr_idx <= hdr_idx + 6'd1;
							state   <= S_STAGE_HDR;
						end
					end
				end

				// ---------------- apply: staging -> cartridge ----------------
				S_APPLY_HDR: begin
					if (stage_ready_i) begin
						stage_req_o  <= 1'b1;
						stage_we_o   <= 1'b0;
						stage_addr_o <= {8'd0, apply_bank, 16'd0} + {19'd0, hdr_idx[4:0], 1'b0};
						state        <= S_APPLY_HDR_W;
					end
				end

				S_APPLY_HDR_W: begin
					if (stage_done_i) begin
						// The first failing check is the one recorded. apply_ok is
						// registered, so the walk reads one more word before it
						// leaves; the `apply_ok &&` keeps that word from
						// overwriting the reason.
						case (hdr_idx)
							// Nothing delivered this session means no save file exists,
							// whatever the staging region happens to still contain.
							5'd0:  if (!from_state && !apf_delivered && !pre_delivered) begin
							           if (apply_ok) begin fail_kind <= F_NODELV; fail_idx <= 6'd0; end
							           apply_ok <= 1'b0;
							       end else if (stage_rdata_i != MAGIC0) begin
							           if (apply_ok) begin fail_kind <= F_NOIMG; fail_idx <= 6'd0; end
							           apply_ok <= 1'b0;
							       end
							5'd1:  if (stage_rdata_i != MAGIC1) begin
							           if (apply_ok) begin fail_kind <= F_NOIMG; fail_idx <= 6'd1; end
							           apply_ok <= 1'b0;
							       end
							5'd2:  if (stage_rdata_i != MAGIC2) begin
							           if (apply_ok) begin fail_kind <= F_NOIMG; fail_idx <= 6'd2; end
							           apply_ok <= 1'b0;
							       end
							5'd3:  begin
							           if ((stage_rdata_i != MAGIC3) &&
							               (stage_rdata_i != MAGIC3_V2)) begin
							               if (apply_ok) begin fail_kind <= F_HDR; fail_idx <= 6'd3; end
							               apply_ok <= 1'b0;
							           end
							           legacy <= (stage_rdata_i == MAGIC3_V2);
							       end
							// Another cartridge's CRC. For a delivered file that is a file
							// this game cannot use: refused. For a STATE it is a leftover:
							// the capture copies the committed bank, and a session with no
							// file and no pass still holds whatever game last used the
							// PSRAM. That state carries no save of this game -- no image.
							// For a state the CRC outranks the tag: another game's image in
							// a format this build does not read is still another game's
							// image, not this game's save (so the walk reads both CRC
							// words even after a tag refusal, below).
							5'd4:  if (stage_rdata_i != cart_crc32_i[15:0]) begin
							           if (apply_ok || (from_state && fail_kind == F_HDR)) begin
							               fail_kind <= from_state ? F_NOIMG : F_HDR; fail_idx <= 6'd4;
							           end
							           apply_ok <= 1'b0;
							       end
							5'd5:  if (stage_rdata_i != cart_crc32_i[31:16]) begin
							           if (apply_ok || (from_state && fail_kind == F_HDR)) begin
							               fail_kind <= from_state ? F_NOIMG : F_HDR; fail_idx <= 6'd5;
							           end
							           apply_ok <= 1'b0;
							       end
							5'd8:  img0[15:0]  <= stage_rdata_i;
							5'd9:  img0[31:16] <= stage_rdata_i;
							5'd10: img0[47:32] <= stage_rdata_i;
							5'd11: img0[63:48] <= stage_rdata_i;
							5'd12: img1[15:0]  <= stage_rdata_i;
							5'd13: img1[31:16] <= stage_rdata_i;
							5'd14: img1[47:32] <= stage_rdata_i;
							5'd15: img1[63:48] <= stage_rdata_i;
							6'd19: crc_want[15:0]  <= stage_rdata_i;
							6'd20: crc_want[31:16] <= stage_rdata_i;
							default: ;
						endcase

						if (hdr_idx == 6'd20) begin
							apply_decide <= 1'b1;
							geo_die      <= 1'b0;
							geo_block    <= 6'd0;
							pack_ptr     <= 16'd0;
							crc_acc      <= 32'hFFFFFFFF;
							// A V2 file carries no checksum and is applied as it
							// always was; a V3 file is decoded once with the writes
							// held off before any of it reaches flash.
							verify_pass  <= apply_ok && !legacy;
							state        <= apply_ok ? S_APPLY_SCAN : S_FINISH;
						end else begin
							hdr_idx <= hdr_idx + 6'd1;
							// A state keeps reading through the CRC words after a
							// failure, so the CRC can reclassify a tag refusal.
							state   <= (apply_ok || (from_state && hdr_idx < 6'd5))
							           ? S_APPLY_HDR : S_FINISH;
						end
					end
				end

				S_APPLY_SCAN: begin
					// First cycle after the header. A STATE's image must cover
					// every block that is dirty right now, because rewinding
					// flash to the state needs the state's copy of each: the
					// original ROM bytes of a dirtied block exist nowhere on the
					// device. A delivered file is the save itself, so a boot
					// apply never refuses on coverage -- blocks the unrestored
					// session already dirtied simply stay dirty (S_FINISH).
					if (apply_decide) begin
						apply_decide <= 1'b0;
						if (from_state && (|(dirty0 & ~img0) || |(dirty1 & ~img1))) begin
							apply_ok       <= 1'b0;
							fail_kind      <= F_COVER;
							fail_idx       <= 6'd0;
							verify_pass    <= 1'b0;
							state          <= S_FINISH;
						end else begin
							// A V2 file has no check pass: this is its write pass,
							// and the image it writes decides the flag afresh.
							if (!verify_pass) image_has_data <= 1'b0;
						end
					end else
					if (block_dirty) begin
						block_word <= 16'd0;
						fill_rem   <= 16'd0;
						state      <= S_APPLY_RD;
					end else if (geo_block == 6'd63) begin
						if (geo_die) state <= S_FINISH;
						else begin
							geo_die   <= 1'b1;
							geo_block <= 6'd0;
						end
					end else begin
						geo_block <= geo_block + 6'd1;
					end
				end

				// The decoder, streaming the packed payload in the same block
				// order the encoder wrote it.
				S_APPLY_RD: begin
					// The payload ends at the slot. A V2 file from before
					// packing could claim more blocks than the slot held --
					// the file was cut at 0xFE00 -- and reading on would pour
					// whatever the memory past it holds into flash. Stop: the
					// blocks the file never carried keep what flash has now.
					if (pack_ptr >= PAYLOAD_WORDS) begin
						state <= S_FINISH;
					end else if (stage_ready_i) begin
						stage_req_o  <= 1'b1;
						stage_we_o   <= 1'b0;
						stage_addr_o <= {8'd0, apply_bank, 16'd0} + 25'd512 +
						                {8'd0, pack_ptr, 1'b0};
						state        <= S_APPLY_RD_W;
					end
				end

				S_APPLY_RD_W: begin
					if (stage_done_i) begin
						pack_ptr <= pack_ptr + 16'd1;
						crc_sr   <= stage_rdata_i;
						crc_cnt  <= 4'd0;
						if (stage_rdata_i == 16'hFFFF && !legacy) begin
							crc_ret <= S_APPLY_CNT;
						end else begin
							// Only a non-erased word is data. On the V2 path every
							// word lands here, erased or not, and an all-erased old
							// file would otherwise claim the slot and be rewritten.
							if (!verify_pass && stage_rdata_i != 16'hFFFF) image_has_data <= 1'b1;
							xfer_data      <= stage_rdata_i;
							fill_rem       <= 16'd1;
							crc_ret        <= S_APPLY_WR;
						end
						state <= S_CRC_SH;
					end
				end

				S_APPLY_CNT: begin
					if (stage_ready_i) begin
						stage_req_o  <= 1'b1;
						stage_we_o   <= 1'b0;
						stage_addr_o <= {8'd0, apply_bank, 16'd0} + 25'd512 +
						                {8'd0, pack_ptr, 1'b0};
						state        <= S_APPLY_CNT_W;
					end
				end

				S_APPLY_CNT_W: begin
					if (stage_done_i) begin
						pack_ptr  <= pack_ptr + 16'd1;
						xfer_data <= 16'hFFFF;
						// A zero count would stall the walk; treat it as one word.
						fill_rem  <= (stage_rdata_i == 16'd0) ? 16'd1 : stage_rdata_i;
						crc_sr    <= stage_rdata_i;
						crc_cnt   <= 4'd0;
						crc_ret   <= S_APPLY_WR;
						state     <= S_CRC_SH;
					end
				end

				S_APPLY_WR: begin
					if (p2_ready_i) begin
						p2_req_o   <= !verify_pass;
						p2_we_o    <= !verify_pass;
						p2_addr_o  <= block_base_addr + {8'd0, block_word, 1'b0};
						p2_wdata_o <= xfer_data;
						state      <= S_APPLY_WR_W;
					end
				end

				S_APPLY_WR_W: begin
					if (p2_done_i || verify_pass) begin
`ifdef NGPC_SAVE_DIAG
						if (!verify_pass) diag_p2wr <= diag_p2wr + 16'd1;
`endif
						if (block_word + 16'd1 >= geo_words) begin
							if (geo_block == 6'd63) begin
								if (geo_die) state <= S_FINISH;
								else begin
									geo_die   <= 1'b1;
									geo_block <= 6'd0;
									state     <= S_APPLY_SCAN;
								end
							end else begin
								geo_block <= geo_block + 6'd1;
								state     <= S_APPLY_SCAN;
							end
						end else if (fill_rem > 16'd1) begin
							fill_rem   <= fill_rem - 16'd1;
							block_word <= block_word + 16'd1;
							state      <= S_APPLY_WR;
						end else begin
							block_word <= block_word + 16'd1;
							state      <= S_APPLY_RD;
						end
					end
				end
				// Sixteen clocks, then back to whoever called. The caller left
				// its own next state in crc_ret on the way in.
				S_CRC_SH: begin
					crc_sr  <= {1'b0, crc_sr[15:1]};
					crc_acc <= (crc_acc[0] ^ crc_sr[0])
					           ? ({1'b0, crc_acc[31:1]} ^ 32'hEDB88320)
					           :  {1'b0, crc_acc[31:1]};
					crc_cnt <= crc_cnt + 4'd1;
					if (crc_cnt == 4'd15) state <= crc_ret;
				end

				S_FINISH: begin
					if (verify_pass) begin
						// The decode has run end to end without touching flash.
						verify_pass <= 1'b0;
						if (~crc_acc == crc_want) begin
							// Accepted: the write pass that follows commits this
							// image, so the flag is decided by its words alone.
							image_has_data <= 1'b0;
							geo_die   <= 1'b0;
							geo_block <= 6'd0;
							pack_ptr  <= 16'd0;
							state     <= S_APPLY_SCAN;
						end else begin
							// Refuse the whole file: nothing reached flash. The
							// outcome is settled with the other refusals below.
							apply_ok  <= 1'b0;
							fail_kind <= F_CRC;
							fail_idx  <= 6'd0;
						end
					end else if (in_apply && from_state && apply_ok && !refused_q &&
					             (slot_busy_q || host_rd_i)) begin
						// An accepted state is committed by flipping stage_bank_o,
						// and APF reads the slot per 16-bit word from the live
						// committed bank: a flush straddling the flip would write a
						// file of two images, refused at the next launch. The pass
						// publish already waits for the host port; the commit now
						// does too, for at most its ~10 ms tail (rc6, L2). The wait
						// is on the host port alone -- draining falls only on the
						// state_done raised below, so waiting on it would never end.
						// host_busy reaches slot_busy_q two clocks after a read
						// starts, so the read strobe itself holds those two.
						// Refusals and boot applies commit nothing and never wait.
					end else begin
						if (in_apply) begin
							if (apply_ok) begin
								// Accepted: the image becomes the save and its
								// bitmap replaces dirty. A state's image is
								// committed where it was drained (it fit once, so
								// staging may run again) -- unless the session is
								// frozen, which no state apply may undo.
								//
								// A delivered file is different: the boot apply read
								// the COMMITTED bank, so that bank now holds a file
								// that was read and applied, and a freeze left by an
								// earlier apply that caught the same file half
								// delivered is lifted (review, FSM-4). Blocks an
								// unrestored session dirtied before a late delivery
								// are dropped: they were the game's writes over a
								// missing save, and the re-armed apply restarts the
								// machine on the real one (review, FSM-3).
								dirty0 <= img0;
								dirty1 <= img1;
								if (from_state) begin
									if (!refused_q) begin
										stage_bank_o  <= apply_bank;
										pack_overflow <= 1'b0;
									end
								end else begin
									refused_q <= 1'b0;
								end
								base_q <= 1'b1;
							end else if (fail_kind == F_FROZEN) begin
								// S11: a state captured while frozen. Nothing
								// applied, the load goes ahead, the freeze returns.
								refused_q <= 1'b1;
							end else if (from_state) begin
								// A refused state leaves flash, dirty and the
								// committed bank as they were, and the load fails
								// -- except a state that carried no image of this
								// game (no magic, or another cartridge's) while
								// nothing is dirty: it was taken before any save
								// existed, and flash already matches it. The same
								// holds while the session has no save, and nothing
								// was programmed since its empty image was
								// published; erased blocks may still be pending
								// (saveless_erased, rc6 R1): nothing there for the
								// machine to lose.
								if (!((fail_kind == F_NOIMG) &&
								      (!(|dirty0 || |dirty1) || saveless_erased)))
									apply_reject_o <= 1'b1;
								// At a wake the state was the only copy of the
								// save the session would get. Refusing it and
								// then letting the cold-booted game stage would
								// overwrite the file on the card; freeze instead.
								if (((fail_kind == F_HDR) || (fail_kind == F_CRC)) && wake_shaped)
									refused_q <= 1'b1;
							end else if (fail_kind != F_NODELV) begin
								// A delivered file this build cannot use -- a newer
								// or older format, another dump, a damaged payload.
								// It is still somebody's save: keep it exactly. That
								// includes a file from before a cartridge reload:
								// the rc4 exemption for a cartridge-CRC mismatch
								// there opened a path to overwriting a file from
								// another dump of the same game (review, F5).
								refused_q <= 1'b1;
							end
`ifdef NGPC_SAVE_DIAG
							diag_verdict <= {from_state, 1'b0, fail_idx,
							                 apply_ok                  ? 8'd1 :
							                 (fail_kind == F_COVER)    ? 8'd2 :
							                 (fail_kind == F_CRC)      ? 8'd3 :
							                 (fail_kind == F_HDR)      ? 8'd4 :
							                 (fail_kind == F_NODELV)   ? 8'd5 :
							                 (fail_kind == F_FROZEN)   ? 8'd7 :
							                                             8'd6};
`endif
							if (from_state) state_done_o <= 1'b1;
							in_apply   <= 1'b0;
							from_state <= 1'b0;
						end
						boot_hold_o <= 1'b0;
						busy_o      <= 1'b0;
						quiet       <= 20'd0;
						state       <= S_IDLE;
					end
				end

				default: state <= S_IDLE;
			endcase

			if (prog_event) prog_since_publish <= 1'b1;
		end

		// A cartridge reload moves this epoch's delivery into the previous
		// one; reset forgets both (see pre_delivered).
		if (reset) begin
			apf_delivered <= 1'b0;
			pre_delivered <= 1'b0;
		end else if (cart_replace_i) begin
			apf_delivered <= 1'b0;
			pre_delivered <= apf_delivered | pre_delivered;
		end
	end

	wire unused_ok = &{1'b0, STAGE_BYTES, 1'b0};

endmodule

`default_nettype wire
