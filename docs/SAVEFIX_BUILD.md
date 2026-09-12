# Save-fix test build

This is an experimental build for trying the V3 save changes on hardware. It has compiled, fitted and assembled successfully. It has not been hardware-tested yet, and setup timing still fails.

## The binary

- Version: `1.0.0-savefix-v3`
- Quartus Prime Lite 17.1.0 Build 590, target `5CEBA4F23C8`
- Logic: 18,225 / 18,480 ALMs (99%)
- Memory: 301 / 308 RAM blocks (98%)
- Worst setup slack: **−3.438 ns**, CPU clock, slow 0°C corner
- Worst hold slack: +0.014 ns
- Compilation: 0 errors, 257 warnings
- `ngpc.rev`: 2,181,332 bytes
- SHA-256: `552a02eeec971ab9b27c677a4d49108b34723579c611fa0cf5893c2cb680dba8`

Upstream's checked-in report also has negative CPU setup slack (−3.731 ns), but it used a different compiler/build. That comparison does not establish that this binary is reliable.

## Build it

The RTL is based on upstream port commit `30e11093bb090692629c75cb4ca349ddf1457ee8`. Use the MiSTer source revision in `patches/UPSTREAM_COMMIT`. On a fresh checkout:

```sh
git clone https://github.com/MiSTer-devel/NGPC_MiSTer.git upstream
git -C upstream checkout "$(cat patches/UPSTREAM_COMMIT)"
git -C upstream apply ../patches/ngpc-upstream-patches.diff
```

The existing `scripts/setup.sh` refers to a different patch filename; the commands above use the patch actually in this tree. Start with clean Quartus output/database directories. The local build used `NUM_PARALLEL_PROCESSORS=1` in the project settings because parallel workers stalled under Rosetta. That is a build-environment workaround, not a required RTL change.

```sh
cd projects
quartus_sh --flow compile ngpc_pocket
cd ..
python3 scripts/package.py --zip
```

The compiler ran in `theypsilon/quartus-lite-c5:17.1`, pinned to image digest `sha256:1fbeec2829bc5b156bd8c7d4fae993d5c7bf8238d21a184822fcb1dbf7132f58`. The new RBF was converted using the repository's byte-wise bit reversal; reversing the resulting REV again reproduced the RBF exactly. Placement may differ between environments, so a rebuild need not produce an identical binary.

## Install and try it

Back up your existing core directory, saves and save states first. Copy the test ZIP's `Cores/janisc.NGPC` directory onto the SD card, replacing that directory's files. Keep your existing BIOS and ROM files. The core menu should show `1.0.0-savefix-v3`.

**New V3 saves cannot be read by the old core.** Keep the backups if you plan to switch back. See [the test guide](SAVEFIX_TESTING.md) for save-format limits and useful test cases.

The code remains under the repository's GPL-2.0 license. The test release links to its source branch and includes the license; no game ROM, BIOS or game save is distributed.
