# Testing the experimental V3 cartridge-save patch

Run the public regression from the repository root:

```sh
python3 sim/run_savefix_v3.py
```

Requirements are Python 3 (standard library only), Icarus Verilog (`iverilog`
and `vvp`, tested with version 13), and the pinned upstream checkout described
in [SAVEFIX_BUILD.md](SAVEFIX_BUILD.md). No Quartus installation is needed for
these simulations. The runner can also be invoked by its absolute path from
another directory. A missing simulator or upstream checkout produces an error.

The suite generates all inputs beneath the ignored `dist/savefix-tests/`
directory. It requires no ROM, BIOS, downloaded game, or native save file.
The synthetic cartridge is a deterministic arithmetic pattern; four modified
physical blocks contain generated literal values and erased FFFF runs. The
cartridge identity supplied to the DUT is an arbitrary test constant. None
of these fixture bytes came from a commercial title.

Each test writes `compile.log`, `simulation.log` and `result.json` within its
output subdirectory. Successful completion prints `All V3 regressions passed`.
A compile failure, failed assertion, timeout or unexpected result returns a
nonzero process exit code. Allow several minutes for the complete suite.

## Coverage

- `sim/savefix_codec.py`: executes the actual save encoder/decoder, geometry
  module and state-cart copier against modeled memory. Four whole dirty blocks
  total 112 KiB, exceeding the former 63 KiB payload. It compares encoded bytes
  against a separate Python encoder and standard-library CRC32 calculation,
  then verifies every word of the restored 4 MiB synthetic cartridge. It also
  covers same-bitmap state rewind, erased blocks, both dies, concurrent flash
  events, incompressible overflow, rejected state preservation, malformed run
  lengths/bitmaps/identity/geometry, checksum corruption, interrupted input,
  bounded legacy V2 restore/upgrade, and oversized V2 rejection.
- `sim/savefix_banks.py`: executes staging-memory and PSRAM-controller RTL
  against a behavioral CellularRAM model. It checks active-bank mapping,
  host reads/writes, queued write-bank latching and simultaneous host/engine
  arbitration.
- `sim/savefix_fullstack.py`: couples the codec and state copier to the actual
  staging arbiter and PSRAM controller. Synthetic cold restore and state
  capture/erase/rewind must match, with zero dropped write-FIFO entries.
- `sim/savefix_bridge.py`: extends the upstream state-bridge regression with
  explicit save-overflow and load-validation error propagation. Rejected
  cartridge data must prevent machine-state restoration.

The codec test generates fixtures used by the full-stack test. Run the main
entry point for the supported order. For a focused rerun after fixtures exist,
individual `savefix_*.py` scripts can be invoked directly.

These tests use synthesized flash events and behavioral memory devices. They
do not execute the game CPU or flash-die command FSM, prove real APF pacing,
model the Pocket firmware's file replacement on SD, or establish FPGA timing
or physical hardware compatibility. Build results are documented separately
in [SAVEFIX_BUILD.md](SAVEFIX_BUILD.md).

## V3 behavior and compatibility

The host transfer and savestate cartridge section remain 65,024 bytes. Whole
physical dirty blocks are encoded in die/block order. A word other than FFFF
is literal; FFFF followed by a nonzero 16-bit count denotes that many erased
words within the same physical block. Header bounds, cartridge identity,
geometry and header/payload CRC32 are checked before any restore writes.

A new image is staged in an inactive 64 KiB PSRAM bank. Only a complete
candidate is committed. Encoding overflow preserves the previous valid
battery image and reports a savestate capture error; it cannot preserve the
newest flash state if that state is incompressible and too large. This does
not make the Pocket firmware's SD write atomic across power loss.

Bounded V2 raw images remain readable and are upgraded. **V3 files cannot be
read by the old core.** Back up the original core, battery saves and savestates
before testing or downgrading. Already truncated V2 files cannot recover lost
bytes; oversized V2 images are rejected before partial flash restoration.

A state whose bitmap omits a block already dirtied in the current session is
rejected. The original core does not retain pristine ROM bytes for those
blocks, so silently accepting that rewind would leave the wrong cartridge
contents. Same-bitmap rewind, including erasing/restoring a saved slot, is
covered. Arbitrary earlier-timeline rewind needs a separate pristine-ROM or
flash-history design.

## Relation to issue #3 and requested hardware feedback

[Issue #3](https://github.com/janisc/openfpga-NGPC/issues/3) reports that both
Card Fighters Clash versions appear to save, produce a `.sav` of the expected
size, but lose Continue after exiting to the Pocket menu and relaunching. It
also asks whether a RAM resume marker, as discussed for Neo Turf Masters,
could explain the behavior.

**That report has not been reproduced or proven to share this cause.** The
capacity defect was investigated using a separate Unitron 2 save image; that
evidence does not establish Card Fighters Clash's dirty-block use, restore
behavior, or RAM-marker requirements. An expected-size `.sav` by itself does
not demonstrate complete cartridge persistence. This patch addresses bounded
serialization/restoration of dirty flash blocks and does not add a title-
specific RAM resume marker.

Testing both Card Fighters Clash versions on real hardware is requested:

1. Preserve existing core, save and state files and record Pocket firmware and
   game version/region. Use a backed-up test copy of the game/save when needed.
2. Make an in-game save, wait for disk activity to finish, exit to the Pocket
   menu, relaunch and check Continue and the saved progress.
3. Repeat with a full power-off/relaunch, then a second save and overwrite.
4. Report any rejected state loads, crashes or regressions. Report whether a
   fresh save and a copied older save differ. Share hashes and observations;
   please do not attach copyrighted ROM or BIOS files.

A successful simulator or FPGA build is not a substitute for those results.
