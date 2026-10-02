#!/usr/bin/env python3
"""rc6 family F helper: the cartridge save image the machine model carries.

    python3 sim/tb_rc6f_mkimg.py <out.hex>

Writes a real janisc.NGPC V4 save (0xFE00 bytes: a 256-word header with the
rc6 writer revision, three blocks of a 16 Mbit cartridge, the packed
payload and its CRC) as 16256 32-bit words, one hex word per line, in the
order sim/tb_rc6f_stamp.sv's copier model streams them into the blob's cart
section. Word k is bytes 4k..4k+3 of the .sav read little-endian: the
section as ngpc_state_cart stores it, which tools/savinfo.py undoes when it
reads the section out of a .sta (each big-endian word byte-reversed).

Built here from the format (the same rules tools/test_savinfo.py uses) so
that the captures the bench writes out decode as a real save underneath the
load diagnostic. No dependencies.
"""
import sys

SLOT_BYTES = 0xFE00
HDR_WORDS = 256
CART_BYTES = 0x200000          # 16 Mbit: blocks 32 and 33 are 8 KB, 34 is 16 KB
ROM_CRC = 0x94B63A97           # also the bench's cartridge CRC (CRC_OK)
BLOCK_BYTES = {32: 8192, 33: 8192, 34: 16384}
TITLE = b'CARD FIGHT E'
CATALOGUE = 0x0067
SUBCAT = 0x03
WRITER_RC6 = 0x06


def crc32_words(words):
    """Reflected CRC32 (poly EDB88320, init/final all ones) over the packed
    payload words, each shifted in low bit first."""
    c = 0xFFFFFFFF
    for v in words:
        for b in range(16):
            c = ((c >> 1) ^ 0xEDB88320) if ((c ^ (v >> b)) & 1) else (c >> 1)
    return c ^ 0xFFFFFFFF


def pack(blocks):
    """V4 packing: literals pass through; a run of erased words is 0xFFFF
    then the run length. Runs stop at a block boundary."""
    out = []
    for blk in blocks:
        i = 0
        while i < len(blk):
            if blk[i] != 0xFFFF:
                out.append(blk[i])
                i += 1
            else:
                j = i
                while j < len(blk) and blk[j] == 0xFFFF:
                    j += 1
                out += [0xFFFF, j - i]
                i = j
    return out


def contents():
    b32 = [0xFFFF] * (BLOCK_BYTES[32] // 2)
    for i in range(1024):
        b32[i] = (0x1234 + 7 * i) & 0xFFFE
    b33 = [0xFFFF] * (BLOCK_BYTES[33] // 2)
    b34 = [0xFFFF] * (BLOCK_BYTES[34] // 2)
    for i in range(16):
        b34[-1 - i] = 0x0A00 + i
    return {32: b32, 33: b33, 34: b34}


def image():
    data = contents()
    order = sorted(data)
    payload = pack([data[b] for b in order])
    crc = crc32_words(payload)
    h = [0] * HDR_WORDS
    tag = 'NGPCSAV4'                   # stored byte-swapped per word
    for k in range(4):
        h[k] = (ord(tag[2 * k]) << 8) | ord(tag[2 * k + 1])
    h[4], h[5] = ROM_CRC & 0xFFFF, ROM_CRC >> 16
    h[6], h[7] = CART_BYTES >> 16, CART_BYTES & 0xFFFF
    bm0 = sum(1 << b for b in order)
    for k in range(4):
        h[8 + k] = (bm0 >> (16 * k)) & 0xFFFF
    # diagnostics: a boot apply accepted, delivery only
    h[16], h[17], h[18], h[22], h[23], h[24] = 32512, 0, 0, 1, 0x0001, 0
    h[19], h[20] = crc & 0xFFFF, crc >> 16
    h[21] = (WRITER_RC6 << 8) | SUBCAT
    for k in range(6):
        h[25 + k] = TITLE[2 * k] | (TITLE[2 * k + 1] << 8)
    h[31] = CATALOGUE
    raw = b''.join((v & 0xFFFF).to_bytes(2, 'little') for v in h + payload)
    assert len(raw) <= SLOT_BYTES
    return raw + b'\xFF' * (SLOT_BYTES - len(raw))


def main(out):
    img = image()
    with open(out, 'w') as f:
        for i in range(len(img) // 4):
            f.write('%08x\n' % int.from_bytes(img[4 * i:4 * i + 4], 'little'))
    return 0


if __name__ == '__main__':
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
