#!/usr/bin/env python3
"""Decode a janisc.NGPC save file and report what is actually in it.

No dependencies: python3 tools/savinfo.py "path/to/game.sav"

Paste the output into a bug report. It says which cartridge the save
belongs to, which flash blocks it carries, whether those blocks contain
real data or only erased flash, whether the file's own checksum still
matches, and -- on builds with the save diagnostics enabled -- what the
core's own counters recorded, including how the last apply of a save
into the cartridge ended and whether it came from a savestate load.
"""
import sys
import textwrap
import zlib

HDR_BYTES = 0x200
PAYLOAD_WORDS = 32256        # 0xFE00 less the header

# Header word 23 on a diagnostics build. From 1.1.0-rc4 it is
# {from_state, reserved, fail_idx[5:0], verdict[7:0]}; 1.0.2 and rc3 wrote
# the bare verdict (high byte 0) with codes 0-3, where 2 meant "rejected".
# The short labels go on the diagnostics line; codes 0-3 with a zero high
# byte print exactly as they always did.
VERDICT_OLD = {0: 'none', 1: 'ACCEPTED', 2: 'REJECTED', 3: 'REFUSED (bad checksum)'}
VERDICT_NEW = {0: 'none', 1: 'ACCEPTED', 2: 'REJECTED (coverage)',
               3: 'REFUSED (bad checksum)', 4: 'REFUSED (header)',
               5: 'NOTHING DELIVERED', 6: 'NO IMAGE'}


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
                    'flash was not touched, and the load fails if this session had '
                    'already written flash')
        return ('NO IMAGE -- the delivered file is not a janisc.NGPC save (magic '
                'mismatch); nothing was written')
    return 'verdict code %d is not known to this tool -- written by a newer core?' % code


def diagnostics(w):
    """Header words 16-18 and 22-24, as the save diagnostics build stamps them."""
    beats, drops, drain = w(16), w(17), w(18)
    applies, word23, p2wr = w(22), w(23), w(24)
    code = word23 & 0xFF
    fail_idx = (word23 >> 8) & 0x3F
    reserved = (word23 >> 14) & 1
    from_state = word23 >> 15
    # 1.0.2 and rc3 leave word 18 at 0 and the high byte of word 23 at 0,
    # and never write codes past 3. Anything else is 1.1.0-rc4 or later.
    rc4 = drain != 0 or (word23 >> 8) != 0 or code > 3
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
    if reserved:
        text += ' (word 23 has its reserved bit set -- a newer core?)'
    say('last apply', text)
    # Where the apply stopped. Index 0 is a real place for "no image" (the
    # magic) but means "not applicable" for the checks past the header.
    if rc4 and (code in (4, 6) or (code in (2, 3) and fail_idx)):
        say('failed check', 'header word %d (%s)' % (fail_idx, header_field(fail_idx)))


def main(path):
    d = open(path, 'rb').read()
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
        diagnostics(w)
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
