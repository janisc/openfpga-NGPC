# Test build: 1.1.0-rc3

A ready-to-install build of this branch, so the new save system can be tried
without building it. It is a release candidate, not a release.

| | |
|---|---|
| File | `janisc.NGPC_1.1.0-rc3.zip` |
| SHA-256 | `cb5e470cd12179bfa2ca1ab4642951ee754511b0775624a9fe689de3667284b4` |
| Built from | commit `361cb12` (Quartus Prime Lite 25.1, seed 48) |

## Install

1. **Back up `Saves/ngpc/` on your SD card first.**
2. Unzip onto the SD card root. It replaces the `janisc.NGPC` core.
3. The BIOS goes in `Assets/ngpc/janisc.NGPC/`, as before.

## What changes for your saves

- Saves are now written in a new format (V4). Runs of erased flash are packed,
  so large saves fit the save slot and are no longer cut off. Unitron 2,
  Faselei!, Neo Turf Masters and other games that write a 64 KB flash block
  lost part of every save in 1.0.x.
- **Existing 1.0.x saves load as before** and are rewritten as V4 the next
  time the game writes flash. If a 1.0.x file was cut off, only the part it
  actually contains can be restored.
- A damaged file is refused before anything reaches the cartridge, and it is
  left on the card.
- 1.0.x cannot read V4 files. If you go back to 1.0.2, it refuses them
  (it does not destroy them), and they work again after reinstalling this
  build. Restore your backup if you want to keep playing on 1.0.x.
- Saves from the PR #5 test build (tagged V3) have a different layout and
  are not read by this build.

To see what a save file contains, run `python3 tools/savinfo.py path/to/game.sav`.

## Feedback

Issues and pull request comments are both read. The output of
`tools/savinfo.py` for the file in question is the most useful thing to include.
