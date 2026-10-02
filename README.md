# NGPC for Analogue Pocket

**This port was created by AI.** It is a port of [MiSTer-devel/NGPC_MiSTer](https://github.com/MiSTer-devel/NGPC_MiSTer) (Kitrinx / Jamie Blanks).

Running on hardware:

- Color and mono BIOS (System: Auto/Color/Mono). On the Pocket, Auto runs
  the color BIOS, which plays mono games in its compatibility mode; choose
  Mono for the original NGP BIOS.
- Language (English/Japanese) and Mono Palette, applied from the first
  boot: the core waits for the Pocket to hand over the saved settings
  before the game starts. Games read them when they start, so a change
  made while a game runs takes effect the next time the game is launched,
  just as on MiSTer. Mono Palette sets the colors the color BIOS gives mono
  games; with System = Mono it has no effect, because the mono BIOS has no
  palettes.
- Cartridge flash saves — the real thing: NGP cartridges have no save RAM,
  the game rewrites its own flash, and this core persists exactly the blocks
  a game dirties into a Pocket nonvolatile save slot, packed so that even
  games with large flash blocks fit whole. It just works; there is no save
  menu. A save file the core refuses is never overwritten.
- Save states that carry the cartridge: a state embeds the game's flash
  save data, so loading one restores machine AND cartridge together —
  including rewinding your in-game saves to that moment, which is the
  point. With them the Pocket's sleep/wake, a natural fit for a console
  that was itself designed to be always on. States are named after the
  game and refuse to load into a different cartridge. A load restores
  both or neither: the game is never put back over a save that could not
  be restored. If a Memory cannot rewind the game's save, the load fails
  and the game starts over (see Known behaviors).
- Display modes, including Analogue's own Neo Geo Pocket screen simulations
- Real-time clock fed from the Pocket's system clock: the BIOS calendar,
  alarm and horoscope run on the actual date and time. After a sleep/wake
  or a Memory load the clock carries on from the moment the state was
  taken, so it is behind by the time in between; relaunching the game,
  or Reset to BIOS, sets it right.
- Reset to BIOS — one menu action to visit the BIOS menu (clock, horoscope)
  without a cartridge trick. The plain menu Reset also unloads the
  cartridge and lands in the BIOS menu (MiSTer's keeps the game); to
  restart a game, relaunch it. A menu Reset keeps your save.

The mono Neo Geo Pocket is the same machine with the color video path unused;
both BIOSes and both cartridge families run.

## BIOS

Not included, never will be. Place your own dumps at
`Assets/ngpc/janisc.NGPC/` on the SD card:

| file | contents |
|---|---|
| `boot0.rom` | NGPC color BIOS, 64 KiB |
| `boot1.rom` | NGP mono BIOS, 64 KiB |

## Saves

Saving is automatic: the core tracks the flash blocks a game rewrites and
persists exactly those. There is no save menu.

**A save belongs to a ROM file, not to a game.** The Pocket finds a save by
the ROM's path and filename, mirroring it under `Saves/ngpc/`. So:

- Two copies of the same ROM in different folders keep two separate saves.
  If a collection set gives you the same game in several category folders,
  progress does not follow you between them.
- Renaming or moving a ROM orphans its save. Nothing is lost -- rename the
  `.sav` to match and it works again.
- A save carries the cartridge's identity, so it is always possible to tell
  which game an orphaned file belongs to.
- A save is bound to the exact ROM dump (its CRC32). A save made with a
  different dump of the same game is refused and left untouched, and
  nothing is saved in that session (see below).

### How a save is stored

Saves are written in a packed format (V4): a run of erased flash is
stored as a count, so even games that write 64 KB flash blocks fit the
save slot whole. Every save carries a checksum over its contents, and the
core checks it before anything reaches the cartridge.

Saves from 1.0.x load as before and are rewritten in the new format the
next time the game saves. A 1.0.x file that was cut off at the slot size
(among the games we found: Unitron 2, Faselei!, Neo Turf Masters, Neo 21,
Bust-A-Move and the Ogre Battle Gaiden translation) can only give back what
it holds.

### If a game starts without its save

A save file the core refuses is never overwritten. The core refuses a
damaged file, a file in a format this build does not know, and a save that
belongs to a different dump of the ROM. The core keeps it on the card byte for
byte and **does not save for the rest of that session**. There is no
on-screen message: the game simply starts as if it had no save, and
nothing you do in that session is kept. Sleep and wake still work, and a
Memory taken in such a session remembers it: loading it restores the
game, leaves the cartridge alone, and saving stays off.

**If a game starts without a save it should have, the save is almost
certainly still on the card. Don't overwrite or delete it:**

1. **Quit the core.** Don't play on: nothing in that session is saved,
   and the file is left as it is. To help find the cause, make a Memory
   before you quit; keep it only for the report, and don't play from it
   later.
2. *Optional:* copy the save to your computer. It is under `Saves/ngpc/`,
   in the same folders as the game under `Assets/ngpc/` (for example
   `Saves/ngpc/common/<game>.sav`). If you can, open an issue and attach
   it, and the Memory if you made one.
3. **Launch the game again.** In the case we have seen, the save is back.

That case is a rare fault, found during testing: at launch, the core
sometimes worked out the wrong checksum for the game and then did not
recognise its own save. It showed up only on some builds, and the release
build never showed it in our testing, but the cause is not known yet; see
[docs/KNOWN_BEHAVIORS.md](docs/KNOWN_BEHAVIORS.md).

If the save still isn't there, run `tools/savinfo.py` on the file (below).
To start over instead, move the file off the card first, and keep it.

Saves from the PR #5 test build (tagged V3) use a different layout. This
core does not read them and leaves them untouched.

### Going back to 1.0.x

**Don't, without restoring a backup.** 1.0.x cannot read the new format.
Given a 1.1.0 save, it refuses it and can then write an empty save over
it; this was reproduced on hardware. Memories made with 1.1.0 carry the
new format too. If you need 1.0.x, put back the copy of `Saves/ngpc/` you
made before updating.

### Reading a save file

`tools/savinfo.py` decodes any save and reports what is actually in it -- the
cartridge, the ROM checksum, which flash blocks it carries, whether those
blocks hold real data or only erased flash, whether the file's own checksum
still matches, which build wrote it, whether the last restore came from the
file or from a savestate, which check refused a restore, and the core's own
diagnostic counters:

```
python3 tools/savinfo.py "Saves/ngpc/common/Your Game.sav"
```

**If you are reporting a save problem, please include this output.** It
answers in one line what otherwise takes a week of correspondence.

It reads sleep states and Memories too: the cartridge a state belongs to,
the save it carries, and, for a state made with 1.1.0, how the last Memory
load or wake before it in that session ended, and which check refused it
if one did:

```
python3 tools/savinfo.py "System/user_sleepstate.sta"
python3 tools/savinfo.py "Memories/Save States/janisc.NGPC/<the Memory's file>.sta"
```

If a save is still gone after a relaunch, copy these off the card before
you play again: the `.sav`, `System/user_sleepstate.sta` (if you have not
slept since), and any Memories of that game in
`Memories/Save States/janisc.NGPC/`. A state carries a copy of the save
from the moment it was taken, so the save may be recoverable from one;
`savinfo.py` shows what each of them holds.

## Known behaviors

See [docs/KNOWN_BEHAVIORS.md](docs/KNOWN_BEHAVIORS.md). It starts with what
to do if a game starts without its save (in short: the save is almost
certainly still there; quit the core and launch the game again). The rest
are findings that are understood and intentionally left as-is (e.g. why
in-game suspend features cannot offer resume on any cold-booting core, this
one and MiSTer alike, and why sleep is the honest replacement; or why a
Memory that cannot rewind the game's save restarts the game).

## What this port leaves out

- **Cheats** — upstream's cheat engine is compiled out (`NGPC_NO_CHEATS`).
- **Skip BIOS animation** — removed. The only honest way to skip the
  eye-catch is the BIOS resume path, and faking resume on a cold boot makes
  games restore a session that never existed (Faselei! draws over tilemaps
  it never filled). The jingle stays; it's three seconds of 1998.
- **Link cable** — upstream's serial port code is still in the tree but is
  compiled out (`NGPC_NO_LINK`); the port terminates in a stub. Two Pockets
  will not be trading Card Fighters cards.
- **Analog video out / Analogizer** — not wired. Dock output is whatever
  Analogue's scaler does with it; untested here, no dock on hand.
- **MiSTer's video processing options** — LCD Response simulation and
  Saturation are not wired; that ground is covered (better) by Analogue's
  display modes, including their Neo Geo Pocket screen simulations.
- **Stereo Mix** — the NGP's stereo comes through as-is, no blend option.
- **Savestate slots and hotkeys** — MiSTer's four slots and F-keys are
  replaced by the Pocket's own Memories UI, which manages any number of
  states. Nothing lost, different furniture.

**Saves are a ground-up rewrite, not a port of MiSTer's.** MiSTer keeps a
sparse overlay of the whole 8 MB cartridge space; this port tracks exactly
the flash blocks a game dirties and persists them, packed and checksummed,
in a sub-64 KB Pocket nonvolatile slot, CRC-bound to the cartridge,
verified and applied before boot. What that trades away, knowingly:

- **No MiSTer `.sav` interchange** — the formats share nothing; saves do not
  travel between the platforms in either direction.
- **No autosave toggle, no manual backup buttons** — saving is always on and
  invisible (except after a file the core refused; see Saves). Backup is
  copying the `.sav` off the SD card, which is also the honest version of
  what those buttons did.
- **A save slot holds 63 KB, packed.** Runs of erased flash are stored as a
  count, so what has to fit is the data, not the blocks it sits in.
  Biomotor Unitron 2 touches 72 KB of erase blocks with a *single* save
  slot, because its small save records sit in large blocks; 1.0.x stored
  such saves truncated. Packed, those 72 KB take under 4 KB, and the
  densest save measured so far (Biomotor Unitron 1) fills about half the
  slot. A save that still would not fit is not written in part: the last
  complete one stays. The packed format is supergarbo's design
  ([#5](https://github.com/janisc/openfpga-NGPC/pull/5)).
- **Savestates carry the cartridge delta** — a state embeds the same .sav
  image the save slot holds, so machine and flash restore as one atomic
  pair, and loading a state rewinds your in-game saves with it. If the
  image cannot be restored, the load fails as a whole and the game starts
  over: the machine is never restored over flash that was not rewound.
  MiSTer stores 8 MB per state for the same idea; ours are 96 KB.

And a word of expectation management: the design fills 98% of
the Pocket's FPGA and does not formally close timing at this speed grade —
every feature above was won through fit battles and seed sweeps. 1.1.0
only fits because the slow, non-critical blocks are now built for area;
before that the fitter had run out of LABs while ALMs were still nominally
free. Realistically **no new features are planned**; the remaining work is
polish, testing and release. One is of course free to try — the fitter
reports about 374 ALMs unused, scattered across the device
(all 1,848 of its LABs are in use), and they are spoken for by
whoever gets there first. 😃

## Branches

- `main` *(at release)*: curated milestone history for reading
- `dev`: the authentic, uncensored development record — every probe,
  dead end, fit battle and lesson, in the order it really happened

## Layout

```
upstream/          the MiSTer core, cloned by scripts/setup.sh, patched from patches/
patches/           our changes to upstream, as one reviewable diff
platform/pocket/   Analogue's APF framework files
target/pocket/     this port: bridge, savestate transport, cart save engine, RTC
projects/          the Quartus project
pkg/pocket/        core definition JSON for the Pocket
sim/               iverilog benches: save engine, savestate transport and
                   load path, staging, settings gate, RTC (run_all.sh runs
                   them all)
scripts/           setup, seed sweep, packaging
tools/             savinfo.py (reads a save, sleep or Memory file) and its
                   tests; cartdiag.py (for cartridge-load diagnostic builds)
docs/              known behaviors and release notes
```

## Build

```
sh scripts/setup.sh                                  # clone + patch upstream
quartus_sh --flow compile projects/ngpc_pocket.qpf
python scripts/package.py --zip
```

Open `projects/ngpc_pocket.qpf` in Quartus and hit Compile, exactly as on
MiSTer. 1.1.0 is built and verified with **Quartus Prime Lite 25.1** (free,
no license; install with Cyclone V device support). Expect a batch of
benign warnings about ignored legacy assignments -- the modern fitter
absorbed those knobs. `package.py` then stages the SD-card layout from the
bitstream and the JSON.

The design targets a Cyclone V 5CEBA4F23C8 at ~98% logic occupancy
and does not formally close timing at this speed grade; see the commit
history on `dev` for the measured reality and the disciplines that keep it
honest. The 1.1.0 release bitstream is seed 7 (main clock −3.139 ns worst
case), picked from a 25-seed search.

## Credits

- **Kitrinx (Jamie Blanks)** — the NGPC core this stands on: the TLCS-900/H,
  the K2GE, the whole machine. GPL-2.0.
- **Adam Gastineau (agg23)** — PSRAM controller and data loader from the
  openFPGA template ecosystem. MIT.
- **supergarbo** — the packed save format and double-banked staging
  ([#5](https://github.com/janisc/openfpga-NGPC/pull/5)), reimplemented
  here with credit, and the two savestate transport fixes in 1.0.1.
- **Analogue** — the openFPGA platform.
- **janisc** — port direction, hardware testing, and the patience to enter
  probe birthdays into the BIOS's own horoscope so the save-state diff could
  name their address.
- **Claude (Anthropic)** — AI co-developer: the port, the savestate
  transport, the cart save engine, the debugging.

## License

Three layers, each carried where it applies:

- **GPL-2.0** for the core and this port — inherited from upstream, see
  [LICENSE](LICENSE). Kitrinx's copyright headers are preserved throughout.
- **MIT** for the agg23 modules (`psram.sv`, `data_loader.sv`) — their
  headers carry it.
- **Analogue's APF Software License Agreement** for `platform/pocket/` —
  every APF file carries Analogue's agreement in its header, referencing
  their [EULA](https://www.analogue.link/pocket-eula); this is how all
  published openFPGA cores ship these files.

The platform image derives from a public-domain photograph by Evan-Amos
([Wikimedia Commons](https://commons.wikimedia.org/wiki/File:Neo-Geo-Pocket-Color-Blue-Left.jpg)).
BIOS images and game ROMs are copyrighted by their owners and are not part
of this repository or any release.
