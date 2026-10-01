# Known Behaviors

Findings from play-testing that are understood and intentionally left as-is.
Each entry states what you'll see, why it happens, and what to use instead.

## In-game suspend features don't offer resume (Neo Turf Masters)

**What you'll see:** Neo Turf Masters offers "press OPTION to suspend" before
each stroke. Choosing "suspend and turn off the power → Yes" keeps the round
and powers the machine down (blank/white screen — a powered-off NGP shows a
blank panel; this part is correct). On the next launch the game never offers
to resume.

**Why:** The suspend is not kept in the cartridge at all. It lives in the
console's **always-on work memory**: on real hardware "power off" is a standby
in which that memory stays powered, and on the next power-on the BIOS and the
game pick the round up from it. Every launch on the Pocket starts the console
from cold with that memory cleared, so there is nothing to resume. Measured:
a suspend followed by quitting leaves the save file exactly as it was, byte
for byte. (The empty 16 KB block 34 in Neo Turf Masters' save file is the
BIOS's own power-up routine, which erases the cartridge's top block at every
cold start; the saves of most games carry one.) **MiSTer behaves
identically** — it cold-boots too.

**Decision: document, don't fix — for now.** Keeping the console's work memory
between sessions, as some software emulators do, would make in-game suspend
work for every game without per-game hacks. That is a candidate for a later
version, not for a save-safety release.

**Use instead:** **Sleep.** The Pocket's sleep *is* the NGP's always-on model,
done faithfully — close the lid mid-backswing, wake, continue. Savestates
cover the cart-swap case the in-game suspend was designed for. Normal
turn-off-and-continue saves in Neo Turf Masters are unaffected; only the
mid-round suspend prompt is inert.

## A Memory that cannot be loaded restarts the game

**What you'll see:** the Pocket reports that a Memory could not be loaded,
and the game starts over from the BIOS animation instead of carrying on
where it was.

**Why:** A Memory carries the game's save as it was when the Memory was
made, and loading one rewinds the save to that point together with the game.
If the game has since written part of its save that the Memory does not
hold — typically a Memory made before the game had ever saved, loaded after
a save exists — that part cannot be rewound: its original contents exist
nowhere on the device. The core then refuses the whole load rather than put
the game back over a save it could not rewind. The check runs while the game
is already stopped for the restore, so the running game restarts. The core
itself writes nothing to the cartridge, and the save file stays as it was —
unless the game was in the middle of saving when the Memory was loaded: that
save is cut short, just as a reset at that moment would cut it.

**Use instead:** Continue from the game's own save, or load a more recent
Memory. Only unsaved progress from that session is lost.
