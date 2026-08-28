# NGPC for Analogue Pocket

A port of [MiSTer-devel/NGPC_MiSTer](https://github.com/MiSTer-devel/NGPC_MiSTer)
(Kitrinx / Jamie Blanks) to Analogue Pocket openFPGA.

**Status: feature-complete, pre-release polish.** Running on hardware:

- Color and mono BIOS, auto-selected from the cartridge (System: Auto/Color/Mono)
- Cartridge flash saves — the real thing: NGP cartridges have no save RAM,
  the game rewrites its own flash, and this core persists exactly the blocks
  a game dirties into a Pocket nonvolatile save slot. It just works; there is
  no save menu.
- Save states, and with them the Pocket's sleep/wake — a natural fit for a
  console that was itself designed to be always on. States are named after
  the game and refuse to load into a different cartridge.
- Display modes, including Analogue's own Neo Geo Pocket screen simulations
- Real-time clock fed from the Pocket's system clock, plus a birthday setting
  so the BIOS horoscope reads your actual chart *(in the current fit battle)*

The mono Neo Geo Pocket is the same machine with the color video path unused;
both BIOSes and both cartridge families run.

## BIOS

Not included, never will be. Place your own dumps at
`Assets/ngpc/Kitrinx.NGPC/` on the SD card:

| file | contents |
|---|---|
| `boot0.rom` | NGPC color BIOS, 64 KiB |
| `boot1.rom` | NGP mono BIOS, 64 KiB |

## Known behaviors

See [docs/KNOWN_BEHAVIORS.md](docs/KNOWN_BEHAVIORS.md) — play-tested findings
that are understood and intentionally left as-is (e.g. why in-game suspend
features cannot offer resume on any cold-booting core, this one and MiSTer
alike, and why sleep is the honest replacement).

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
