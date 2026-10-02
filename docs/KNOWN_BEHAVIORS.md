# Known Behaviors

Things you may run into, why they happen, and what to do. All but the first
are understood and intentionally left as-is. The first is a rare fault whose
cause is still being looked for; when it happens, the core keeps your save
file as it is.

## A game starts without its save (the save is still on the card)

**What you'll see:** you launch a game that has a save, and the save isn't
there: no Continue, or the game starts as if it were new. There is no
message.

**What to do:** the save is almost certainly still on the card. Don't
overwrite or delete it.

1. **Quit the core.** Don't play on: nothing in that session is saved. If
   you'd like to help find the cause, make a Memory before you quit. It
   records the checksum the core worked out. Keep it only for the report;
   don't play from it later.
2. **Optional: back up the save and tell us.** Copy the save to your
   computer. It is on the SD card under `Saves/ngpc/`, in the same folders
   as the game under `Assets/ngpc/`, with the game's name and `.sav` at the
   end: for a game in `Assets/ngpc/common/`, that is
   `Saves/ngpc/common/<game>.sav`. If you can, open an issue on GitHub and
   attach the file, and the Memory if you made one (Memories are in
   `Memories/Save States/janisc.NGPC/`).
3. **Launch the game again.** If it was the fault described below, your
   save is back.

If the save still isn't there, the file is still kept. `tools/savinfo.py`
shows whether it is damaged or in a format this build does not read, and
which ROM (CRC32) it was made for. To start over instead, move the file off
the card first, and keep it.

**Why:** Before the core puts a save back into the cartridge, it checks that
the file belongs to exactly this ROM (every save carries the checksum of
the ROM it was made with) and, for a save 1.1.0 wrote, that the file is
intact (it carries a checksum of its own). If a check fails, the core
refuses the file. A refused file is never overwritten or deleted: the core
leaves it on the card byte for byte and **does not save anything for the
rest of that session**, so nothing you do in that session is kept. (Sleep
and wake still work in such a session, and a Memory made in it remembers
that saving is off.)

A file is refused on purpose when it is damaged, when it is in a format
this build does not know (for example from the PR #5 test build), or when
it was made with a different dump of the ROM. If you changed none of those,
the likely reason is a rare fault: at launch, the core sometimes works out
the wrong checksum for the game, although the game itself arrived intact,
and then does not recognize its own save. We saw this during testing with
Card Fighters' Clash, and the next launch brought the save back. We added
diagnostics and checks but could not pinpoint the cause. It showed up only
on some builds, most likely depending on how the design happens to be laid
out on the FPGA (the fitter's placement and timing), and the release build
never showed it in our testing. We can't be sure it is gone for good,
though. (1.0.x went on saving after it had refused a file, so there the
same fault could cost the save; 1.1.0 keeps the file.)

## Neo Turf Masters: the in-game suspend and the power button

**What you'll see:** Neo Turf Masters offers "press OPTION to suspend" before
each stroke. If you choose to suspend and turn off the power, the game
switches the console off and the screen goes white.

**What to do:** press **Select**. On this core it is the console's power
button, and the round carries on where you left it. We strongly suggest
using the Pocket's sleep or Memories (save states) instead, though.

**Why:** On the real console, the suspend keeps the round in memory while
the console is off, and the power button switches it back on. This core's
power button does that, but otherwise it doesn't work as it should (it only
switches the console back on, not off), it is confusing, and it offers
nothing that sleep and Memories don't. It is under consideration for
removal in a future version.

## A Memory that cannot rewind the save restarts the game

**What you'll see:** the Pocket reports that a Memory could not be loaded,
and the game starts over from the BIOS animation instead of carrying on
where it was. (A Memory of a different game is turned away before anything
is touched; the running game simply carries on.)

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

## A short sound stutter when a Memory loads

**What you'll see:** now and then, loading a Memory makes the sound stutter
briefly before the Memory is restored.

**Why:** If the game is writing to its save at that moment, the core waits
for the flash write in progress to finish before it stops the game and
restores the Memory. (A save the game makes of several writes can still be
cut between them, as the entry above describes.) The
wait is deliberate: cutting a flash write in half would leave the cartridge
in a state that nothing records, and a Memory load that did not wait for
the game's save to settle could hang.

**Use instead:** Nothing to do. The load completes normally.

## Menu Reset goes to the BIOS menu, not back to the game

**What you'll see:** choosing Reset in the Pocket's menu does not restart
the game. The BIOS menu appears instead (clock, horoscope), as it would
with no cartridge.

**Why:** The menu Reset resets the console and its cartridge loader. The
loader forgets the cartridge and the Pocket does not send it again, so the
console starts without it and the BIOS shows its menu. Your save is kept:
tested on hardware.

**Use instead:** To restart a game, relaunch it (quit the core and launch
the game again). To visit the BIOS menu on purpose, use Reset to BIOS.

## The clock is behind after a sleep or a Memory load

**What you'll see:** after waking from sleep, or loading a Memory, the
NGP's clock (the BIOS calendar, alarm and horoscope, and games that read
the time) carries on from the moment the sleep or the Memory was taken, so
it is behind by the time in between.

**Why:** A sleep or a Memory brings back the whole machine as it was,
clock included. The core sets the clock from the Pocket's when a game is
launched, and at Reset to BIOS.

**Use instead:** Relaunch the game, or use Reset to BIOS, to set the clock
right.

## Mono Palette has no effect with System = Mono

**What you'll see:** with System set to Mono, changing Mono Palette changes
nothing.

**Why:** The palettes belong to the color BIOS: it is the color BIOS that
colors mono games. System = Mono runs the original mono BIOS, which has no
palettes.

**Use instead:** System = Auto or Color. Both run the color BIOS, so the
palette applies to mono games.
