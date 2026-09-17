#!/usr/bin/env python3
"""Decode a janisc.NGPC save file and report what is actually in it.

No dependencies: python3 tools/savinfo.py "path/to/game.sav"

Paste the output into a bug report. It says which cartridge the save
belongs to, which flash blocks it carries, whether those blocks contain
real data or only erased flash, and -- on builds with the save
diagnostics enabled -- what the core's own counters recorded.
"""
import sys

MAGIC = b'NGPCSAV2'          # stored byte-swapped per 16-bit word
HDR_BYTES = 0x200


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


def main(path):
    d = open(path, 'rb').read()
    w = lambda i: int.from_bytes(d[2 * i:2 * i + 2], 'little')

    print('file            : %s' % path)
    print('size            : %d bytes%s' % (len(d), '' if len(d) == 65024 else '  <-- unexpected'))

    magic = bytes(d[0:8])
    swapped = bytes(b for i in range(0, 8, 2) for b in (d[i + 1], d[i]))
    if swapped != MAGIC:
        print('magic           : %r  <-- NOT a janisc.NGPC save' % magic)
        return 1
    print('magic           : ok (NGPCSAV2)')

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

    off = HDR_BYTES
    any_data = False
    for die, b in blocks:
        n = geo.get(b, 0)
        chunk = d[off:off + n]
        erased = all(c == 0xFF for c in chunk)
        if not erased:
            any_data = True
        print('   die%d block %-2d %6d bytes : %s' % (
            die, b, n, 'ERASED (no data)' if erased else
            'has data (%d%% written)' % (100 - chunk.count(0xFF) * 100 // max(len(chunk), 1))))
        off += n

    if any(w(i) for i in (16, 17, 22, 23, 24)):
        print('diagnostics     : ingest %d beats / %d drops | applies %d | verdict %s | flash writes %d' % (
            w(16), w(17), w(22),
            {0: 'none', 1: 'ACCEPTED', 2: 'REJECTED'}.get(w(23), w(23)), w(24)))
    else:
        print('diagnostics     : none recorded (build without save diagnostics)')

    print()
    if not blocks:
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
