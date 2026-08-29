# Known Behaviors

Findings from play-testing that are understood and intentionally left as-is.
Each entry states what you'll see, why it happens, and what to use instead.

## In-game suspend features don't offer resume (Neo Turf Masters)

**What you'll see:** Neo Turf Masters offers "press OPTION to suspend" before
each stroke. Choosing "suspend and turn off the power → Yes" writes its
suspend data and powers the machine down (blank/white screen — a powered-off
NGP shows a blank panel; this part is correct). On the next boot the game
never offers to resume.

**Why:** The suspend data itself is saved and restored correctly. Diagnostic
counters in the .sav prove the full round trip: the suspend writes exactly one
16 KB flash block (block 34), it is delivered on the next boot, validated, and
physically written back into cartridge flash before the game starts
(`applies=1, verdict=ACCEPTED, p2wr=8192` — one full block).

The game still starts fresh because its resume check depends on the console's
**always-on state**, not just flash. On real hardware, "power off" isn't off:
the NGP's work RAM stays battery-alive, and the game leaves a warm-state
marker there alongside the flash block. On the next "power on" it checks that
marker to distinguish a fresh suspend from stale flash leftovers. Any core
that cold-boots clears that RAM — the marker is gone, so the game ignores its
own perfectly-restored suspend block. **MiSTer behaves identically**, with its
much larger sparse-overlay save system — confirming the limitation is the
cold-boot model, not this core's save pipeline.

**Decision: document, don't fix.** A fix would mean seeding game-specific RAM
signatures at boot — a per-game hack layer for a feature the platform already
supersedes.

**Use instead:** **Sleep.** The Pocket's sleep *is* the NGP's always-on model,
done faithfully — close the lid mid-backswing, wake, continue. Savestates
cover the cart-swap case the in-game suspend was designed for. Normal
turn-off-and-continue saves in Neo Turf Masters are unaffected; only the
mid-round suspend prompt is inert.
