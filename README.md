# NGPC for Analogue Pocket

**This port was created by AI.** It is a port of [MiSTer-devel/NGPC_MiSTer](https://github.com/MiSTer-devel/NGPC_MiSTer) (Kitrinx / Jamie Blanks).

Running on hardware:

- Color and mono BIOS, auto-selected from the cartridge (System: Auto/Color/Mono)
- Cartridge flash saves — the real thing: NGP cartridges have no save RAM,
  the game rewrites its own flash, and this core persists exactly the blocks
  a game dirties into a Pocket nonvolatile save slot. It just works; there is
  no save menu.
- Save states that carry the cartridge: a state embeds the game's flash
  save data, so loading one restores machine AND cartridge together —
  including rewinding your in-game saves to that moment, which is the
  point. With them the Pocket's sleep/wake, a natural fit for a console
  that was itself designed to be always on. States are named after the
  game and refuse to load into a different cartridge.
- Display modes, including Analogue's own Neo Geo Pocket screen simulations
- Real-time clock fed from the Pocket's system clock: the BIOS calendar,
  alarm and horoscope run on the actual date and time
- Reset to BIOS — one menu action to visit the BIOS menu (clock, horoscope)
  without a cartridge trick; plain Reset returns to the game

The mono Neo Geo Pocket is the same machine with the color video path unused;
both BIOSes and both cartridge families run.

## BIOS

Not included, never will be. Place your own dumps at
`Assets/ngpc/janisc.NGPC/` on the SD card:

| file | contents |
|---|---|
| `boot0.rom` | NGPC color BIOS, 64 KiB |
| `boot1.rom` | NGP mono BIOS, 64 KiB |

## Known behaviors

See [docs/KNOWN_BEHAVIORS.md](docs/KNOWN_BEHAVIORS.md) — play-tested findings
that are understood and intentionally left as-is (e.g. why in-game suspend
features cannot offer resume on any cold-booting core, this one and MiSTer
alike, and why sleep is the honest replacement).

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
the flash blocks a game dirties and persists them in a sub-64 KB Pocket
nonvolatile slot, CRC-bound to the cartridge, applied before boot. What that
trades away, knowingly:

- **No MiSTer `.sav` interchange** — the formats share nothing; saves do not
  travel between the platforms in either direction.
- **No autosave toggle, no manual backup buttons** — saving is always on and
  invisible. Backup is copying the `.sav` off the SD card, which is also the
  honest version of what those buttons did.
- **A save set is capped at 63 KB of dirty blocks** — no licensed game comes
  anywhere near it (the hungriest known dirties ~32 KB).
- **Savestates carry the cartridge delta** — a state embeds the same .sav
  image the save slot holds, so machine and flash restore as one atomic
  pair, and loading a state rewinds your in-game saves with it. MiSTer
  stores 8 MB per state for the same idea; ours are 96 KB.

And a word of expectation management: the design fills 99% of the Pocket's
FPGA and does not formally close timing at this speed grade — every feature
above was won through fit battles and seed sweeps. Realistically **no new
features are planned**; the remaining work is polish, testing and release.
One is of course free to try — the fabric holds about 140 spare ALMs, and
they are spoken for by whoever gets there first. 😃

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
projects/          the Quartus 17.1 project
pkg/pocket/        core definition JSON for the Pocket
sim/               iverilog benches for the transport, save and RTC engines
scripts/           setup, seed sweep, packaging
docs/              known behaviors and notes
```

## Build

```
sh scripts/setup.sh                                  # clone + patch upstream
quartus_sh --flow compile projects/ngpc_pocket.qpf
python scripts/package.py --zip
```

The design targets a Cyclone V 5CEBA4F23C8 at 99% logic occupancy and does
not formally close timing at this speed grade; see the commit history on
`dev` for the measured reality and the disciplines that keep it honest.

## Credits

- **Kitrinx (Jamie Blanks)** — the NGPC core this stands on: the TLCS-900/H,
  the K2GE, the whole machine. GPL-2.0.
- **Adam Gastineau (agg23)** — PSRAM controller and data loader from the
  openFPGA template ecosystem. MIT.
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

BIOS images and game ROMs are copyrighted by their owners and are not part
of this repository or any release.
