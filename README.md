# NGPC for Analogue Pocket

A port of [MiSTer-devel/NGPC_MiSTer](https://github.com/MiSTer-devel/NGPC_MiSTer)
(Kitrinx / Jamie Blanks) to openFPGA.

**Status: running on hardware. BIOS, cartridges and saves work; sleep does not yet.**

## Layout

```
upstream/          the MiSTer core, checked out and referenced in place
platform/pocket/   Analogue's APF files, unmodified
target/pocket/     this port
projects/          the Quartus project
pkg/pocket/        core definition JSON
scripts/package.py builds dist/ from the bitstream + JSON
fit/               a throwaway harness used to measure the console alone
```

`upstream/` is a real checkout so it can be re-pulled and the diff kept
visible. It carries exactly one change, guarded by `` `ifdef NGPC_POCKET ``
(see [Video](#video)); everything else is referenced as-is by
`projects/ngpc_upstream.qip`.

## Build

```
quartus_sh --flow compile projects/ngpc_pocket.qpf
python scripts/package.py --zip
```

Built with Quartus Prime Lite 17.1. The device is `5CEBA4F23C8` -- the Pocket's
core FPGA, 49k LE, 308 M10K blocks, **speed grade 8** where MiSTer's part is
grade 7. That last detail is not a footnote; see [Timing](#timing).

Put `boot0.rom` (colour BIOS) and `boot1.rom` (mono BIOS) in
`Assets/ngpc/Kitrinx.NGPC/` on the SD card. They are the same images the
MiSTer core uses.

## What had to change, and why

### Video

The one substantive difference between the two targets.

MiSTer's core carries `ngpc_crt_framebuffer`, which exists because MiSTer must
hand its framework a CRT-shaped raster: the K1GE/K2GE line period is 83.8 us,
nowhere near the 64 us an analog display wants. So the core buffers whole
frames into two RGB888 banks and re-emits them as a 262-line raster with an
identical frame period.

Those two banks are **192 of the Pocket's 308 M10K blocks**. With them the
design does not fit -- the first build failed with "the current design needs
more than 308".

APF has no such constraint: the scaler takes whatever raster the core produces.
So `target/pocket/ngpc_pocket_video.sv` replaces the frame store with a
passthrough presenter and the native 515 x 199 dot grid goes straight out.
Memory use drops from 2,489,600 bits to 1,303,168, and 173 of 308 blocks.

Two details make it simpler than it sounds:

- The panel takes one pixel per **three** dots (hdot 0, 3, ... 477 = 160
  pixels), so a naive DE would present 480 pixels per line. APF's `video_skip`
  suppresses the pixel latch on a given clock, so the presenter just marks the
  dots that carry a pixel and the Pocket latches exactly 160 x 152.
- Because `video_skip` removes the need to re-time anything, the APF video
  clock can be `clk_sys` itself. No clock domain is crossed and no line buffer
  is needed.

**Lost feature:** "LCD Response: Panel" blends against the previous frame,
which needs the frame store. `opt_lcd_response` is accepted and ignored.

### Timing

Upstream ships `NGPC.sdc` with carefully argued multicycle exceptions for the
TLCS-900H register-file write cone, which is deeper than one 20.345 ns clk_sys
period. The rule it states: a source that can only change on a `ce_t900_g`
tick, feeding storage that can only commit on such a tick, is a two-cycle path,
because `ce` is at most one clk_sys pulse in sixteen.

Its list covers "the exact path families seen in the fitted report" on grade-7
silicon. Grade 8 surfaces more members of the same family, so
`target/pocket/ngpc_pocket_timing.sdc` adds them -- each one checked against
the RTL individually, with the always-block cited in a comment.

Not every failing path qualifies. `dec_needs_byte1_hold` and
`dec_op2_kind_hold` load under `if (!ce)` -- **every** non-tick cycle -- unlike
the control snapshots next to them, which load under
`ctl_en = reset | ce_d | seq_pause_ready`. Upstream says "the decode/read holds
remain single-cycle" and it is right. Those paths are genuinely single-cycle
and are the current timing wall.

### Framework glue

`target/pocket/ngpc_machine.sv` is the Pocket's answer to `NGPC.sv`. It keeps
the machine-side logic -- reset sequencing, BIOS load, system strap, the power
button hold, BIOS setup seeding -- deliberately close to upstream's code and
comments, so an upstream change to those rules can be recognised and carried
across. What it drops is everything that only spoke to MiSTer: `hps_io`,
`CONF_STR`, the DDR3 clients, `video_mixer`/`video_freak`, and the HPS UART.

`target/pocket/core_top.v` is the framework face: PLL, bridge, data slots,
controls, video and audio pads.

## Phases

| | |
|---|---|
| 1 | BIOS boots, both console models. **Done, verified on hardware.** |
| 2 | Cartridges in SDRAM, 512 KB to 4 MB. **Done, verified on hardware.** Upstream's `sdram.sv` ported with a clock parameter; the Pocket has no SDRAM chip select, which is safe only because the controller's one nCS-high encoding also drives RAS/CAS/WE high. |
| 3 | Cartridge saves. **Built, untested.** Upstream's overlay does not fit -- see `ngpc_cart_save.sv`. Replaced by a dirty-block bitmap and a fixed-order sparse format. Not MiSTer `.sav` compatible, by decision. |
| 4 | Savestates and sleep. **Not started.** On the Pocket these are the same feature: sleep is host commands 0x00A0/0x00A4. The engine is already in the machine, tied off with `PHASE 4` markers; what is missing is a controller that streams ~41 KB over the bridge, and a decision about how cartridge flash survives the power-down. |

## Licensing

Upstream is GPLv2 and this port inherits that. Note for later: agg23's
`save_state_controller.sv` is a proven adapter for exactly this savestate bus,
but his repository is GPL-3.0-or-later, which does not combine with GPLv2 --
so Phase 4 needs its own implementation rather than a copy.

Analogue's APF files under `platform/pocket/` carry their own licence and are
redistributed unmodified.
