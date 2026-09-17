#!/usr/bin/env python3
"""Decode a janisc.NGPC save file and report what is actually in it.

No dependencies: python3 tools/savinfo.py "path/to/game.sav"

Paste the output into a bug report. It says which cartridge the save
belongs to, which flash blocks it carries, whether those blocks contain
real data or only erased flash, whether the file's own checksum still
matches, and -- on builds with the save diagnostics enabled -- what the
core's own counters recorded.
"""
import sys
import zlib

HDR_BYTES = 0x200
PAYLOAD_WORDS = 32256        # 0xFE00 less the header


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
    if version not in '23':
        print('magic           : ok, but version %r is from a newer core' % version)
        return 1
    print('magic           : ok (NGPCSAV%s%s)' % (
        version, '' if version == '3' else '  -- pre-1.0.3 layout, uncompressed'))

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
    if version == '3':
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

    any_data = False
    for (die, b), n, chunk in zip(blocks, sizes, chunks):
        erased = all(c == 0xFF for c in chunk)
        if not erased:
            any_data = True
        print('   die%d block %-2d %6d bytes : %s' % (
            die, b, n, 'ERASED (no data)' if erased else
            'has data (%d%% written)' % (100 - chunk.count(0xFF) * 100 // max(len(chunk), 1))))

    if any(w(i) for i in (16, 17, 22, 23, 24)):
        print('diagnostics     : ingest %d beats / %d drops | applies %d | verdict %s | flash writes %d' % (
            w(16), w(17), w(22),
            {0: 'none', 1: 'ACCEPTED', 2: 'REJECTED', 3: 'REFUSED (bad checksum)'}
            .get(w(23), w(23)), w(24)))
    else:
        print('diagnostics     : none recorded (build without save diagnostics)')

    print()
    if ok is False:
        print('VERDICT: THIS FILE IS DAMAGED. Its own checksum does not match its')
        print('         contents, so the core will refuse it rather than write')
        print('         nonsense into the cartridge. Keep the file: an older copy')
        print('         or a backup is the only way back.')
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
