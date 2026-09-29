#!/usr/bin/env python3
"""Self-check for tools/savinfo.py. No dependencies:

    python3 tools/test_savinfo.py

Builds synthetic V2 and V4 save files in a temporary directory, runs the
tool on each exactly as a user would, and checks what it prints: the
payload checksum (computed here the way sim/tb_cart_save.sv does it, not
the way the tool does), the old diagnostics line of 1.0.2 and rc3 files,
the 1.1.0-rc4 word 23 decode for every verdict code, and the split of
the ingest count into delivery and savestate drain.

Prints PASS/FAIL per scenario and a final "== ALL ... PASS" or
"== N FAILURE(S)" line; exits non-zero on any failure.
"""
import os
import subprocess
import sys
import tempfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, 'savinfo.py')

SLOT_BYTES = 0xFE00
HDR_WORDS = 256
CART_BYTES = 0x200000          # 16 Mbit: blocks 32 and 33 are 8 KB, 34 is 16 KB
ROM_CRC = 0x94B63A97
BLOCK_BYTES = {32: 8192, 33: 8192, 34: 16384}
TITLE = b'CARD FIGHT E'
CATALOGUE = 0x0067
SUBCAT = 0x03
TIMEOUT_S = 30                 # watchdog per tool run

failures = 0
passes = 0


# ---------------------------------------------------------------- the format

def crc32_words(words):
    """The payload checksum as sim/tb_cart_save.sv crc_of computes it: a
    reflected CRC32 (poly EDB88320, init and final xor all ones) over the
    packed payload words only -- not the header -- each word shifted in
    low bit first, i.e. low byte first as the file stores it."""
    c = 0xFFFFFFFF
    for v in words:
        for b in range(16):
            c = ((c >> 1) ^ 0xEDB88320) if ((c ^ (v >> b)) & 1) else (c >> 1)
    return c ^ 0xFFFFFFFF


def pack(blocks):
    """The V4 packing: a literal passes through; a run of erased words is
    0xFFFF followed by the run length. Runs stop at a block boundary."""
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


def block_contents():
    """Block 32 part written, block 33 erased, block 34 written at its end,
    with one lone 0xFFFF inside the data (a run of one)."""
    b32 = [0xFFFF] * (BLOCK_BYTES[32] // 2)
    for i in range(1024):
        b32[i] = (0x1234 + 7 * i) & 0xFFFE
    b32[100] = 0xFFFF
    b33 = [0xFFFF] * (BLOCK_BYTES[33] // 2)
    b34 = [0xFFFF] * (BLOCK_BYTES[34] // 2)
    for i in range(16):
        b34[-1 - i] = 0x0A00 + i
    return {32: b32, 33: b33, 34: b34}


def header(version, blocks, diag, crc=0):
    h = [0] * HDR_WORDS
    tag = 'NGPCSAV' + version            # stored byte-swapped per word
    for k in range(4):
        h[k] = (ord(tag[2 * k]) << 8) | ord(tag[2 * k + 1])
    h[4], h[5] = ROM_CRC & 0xFFFF, ROM_CRC >> 16
    h[6], h[7] = CART_BYTES >> 16, CART_BYTES & 0xFFFF
    bm0 = sum(1 << b for b in blocks)
    for k in range(4):
        h[8 + k] = (bm0 >> (16 * k)) & 0xFFFF
    for idx, val in diag.items():
        h[idx] = val & 0xFFFF
    h[19], h[20] = crc & 0xFFFF, crc >> 16
    h[21] = SUBCAT
    for k in range(6):
        h[25 + k] = TITLE[2 * k] | (TITLE[2 * k + 1] << 8)
    h[31] = CATALOGUE
    return h


def to_bytes(words):
    raw = b''.join((v & 0xFFFF).to_bytes(2, 'little') for v in words)
    assert len(raw) <= SLOT_BYTES
    return raw + b'\xFF' * (SLOT_BYTES - len(raw))


def diag_words(beats=32512, drops=0, drain=0, applies=1, word23=0, p2wr=0):
    return {16: beats, 17: drops, 18: drain, 22: applies, 23: word23, 24: p2wr}


def make_v4(tmp, name, diag, corrupt=False):
    data = block_contents()
    order = sorted(data)
    payload = pack([data[b] for b in order])
    crc = crc32_words(payload)
    if corrupt:
        payload = list(payload)
        payload[0] ^= 0x0001            # a literal word, after the CRC was taken
    path = os.path.join(tmp, name)
    with open(path, 'wb') as f:
        f.write(to_bytes(header('4', order, diag, crc) + payload))
    return path, payload, crc


def make_v2(tmp, name, diag):
    data = block_contents()
    order = sorted(data)
    raw = [v for b in order for v in data[b]]
    path = os.path.join(tmp, name)
    with open(path, 'wb') as f:
        f.write(to_bytes(header('2', order, diag) + raw))
    return path


# ---------------------------------------------------------------- the checks

def run(path):
    try:
        r = subprocess.run([sys.executable, TOOL, path], capture_output=True,
                           text=True, timeout=TIMEOUT_S)
    except subprocess.TimeoutExpired:
        return -1, [], 'WATCHDOG: savinfo.py ran longer than %d s' % TIMEOUT_S
    return r.returncode, r.stdout.splitlines(), r.stderr


def field(lines, label):
    """The value of a labelled line with its continuation lines, joined."""
    key = '%-16s: ' % label
    for i, ln in enumerate(lines):
        if ln.startswith(key):
            parts = [ln[len(key):]]
            for more in lines[i + 1:]:
                if more.startswith(' ' * 18) and more.strip():
                    parts.append(more.strip())
                else:
                    break
            return ' '.join(parts)
    return None


def line(lines, label):
    key = '%-16s: ' % label
    return next((ln for ln in lines if ln.startswith(key)), None)


class Scenario:
    def __init__(self, sid, what):
        self.sid, self.what, self.errs = sid, what, []

    def check(self, cond, msg):
        if not cond:
            self.errs.append(msg)

    def eq(self, got, want, what):
        self.check(got == want, '%s: got %r, want %r' % (what, got, want))

    def has(self, text, frag, what):
        self.check(text is not None and frag in text,
                   '%s: %r not found in %r' % (what, frag, text))

    def done(self):
        global failures, passes
        if self.errs:
            failures += 1
            print('FAIL %-4s %s' % (self.sid, self.what))
            for e in self.errs:
                print('       ' + e)
        else:
            passes += 1
            print('PASS %-4s %s' % (self.sid, self.what))


def tool_ok(s, rc, err):
    s.eq(rc, 0, 'exit code')
    s.check(not err, 'stderr: %s' % err.strip())


def old_diag_line(beats, drops, applies, verdict, p2wr):
    return ('diagnostics     : ingest %d beats / %d drops | applies %d | verdict %s | flash writes %d'
            % (beats, drops, applies, verdict, p2wr))


def main():
    with tempfile.TemporaryDirectory(prefix='savinfo_test_') as tmp:

        # ---- A: the payload checksum and the file formats ----------------
        s = Scenario('A1', 'CRC reimplementation: bench-style bitwise CRC32 == zlib over the LE payload bytes')
        _, payload, crc = make_v4(tmp, 'a1.sav', diag_words())
        le = b''.join(v.to_bytes(2, 'little') for v in payload)
        s.eq(crc, zlib.crc32(le) & 0xFFFFFFFF, 'crc')
        s.check(crc != crc32_words(list(payload) + [0]), 'crc must depend on the payload length')
        s.done()

        s = Scenario('A2', 'V4 file with a correct payload CRC decodes as ok and a real save')
        path, payload, crc = make_v4(tmp, 'a2.sav', diag_words(word23=1, p2wr=16384))
        rc, out, err = run(path)
        tool_ok(s, rc, err)
        s.eq(line(out, 'payload checksum'), 'payload checksum: %08X ok' % crc, 'checksum line')
        s.has(line(out, 'packed payload'), '%d words (%d bytes) for 32768 bytes of flash'
              % (len(payload), 2 * len(payload)), 'packed payload')
        s.has(line(out, 'magic'), 'ok (NGPCSAV4)', 'magic')
        s.has(line(out, 'cartridge'), '"CARD FIGHT E"   catalogue 0067-03', 'cartridge')
        s.eq(line(out, 'saved blocks'), 'saved blocks    : die0/32, die0/33, die0/34', 'blocks')
        s.check(any('die0 block 33' in ln and 'ERASED' in ln for ln in out), 'block 33 not ERASED')
        s.check(any('die0 block 32' in ln and 'has data' in ln for ln in out), 'block 32 has no data')
        s.check('VERDICT: looks like a real save.' in out, 'final verdict')
        s.done()

        s = Scenario('A3', 'V4 file whose payload no longer matches its CRC is reported damaged')
        path, _, crc = make_v4(tmp, 'a3.sav', diag_words(word23=1), corrupt=True)
        rc, out, err = run(path)
        tool_ok(s, rc, err)
        s.has(line(out, 'payload checksum'), '%08X MISMATCH, computed' % crc, 'checksum line')
        s.check('VERDICT: THIS FILE IS DAMAGED. Its own checksum does not match its' in out,
                'damaged verdict')
        s.done()

        s = Scenario('A4', 'V2 file (1.0.2 layout) decodes raw blocks with no checksum line')
        path = make_v2(tmp, 'a4.sav', diag_words())
        rc, out, err = run(path)
        tool_ok(s, rc, err)
        s.has(line(out, 'magic'), 'NGPCSAV2  -- pre-1.1 layout, uncompressed', 'magic')
        s.eq(line(out, 'payload checksum'), None, 'checksum line')
        s.check('VERDICT: looks like a real save.' in out, 'final verdict')
        s.done()

        # ---- B: 1.0.2 / rc3 diagnostics read exactly as before -----------
        legacy = [
            # id,  word23, applies, old label,                 last-apply text
            ('B0', 0, 0, 'none', 'none yet -- nothing has been applied'),
            ('B0e', 0, 1, 'none', 'no verdict recorded -- a core before 1.1.0-rc4 leaves this'),
            ('B1', 1, 1, 'ACCEPTED', 'ACCEPTED -- the save matched this cartridge; the flash writes count'),
            ('B2', 2, 2, 'REJECTED', 'REJECTED -- the core turned this save down'),
            ('B3', 3, 1, 'REFUSED (bad checksum)', 'REFUSED -- the payload checksum did not match'),
        ]
        for sid, w23, applies, label, text in legacy:
            for fmt in ('2', '4'):
                s = Scenario('%s/V%s' % (sid, fmt),
                             'old verdict %d (word 18 = 0, high byte 0) keeps its old line and meaning' % w23)
                d = diag_words(beats=32512, drops=3, applies=applies, word23=w23, p2wr=77)
                path = make_v2(tmp, 'b.sav', d) if fmt == '2' else make_v4(tmp, 'b.sav', d)[0]
                rc, out, err = run(path)
                tool_ok(s, rc, err)
                s.eq(line(out, 'diagnostics'), old_diag_line(32512, 3, applies, label, 77), 'diagnostics line')
                s.eq(line(out, 'ingest split'),
                     'ingest split    : delivery 32512 beats | drain 0 beats'
                     '  (cores before 1.1.0-rc4 count drains as delivery)', 'split line')
                la = field(out, 'last apply')
                s.has(la, text, 'last apply')
                s.check(la is not None and not la.startswith(('savestate', 'boot')),
                        'old files record no origin: %r' % la)
                s.eq(line(out, 'failed check'), None, 'failed check line')
                s.done()

        # ---- C: rc4 word 23 = {from_state, reserved, fail_idx, verdict} ---
        boot, state = 'boot or late delivery: ', 'savestate load: '
        rc4 = [
            # id,   word23, drain, applies, label, origin+text, failed check
            ('C0', 0x0000, 32512, 0, 'none', 'none yet -- nothing has been applied', None),
            ('C1', 0x0001, 5, 1, 'ACCEPTED',
             boot + 'ACCEPTED -- the save matched this cartridge and was written into its flash', None),
            ('C1s', 0x8001, 32512, 2, 'ACCEPTED',
             state + 'ACCEPTED -- the save matched this cartridge and was written into its flash', None),
            ('C2', 0x8802, 32512, 2, 'REJECTED (coverage)',
             state + "REJECTED -- the savestate's save lacks a block this session had already written",
             'header word 8 (block bitmap)'),
            ('C2z', 0x8002, 32512, 2, 'REJECTED (coverage)', state + 'REJECTED -- the savestate', None),
            # from_state (bit 15) is the only rc4 evidence here: no drains,
            # fail_idx 0, an old-range code. It must still decode as rc4.
            ('C2d', 0x8002, 0, 2, 'REJECTED (coverage)',
             state + "REJECTED -- the savestate's save lacks a block", None),
            ('C3', 0x1303, 0, 1, 'REFUSED (bad checksum)',
             boot + 'REFUSED -- the payload checksum did not match', 'header word 19 (payload checksum)'),
            ('C3s', 0x9403, 32512, 2, 'REFUSED (bad checksum)',
             state + 'REFUSED -- the payload checksum did not match', 'header word 20 (payload checksum)'),
            ('C3z', 0x8003, 32512, 2, 'REFUSED (bad checksum)', state + 'REFUSED -- the payload', None),
            ('C4', 0x0304, 0, 1, 'REFUSED (header)',
             boot + "REFUSED -- the header's format tag or ROM CRC does not match", 'header word 3 (format tag)'),
            ('C4s', 0x8504, 32512, 2, 'REFUSED (header)',
             state + "REFUSED -- the header's format tag or ROM CRC", 'header word 5 (ROM CRC32)'),
            ('C5', 0x0005, 0, 1, 'NOTHING DELIVERED',
             boot + 'NOTHING DELIVERED -- the Pocket delivered no save file this session', None),
            ('C6', 0x0006, 0, 1, 'NO IMAGE',
             boot + 'NO IMAGE -- the delivered file is not a janisc.NGPC save', 'header word 0 (magic)'),
            ('C6s', 0x8106, 32512, 2, 'NO IMAGE',
             state + 'NO IMAGE -- the savestate was taken while no save was staged', 'header word 1 (magic)'),
            ('C7', 0x0007, 0, 1, '7 (word 23 = 0007)', 'verdict code 7 is not known to this tool', None),
            ('C8', 0x4001, 0, 1, 'ACCEPTED', 'reserved bit set', None),
        ]
        for sid, w23, drain, applies, label, text, failed in rc4:
            s = Scenario(sid, 'rc4 word 23 = %04X: label, plain-language line, failing check' % w23)
            beats = 32512 + drain
            path, _, _ = make_v4(tmp, 'c.sav', diag_words(beats=beats, drain=drain, applies=applies,
                                                          word23=w23, p2wr=9))
            rc, out, err = run(path)
            tool_ok(s, rc, err)
            s.eq(line(out, 'diagnostics'), old_diag_line(beats & 0xFFFF, 0, applies, label, 9),
                 'diagnostics line')
            la = field(out, 'last apply')
            s.check(la is not None and (text in la if sid in ('C7', 'C8') else la.startswith(text)),
                    'last apply: %r does not start with %r' % (la, text))
            if failed is None:
                s.eq(line(out, 'failed check'), None, 'failed check line')
            else:
                s.eq(field(out, 'failed check'), failed, 'failed check')
            # A file that shows rc4 evidence carries no "older core" caveat.
            s.check('before 1.1.0-rc4' not in (line(out, 'ingest split') or ''),
                    'rc4 file got the old-core note: %r' % line(out, 'ingest split'))
            s.done()

        # fail_idx is exactly bits 13:8. Reserved bit 14 set and fail_idx bit 5
        # set together: a mask that takes bit 14 in reads 99, a 5-bit mask 3.
        s = Scenario('C9', 'rc4 word 23 = 6304: fail_idx is bits 13:8 only (not bit 14, not 5 bits)')
        path, _, _ = make_v4(tmp, 'c9.sav', diag_words(beats=32512, drain=0, applies=1,
                                                       word23=0x6304, p2wr=9))
        rc, out, err = run(path)
        tool_ok(s, rc, err)
        s.eq(line(out, 'diagnostics'), old_diag_line(32512, 0, 1, 'REFUSED (header)', 9),
             'diagnostics line')
        la = field(out, 'last apply')
        s.check(la is not None and la.startswith(boot + "REFUSED -- the header's format tag"),
                'last apply: %r' % la)
        s.has(la, 'reserved bit set', 'reserved-bit note')
        s.has(field(out, 'failed check'), 'header word 35 (', 'failed check index')
        s.done()

        # ---- D: delivery beats = word 16 - word 18 (mod 2^16) -------------
        split = [
            # id,  beats,  drain,  word23, expected split line
            ('D1', 65024 & 0xFFFF, 32512, 0x8001,
             'ingest split    : delivery 32512 beats | drain 32512 beats'),
            ('D2', 0x0100, 0x7F00, 0x8001,
             'ingest split    : delivery 33280 beats | drain 32512 beats  (16-bit counters wrapped)'),
            ('D3', 32512, 32512, 0x8001,
             'ingest split    : delivery 0 beats | drain 32512 beats'),
            ('D4', 1234, 0, 0x0001,
             'ingest split    : delivery 1234 beats | drain 0 beats  (cores before 1.1.0-rc4 count drains as delivery)'),
            ('D5', 0, 0x8100, 0x0000,
             'ingest split    : delivery 32512 beats | drain 33024 beats  (16-bit counters wrapped)'),
            ('D6', 32512, 7, 0x0001,
             'ingest split    : delivery 32505 beats | drain 7 beats'),
        ]
        for sid, beats, drain, w23, want in split:
            s = Scenario(sid, 'split of ingest %d beats with %d drain beats' % (beats, drain))
            d = diag_words(beats=beats, drain=drain, applies=0 if sid == 'D5' else 1, word23=w23)
            path, _, _ = make_v4(tmp, 'd.sav', d)
            rc, out, err = run(path)
            tool_ok(s, rc, err)
            s.eq(line(out, 'ingest split'), want, 'split line')
            s.has(line(out, 'diagnostics'), 'ingest %d beats / 0 drops' % beats, 'diagnostics total')
            s.done()

        s = Scenario('D7', 'word 18 alone is enough to count as diagnostics')
        path, _, _ = make_v4(tmp, 'd7.sav', diag_words(beats=0, drain=0x7F00, applies=0, word23=0))
        rc, out, err = run(path)
        tool_ok(s, rc, err)
        s.check(line(out, 'diagnostics') is not None and 'none recorded' not in line(out, 'diagnostics'),
                'diagnostics not printed: %r' % line(out, 'diagnostics'))
        s.done()

        s = Scenario('D8', 'no diagnostics words: the old "none recorded" line and nothing new')
        path, _, _ = make_v4(tmp, 'd8.sav', {})
        rc, out, err = run(path)
        tool_ok(s, rc, err)
        s.eq(line(out, 'diagnostics'),
             'diagnostics     : none recorded (build without save diagnostics)', 'diagnostics line')
        s.eq(line(out, 'ingest split'), None, 'split line')
        s.eq(line(out, 'last apply'), None, 'last apply line')
        s.done()

        # ---- E: the new lines sit between diagnostics and the verdict ----
        s = Scenario('E1', 'line order: blocks, diagnostics, ingest split, last apply, failed check, VERDICT')
        path, _, _ = make_v4(tmp, 'e1.sav', diag_words(drain=32512, beats=65024 & 0xFFFF, word23=0x9303))
        rc, out, err = run(path)
        tool_ok(s, rc, err)
        labels = ['file', 'size', 'magic', 'cartridge', 'ROM CRC32', 'ROM size', 'saved blocks',
                  'packed payload', 'payload checksum', 'diagnostics', 'ingest split',
                  'last apply', 'failed check']
        idx = [next((i for i, ln in enumerate(out) if ln.startswith('%-16s: ' % l)), -1) for l in labels]
        s.check(-1 not in idx and idx == sorted(idx), 'order %r' % list(zip(labels, idx)))
        blk = [i for i, ln in enumerate(out) if ln.startswith('   die')]
        s.check(blk and idx[8] < blk[0] and blk[-1] < idx[9], 'block lines not between checksum and diagnostics')
        v = next((i for i, ln in enumerate(out) if ln.startswith('VERDICT:')), -1)
        s.check(v > idx[-1] and out[v - 1] == '', 'VERDICT not after a blank line following the new lines')
        s.done()

    total = passes + failures
    if failures:
        print('== %d FAILURE(S) of %d savinfo scenarios' % (failures, total))
        return 1
    print('== ALL %d savinfo scenarios PASS' % total)
    return 0


if __name__ == '__main__':
    sys.exit(main())
