#!/usr/bin/env python3
"""Decode a janisc.NGPC save file and report what is actually in it.

No dependencies: python3 tools/savinfo.py "path/to/game.sav"

Paste the output into a bug report. It says which cartridge the save
belongs to, which flash blocks it carries, whether those blocks contain
real data or only erased flash, whether the file's own checksum still
matches, and -- on builds with the save diagnostics enabled -- what the
core's own counters recorded, including how the last apply of a save
into the cartridge ended and whether it came from a savestate load.

It also reads a sleep state (System/user_sleepstate.sta) or a Memory
(Memories/Save States/janisc.NGPC/*.sta): the cartridge it belongs to,
how the last savestate load of that session ended (from 1.1.0-rc6), and
the save image the state carries, decoded like a .sav.
"""
import sys
import textwrap
import zlib

HDR_BYTES = 0x200
PAYLOAD_WORDS = 32256        # 0xFE00 less the header

# Header word 23 on a diagnostics build. From 1.1.0-rc4 it is
# {from_state, reserved, fail_idx[5:0], verdict[7:0]}; from 1.1.0-rc6 the
# reserved bit is the staging check (see diagnostics). 1.0.2 and rc3 wrote
# the bare verdict (high byte 0) with codes 0-3, where 2 meant "rejected".
# The short labels go on the diagnostics line; codes 0-3 with a zero high
# byte print exactly as they always did. Code 7 is new in 1.1.0-rc5.
VERDICT_OLD = {0: 'none', 1: 'ACCEPTED', 2: 'REJECTED', 3: 'REFUSED (bad checksum)'}
VERDICT_NEW = {0: 'none', 1: 'ACCEPTED', 2: 'REJECTED (coverage)',
               3: 'REFUSED (bad checksum)', 4: 'REFUSED (header)',
               5: 'NOTHING DELIVERED', 6: 'NO IMAGE', 7: 'FROZEN STATE'}

# Header word 21 is {writer revision, catalogue sub-code}, on every build.
# From 1.1.0-rc5 the high byte names the revision of the core that wrote
# the file: 0x05 is rc5, 0x06 is rc6 and 1.1.0, 0x07 is 1.1.1 (which adds
# the PSRAM report in header words 32/33). Every older writer left it 0.
WRITER_RC5 = 0x05
WRITER_RC6 = 0x06
WRITER_111 = 0x07

# A savestate file (.sta): the Pocket's own header, then the core's blob as
# big-endian 32-bit words. The identity block and the load diagnostic sit
# between the engine's machine state and the embedded save image.
BLOB_OFF = 592
PAD_DIAG = 8419
PAD_PSRAM = 8418               # 1.1.1: the PSRAM set-up report (diag builds: their own word)
H_VERSION = 132                # the Pocket's header: the core's version string
ID_BASE = 8420
CART_BASE = 8424
CART_WORDS = 16256
ID_MAGIC = 0x4E475053          # "NGPS"


def geometry(size_code):
    """Erase-block sizes, mirroring ngp_cart_overlay_geometry.sv."""
    big, last = {1: 7, 2: 15, 3: 31}.get(size_code, 0), {}
    if not big:
        return {}
    for b in range(big):
        last[b] = 65536
    last[big] = 32768
    last[big + 1] = 8192
    last[big + 2] = 8192
    last[big + 3] = 16384
    return last


def size_code_for(cart_bytes):
    if cart_bytes == 0:
        return 0
    if cart_bytes <= 0x080000:
        return 1
    if cart_bytes <= 0x100000:
        return 2
    return 3


def unpack_v3(payload, sizes):
    """Undo the run-length packing: a literal passes through, 0xFFFF is a
    marker followed by the length of a run of erased words. Runs stop at a
    block boundary, so each block decodes on its own terms.

    How many words this consumes is decided by the block sizes, which come
    from the bitmap -- which is why the payload checksum covers the bitmap
    without the bitmap being in it."""
    out, p = [], 0
    for n in sizes:
        words, blk = n // 2, []
        while len(blk) < words:
            if p + 1 > len(payload):
                return out, p, False
            v = payload[p]
            p += 1
            if v != 0xFFFF:
                blk.append(v)
            else:
                if p >= len(payload):
                    return out, p, False
                run = payload[p]
                p += 1
                blk.extend([0xFFFF] * max(run, 1))
        out.append(b''.join(v.to_bytes(2, 'little') for v in blk[:words]))
    return out, p, True


def say(label, text):
    """One labelled line, continued under the value column if it is long."""
    lines = textwrap.wrap(text, 82, break_on_hyphens=False) or ['']
    print('%-16s: %s' % (label, lines[0]))
    for more in lines[1:]:
        print(' ' * 18 + more)


def header_field(idx):
    """What the header word the apply stopped at holds."""
    if idx <= 2:
        return 'magic'
    if idx == 3:
        return 'format tag'
    if idx <= 5:
        return 'ROM CRC32'
    if idx <= 7:
        return 'ROM size'
    if idx <= 15:
        return 'block bitmap'
    if idx in (19, 20):
        return 'payload checksum'
    return 'not a checked field'


def last_apply(code, legacy, from_state, applies):
    """The verdict in plain language. legacy: nothing in the file shows it
    came from 1.1.0-rc4 or later, so only what the old codes meant is said."""
    if code == 0:
        if applies == 0:
            return ('none yet -- nothing has been applied since the core started '
                    'or the cartridge was replaced')
        return ('no verdict recorded -- a core before 1.1.0-rc4 leaves this when '
                'the apply stops early in the header (nothing delivered, or the '
                'magic, format or ROM CRC did not match); nothing was written')
    if code == 1:
        if legacy:
            return ('ACCEPTED -- the save matched this cartridge; the flash writes '
                    'count shows how much of it was written')
        return 'ACCEPTED -- the save matched this cartridge and was written into its flash'
    if code == 2:
        if legacy:
            return 'REJECTED -- the core turned this save down and wrote nothing into flash'
        return ("REJECTED -- the savestate's save lacks a block this session had "
                'already written, so the load failed; flash was not touched')
    if code == 3:
        return ('REFUSED -- the payload checksum did not match (the image is damaged), '
                'so none of it reached flash')
    if code == 4:
        return ("REFUSED -- the header's format tag or ROM CRC does not match this "
                'core and cartridge; nothing was written')
    if code == 5:
        return ('NOTHING DELIVERED -- the Pocket delivered no save file this session, '
                'so there was nothing to restore')
    if code == 6:
        if from_state:
            return ('NO IMAGE -- the savestate was taken while no save was staged; '
                    'flash was not touched, and the load fails if this session holds '
                    'a save it could not rewind (from 1.1.0-rc6, flash the game only '
                    'erased does not count)')
        return ('NO IMAGE -- the delivered file is not a janisc.NGPC save (magic '
                'mismatch); nothing was written')
    if code == 7:
        return ('FROZEN STATE -- savestate from a frozen session: nothing applied, '
                'saving stays off; the savestate itself loaded, and flash was not touched')
    return 'verdict code %d is not known to this tool -- written by a newer core?' % code


def writer(rev):
    """The high byte of header word 21 in plain language."""
    if rev == 0:
        return 'older writer (rev 0) -- 1.1.0-rc4 or earlier'
    if rev == WRITER_RC5:
        return 'written by 1.1.0-rc5 (rev %d)' % rev
    if rev == WRITER_RC6:
        return 'written by 1.1.0-rc6 or 1.1.0 (rev %d)' % rev
    if rev == WRITER_111:
        return 'written by 1.1.1 or later (rev %d)' % rev
    if rev > WRITER_111:
        return 'written by 1.1.1 or later (rev %d, newer than this tool knows)' % rev
    return 'unknown writer revision %d -- no core writes it; the header may be damaged' % rev


def diagnostics(w, rev=0):
    """Header words 16-18 and 22-24, as the save diagnostics build stamps them."""
    beats, drops, drain = w(16), w(17), w(18)
    applies, word23, p2wr = w(22), w(23), w(24)
    code = word23 & 0xFF
    fail_idx = (word23 >> 8) & 0x3F
    reserved = (word23 >> 14) & 1
    from_state = word23 >> 15
    # 1.0.2 and rc3 leave word 18 at 0 and the high byte of word 23 at 0,
    # and never write codes past 3. Anything else is 1.1.0-rc4 or later.
    # From rc5 the writer revision in word 21 says so outright.
    rc4 = drain != 0 or (word23 >> 8) != 0 or code > 3 or rev >= WRITER_RC5
    label = VERDICT_NEW.get(code, '%d (word 23 = %04X)' % (code, word23)) if rc4 \
        else VERDICT_OLD.get(word23, word23)
    print('diagnostics     : ingest %d beats / %d drops | applies %d | verdict %s | flash writes %d' % (
        beats, drops, applies, label, p2wr))

    # Word 16 counts every write into staging: the Pocket's delivery and the
    # savestate copier's drains alike. Word 18 counts the drains alone.
    delivery = (beats - drain) & 0xFFFF
    if drain > beats:
        note = '  (16-bit counters wrapped)'
    elif not rc4:
        note = '  (cores before 1.1.0-rc4 count drains as delivery)'
    else:
        note = ''
    print('ingest split    : delivery %d beats | drain %d beats%s' % (delivery, drain, note))

    # Where the last apply came from is only recorded from 1.1.0-rc4 on.
    origin = '' if code == 0 else 'savestate load: ' if from_state \
        else 'boot or late delivery: ' if rc4 else ''
    text = origin + last_apply(code, not rc4, from_state, applies)
    if reserved and rev < WRITER_RC6:
        text += ' (word 23 has its reserved bit set -- a newer core?)'
    say('last apply', text)
    # Where the apply stopped. Index 0 is a real place for "no image" (the
    # magic) but means "not applicable" for the checks past the header.
    if rc4 and (code in (4, 6) or (code in (2, 3) and fail_idx)):
        say('failed check', 'header word %d (%s)' % (fail_idx, header_field(fail_idx)))
    # From rc6, bit 14 is set if the save engine ever wrote to staging while
    # a savestate was being loaded. No logic in the core does that.
    if rev >= WRITER_RC6:
        if reserved:
            say('staging check', 'FLAGGED -- the save engine wrote to its staging memory while '
                'a savestate was loading. No logic in the core does that, so this points at a '
                'hardware fault. Please keep this file and report it.')
        else:
            say('staging check', 'clean')


PAR = {0: 'full array', 1: 'bottom 1/2', 2: 'bottom 1/4', 3: 'bottom 1/8', 4: 'NONE of the array',
       5: 'top 1/2', 6: 'top 1/4', 7: 'top 1/8'}


def psram_report(v):
    """The 1.1.1 PSRAM set-up report (header words 32/33, or state word 8418):
    how the PSRAM was found when the core started -- a core that ran before
    this one may have changed it -- and whether the set-up read back."""
    if not v & 1:
        return
    bcr0, rcr0 = v >> 16, (v >> 8) & 0xFF
    async1, par1 = (v >> 7) & 1, (v >> 4) & 7
    ok1, ok0, done = (v >> 3) & 1, (v >> 2) & 1, (v >> 1) & 1
    left = []

    def die(mode_async, par, dpd_on, regs):
        parts = []
        if mode_async:
            parts.append('asynchronous')
        else:
            parts.append('SYNCHRONOUS burst mode')
            left.append('mode')
        parts.append('refresh %s' % PAR[par])
        if par != 0:
            left.append('refresh')
        if dpd_on:
            parts.append('DEEP POWER-DOWN on')
            left.append('power-down')
        return ', '.join(parts) + regs

    d0 = die(bcr0 >> 15 & 1, rcr0 & 7, not (rcr0 >> 4 & 1), ' (BCR %04X, RCR %02X)' % (bcr0, rcr0))
    d1 = die(async1, par1, False, '')
    say('PSRAM at start', 'die 0 %s; die 1 %s' % (d0, d1))
    if left:
        say('PSRAM note', 'not the power-on settings: a core that ran before this one left the '
            'PSRAM so (refresh off lets stored data decay). The set-up below put it back.')
    if not done:
        say('PSRAM set-up', 'NOT DONE when this was written')
    elif ok0 and ok1:
        say('PSRAM set-up', 'done; both dies read back as written (asynchronous, full refresh)')
    else:
        say('PSRAM set-up', 'done, but die %s did NOT read back as written' % (
            '0 and 1' if not ok0 and not ok1 else ('0' if not ok0 else '1')))


def main(path):
    d = open(path, 'rb').read()
    if len(d) != 65024 and is_savestate(d):
        return savestate(path, d)
    return decode_sav(d, path)


def blob_word(d, i):
    return int.from_bytes(d[BLOB_OFF + 4 * i:BLOB_OFF + 4 * i + 4], 'big')


def is_savestate(d):
    return (len(d) >= BLOB_OFF + 4 * (CART_BASE + CART_WORDS) and
            blob_word(d, ID_BASE) == ID_MAGIC)


# The identity-check terms of the load diagnostic, bit 4 first.
ID_TERMS = ('the transfer reached the end of the savestate',
            'the identity magic (a savestate of this core)',
            'the cartridge (ROM CRC)',
            'the layout',
            'the identity check word')


def load_diag(v):
    """Pad word 8419 (1.1.0-rc6 on): how the last load of the session ended."""
    if v == 0:
        say('last load', 'not recorded -- this state was written by a core before 1.1.0-rc6')
        return
    if v >> 24 != 0xD1:
        say('last load', 'unknown diagnostic word %08X -- written by a newer core?' % v)
        return
    loads = (v >> 20) & 0xF
    ran, ok = (v >> 19) & 1, (v >> 18) & 1
    chk = (v >> 13) & 0x1F
    frozen, drained, held = (v >> 12) & 1, (v >> 11) & 1, (v >> 10) & 1
    if loads == 0:
        say('last load', 'none -- no savestate load since the core started or was last '
            'reset from the menu')
        return
    say('loads before it', '%d%s savestate load(s) since the core started or was last '
        'reset from the menu' % (loads, ' or more' if loads == 15 else ''))
    failed = [ID_TERMS[4 - b] for b in range(4, -1, -1) if not chk >> b & 1]
    if failed:
        text = ('REFUSED at the identity check (failed: %s); the machine was not touched'
                % ', '.join(failed))
    elif not drained:
        text = ('FAILED -- the copier timed out waiting for the save engine; nothing was '
                'restored')
    elif not ran:
        text = ("REFUSED -- the save engine refused the state's save image; nothing was "
                'restored, and the game restarted because the check runs with the machine '
                'already stopped (a Memory also reports "Loading failed")')
    elif not ok:
        text = ('REFUSED -- the savestate engine refused the machine-state header, so the '
                'machine was not restored' + ('' if frozen else
                "; flash had already been restored from the state's save image, or left "
                'as it was if the state carried none'))
    elif frozen:
        text = ('RESTORED -- machine state only: the state was captured while saving was '
                'off, so flash was left as it was and saving stays off')
    else:
        text = ("RESTORED -- the machine state; flash restored from the state's save image, "
                'or left as it was if the state carried none. A cold start after this came '
                'from something later, such as a power-off')
    say('last load', text)
    say('load timing', 'arrived while the core was still starting up (the boot apply held '
        'the machine)' if held else 'arrived after startup, with the game already running')


def savestate(path, d):
    print('file            : %s' % path)
    print('size            : %d bytes -- a sleep state or Memory' % len(d))
    crc = blob_word(d, ID_BASE + 1)
    layout = blob_word(d, ID_BASE + 2)
    check = blob_word(d, ID_BASE + 3)
    print('ROM CRC32       : %08X   (the cartridge this state belongs to)%s' % (
        crc, '' if check == crc ^ 0xFFFFFFFF else '  <-- identity check word MISMATCH'))
    if layout == 2:
        print('layout          : 2 (normal)')
    elif layout == 3:
        say('layout', '3 -- captured while saving was off: the image below is the file the '
            'core refused, not a save')
    else:
        print('layout          : %d  <-- not a layout this core writes' % layout)
    load_diag(blob_word(d, PAD_DIAG))
    version = d[H_VERSION:H_VERSION + 32].split(b'\0')[0].decode('ascii', 'replace')
    if 'diag' not in version:
        psram_report(blob_word(d, PAD_PSRAM))
    img = b''.join(d[BLOB_OFF + 4 * (CART_BASE + i):BLOB_OFF + 4 * (CART_BASE + i) + 4][::-1]
                   for i in range(CART_WORDS))
    print()
    print('The file this state carries (loading the state applies nothing; saving stays off):'
          if layout == 3 else
          'The save image this state carries (loading the state restores it):')
    print()
    decode_sav(img, path + ' [embedded save image]')
    return 0


def decode_sav(d, path):
    def w(i):
        return int.from_bytes(d[2 * i:2 * i + 2], 'little')

    print('file            : %s' % path)
    print('size            : %d bytes%s' % (len(d), '' if len(d) == 65024 else '  <-- unexpected'))

    magic = bytes(d[0:8])
    swapped = bytes(b for i in range(0, 8, 2) for b in (d[i + 1], d[i]))
    if swapped[:6] != b'NGPCSA' or swapped[6:7] != b'V':
        print('magic           : %r  <-- NOT a janisc.NGPC save' % magic)
        return 1
    version = swapped[7:8].decode('latin1')
    if version == '3':
        # V3 was the tag of the PR #5 test build, whose header differs; this
        # core refuses those files rather than misread them.
        print('magic           : NGPCSAV3 -- written by the PR #5 test build, not this core;')
        print('                  this core refuses it and leaves it on the card')
        return 1
    if version not in '24':
        print('magic           : ok, but version %r is from a newer core' % version)
        return 1
    print('magic           : ok (NGPCSAV%s%s)' % (
        version, '' if version == '4' else '  -- pre-1.1 layout, uncompressed'))
    # Only a V4 file can carry a writer revision: rc5 writes nothing else,
    # and pre-1.0 development builds left other values in word 21's high
    # byte of their V2 files, which must not read as a newer writer.
    rev = (w(21) >> 8) if version == '4' else 0
    say('writer', writer(rev))
    if rev >= WRITER_111:
        psram_report((w(33) << 16) | w(32))

    title = bytes(b for i in range(25, 31) for b in (d[2 * i], d[2 * i + 1]))
    printable = ''.join(chr(c) if 32 <= c < 127 else '.' for c in title)
    # Saves written before 1.0.2 have uninitialised staging bytes here, so
    # only trust the field when it actually looks like cartridge text.
    legible = sum(1 for c in title if 32 <= c < 127 or c == 0)
    if legible == len(title) and any(32 <= c < 127 for c in title):
        print('cartridge       : "%s"   catalogue %04X-%02X' % (printable, w(31), w(21) & 0xFF))
    else:
        print('cartridge       : (not stamped -- written by a core older than 1.0.2)')

    crc = (w(5) << 16) | w(4)
    cart_bytes = (w(6) << 16) | w(7)
    code = size_code_for(cart_bytes)
    print('ROM CRC32       : %08X   (identifies the exact ROM this belongs to)' % crc)
    print('ROM size        : %d bytes (%d Mbit)' % (cart_bytes, cart_bytes * 8 // 1024 // 1024))

    geo = geometry(code)
    d0 = (w(11) << 48) | (w(10) << 32) | (w(9) << 16) | w(8)
    d1 = (w(15) << 48) | (w(14) << 32) | (w(13) << 16) | w(12)
    blocks = [(0, b) for b in range(64) if d0 >> b & 1] + \
             [(1, b) for b in range(64) if d1 >> b & 1]
    print('saved blocks    : %s' % (', '.join('die%d/%d' % x for x in blocks) or 'NONE'))

    sizes = [geo.get(b, 0) for _, b in blocks]
    truncated = False
    if version == '4':
        payload = [int.from_bytes(d[HDR_BYTES + 2 * i:HDR_BYTES + 2 * i + 2], 'little')
                   for i in range(PAYLOAD_WORDS)]
        chunks, used, complete = unpack_v3(payload, sizes)
        truncated = not complete
        stored = (w(20) << 16) | w(19)
        actual = zlib.crc32(d[HDR_BYTES:HDR_BYTES + 2 * used]) & 0xFFFFFFFF
        ok = (actual == stored)
        print('packed payload  : %d words (%d bytes) for %d bytes of flash -- %d%%' % (
            used, 2 * used, sum(sizes), 2 * used * 100 // max(sum(sizes), 1)))
        print('payload checksum: %08X %s' % (
            stored, 'ok' if ok else 'MISMATCH, computed %08X  <-- the file is damaged' % actual))
    else:
        ok = None
        off = HDR_BYTES
        chunks = []
        for n in sizes:
            chunks.append(d[off:off + n])
            off += n
        if off > len(d):
            # Before packing, a save bigger than the slot was cut at 0xFE00
            # while its header still listed every block. The core restores
            # what the file holds and leaves the rest of flash alone.
            truncated = True
            print('NOTE            : the header lists %d bytes of blocks but the file holds %d;'
                  % (sum(sizes), len(d) - HDR_BYTES))
            print('                  blocks past the end were never saved (cut at the slot size)')

    any_data = False
    for (die, b), n, chunk in zip(blocks, sizes, chunks):
        if len(chunk) < n:
            print('   die%d block %-2d %6d bytes : %s' % (die, b, n,
                  'MISSING (past the end of the file)' if not chunk else
                  'CUT SHORT (%d of %d bytes in the file)' % (len(chunk), n)))
            if chunk and not all(c == 0xFF for c in chunk):
                any_data = True
            continue
        erased = all(c == 0xFF for c in chunk)
        if not erased:
            any_data = True
        print('   die%d block %-2d %6d bytes : %s' % (
            die, b, n, 'ERASED (no data)' if erased else
            'has data (%d%% written)' % (100 - chunk.count(0xFF) * 100 // max(len(chunk), 1))))

    if any(w(i) for i in (16, 17, 18, 22, 23, 24)):
        diagnostics(w, rev)
    else:
        print('diagnostics     : none recorded (build without save diagnostics)')

    print()
    if ok is False:
        print('VERDICT: THIS FILE IS DAMAGED. Its own checksum does not match its')
        print('         contents, so the core will refuse it rather than write')
        print('         nonsense into the cartridge. Keep the file: an older copy')
        print('         or a backup is the only way back.')
    elif truncated and version == '2':
        print('VERDICT: PARTLY SAVED. An older core cut this save at the slot size;')
        print('         only the part in the file can be restored. %s' % (
              'Some of that part has data.' if any_data else 'That part holds no data.'))
    elif truncated:
        print('VERDICT: the packed payload ends early -- the file is truncated.')
    elif not blocks:
        print('VERDICT: this file claims no blocks at all.')
    elif not any_data:
        print('VERDICT: THIS SAVE CONTAINS NO DATA. Every block in it is erased')
        print('         flash, so restoring it gives the game nothing to find.')
    else:
        print('VERDICT: looks like a real save.')
    return 0


if __name__ == '__main__':
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
