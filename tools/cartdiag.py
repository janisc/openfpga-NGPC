#!/usr/bin/env python3
"""Read the cartridge-load diagnostics of a 1.1.0-rc6-diag Memory or sleep state.

For cores built with NGPC_CART_DIAG only. Such a core stamps two spare savestate
pad words at every capture (see target/pocket/ngpc_cart_diag.sv):

  word 8419  bridge-side CRC32 of the cartridge as the Pocket delivered it
  word 8418  diag2: {overflow, dropped words (14 bits, saturating), CRC overrun,
             transfer time in units of 4096 clk_74a cycles (55.2 us)}
             diag1 (--v1): {overflow, dropped words (15 bits), transfer time}

together with the identity block's image CRC (word 8421), which ngp_cart_rom
computes after the cartridge FIFO. Usage:

  python cartdiag.py <state.sta> [expected ROM CRC32, hex] [--v1]   or
  python cartdiag.py <state.sta> --rom <rom file> [--v1]
"""
import sys
import zlib

HDR = 592          # the Pocket's header in front of the blob
W_DIAG_A = 8418
W_DIAG_B = 8419
W_ID_MAGIC = 8420
W_ID_CRC = 8421
W_ID_LAYOUT = 8422


def word(d, n):
    o = HDR + 4 * n
    return int.from_bytes(d[o:o + 4], 'big')


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    v1 = '--v1' in argv
    argv = [x for x in argv if x != '--v1']
    d = open(argv[1], 'rb').read()
    expected = None
    if len(argv) >= 4 and argv[2] == '--rom':
        expected = zlib.crc32(open(argv[3], 'rb').read()) & 0xFFFFFFFF
    elif len(argv) >= 3:
        expected = int(argv[2], 16)

    a, b = word(d, W_DIAG_A), word(d, W_DIAG_B)
    img = word(d, W_ID_CRC)
    layout = word(d, W_ID_LAYOUT)
    overflow = a >> 31
    if v1:
        drops, dmax, overrun = (a >> 16) & 0x7FFF, 0x7FFF, 0
    else:
        drops, dmax, overrun = (a >> 17) & 0x3FFF, 0x3FFF, (a >> 16) & 1
    dur = a & 0xFFFF
    secs = dur * 4096 / 74.25e6

    print('file              :', argv[1])
    print('identity layout   : %d%s' % (layout & 0xFF, ' (saving was off: save refused)' if (layout & 0xFF) == 3 else ''))
    print('image CRC (core)  : %08X   after the cartridge FIFO, what the save check uses' % img)
    print('bridge CRC        : %08X   as the Pocket delivered it, before any FIFO' % b)
    if expected is not None:
        print('expected (file)   : %08X' % expected)
    print('cart FIFO         : overflow %s, %s%d word(s) dropped' % (
        'YES' if overflow else 'no', '>= ' if drops == dmax else '', drops))
    if overrun:
        print('WARNING           : the bridge-side CRC could not keep up (overrun); its value is not reliable')
    print('transfer time     : %s%.3f s (first to last cartridge word)' % ('>= ' if dur == 0xFFFF else '', secs))
    if secs > 0:
        print('average rate      : about %.2f MB/s' % (2 * 1024 * 1024 / secs / 1e6) + '  (for a 2 MB cartridge)')

    print()
    if expected is None:
        print('Give the expected ROM CRC (or --rom <file>) for a verdict.')
        return 0
    if b == expected and img == expected:
        print('VERDICT: clean load -- the data arrived intact and the core kept it intact.')
    elif b == expected and img != expected:
        print('VERDICT: the Pocket delivered the cartridge INTACT, and the core corrupted or lost it on the')
        print('         way to the cartridge loader%s.' % (' (the cartridge FIFO overflowed)' if overflow else ''))
    elif b != expected and img == b:
        print('VERDICT: the data was ALREADY WRONG when it reached the core (Pocket, SD card or bridge input),')
        print('         and the core passed it on faithfully.')
    else:
        print('VERDICT: wrong at the bridge AND changed again inside the core -- both ends need a look.')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
