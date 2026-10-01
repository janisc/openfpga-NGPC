#!/usr/bin/env python3
"""Self-check for tools/savinfo.py. No dependencies:

    python3 tools/test_savinfo.py

Builds synthetic V2 and V4 save files in a temporary directory, runs the
tool on each exactly as a user would, and checks what it prints: the
payload checksum (computed here the way sim/tb_cart_save.sv does it, not
the way the tool does), the old diagnostics line of 1.0.2 and rc3 files,
the 1.1.0-rc4 word 23 decode for every verdict code, the split of the
ingest count into delivery and savestate drain, and from 1.1.0-rc5 the
writer revision in the high byte of word 21 and verdict 7 (a savestate
from a frozen session). Groups F and G pin the rc5 additions and that
everything an rc4 tool printed is still printed, line for line. Group H pins
rc6: writer revision 6, the staging check in word 23 bit 14, and sleep
states / Memories (.sta) with the load diagnostic in pad word 8419.

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


def word21(rev=0, subcat=SUBCAT):
    """Header word 21: {writer revision, catalogue sub-code}. 1.1.0-rc5
    writes revision 0x05; every older writer left the high byte 0."""
    return ((rev & 0xFF) << 8) | (subcat & 0xFF)


def header(version, blocks, diag, crc=0, w21=SUBCAT, title=TITLE, catalogue=CATALOGUE):
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
    h[21] = w21 & 0xFFFF
    for k in range(6):
        h[25 + k] = title[2 * k] | (title[2 * k + 1] << 8)
    h[31] = catalogue
    return h


def to_bytes(words):
    raw = b''.join((v & 0xFFFF).to_bytes(2, 'little') for v in words)
    assert len(raw) <= SLOT_BYTES
    return raw + b'\xFF' * (SLOT_BYTES - len(raw))


def diag_words(beats=32512, drops=0, drain=0, applies=1, word23=0, p2wr=0):
    return {16: beats, 17: drops, 18: drain, 22: applies, 23: word23, 24: p2wr}


def make_v4(tmp, name, diag, corrupt=False, **hdr):
    data = block_contents()
    order = sorted(data)
    payload = pack([data[b] for b in order])
    crc = crc32_words(payload)
    if corrupt:
        payload = list(payload)
        payload[0] ^= 0x0001            # a literal word, after the CRC was taken
    path = os.path.join(tmp, name)
    with open(path, 'wb') as f:
        f.write(to_bytes(header('4', order, diag, crc, **hdr) + payload))
    return path, payload, crc


def make_v2(tmp, name, diag, **hdr):
    data = block_contents()
    order = sorted(data)
    raw = [v for b in order for v in data[b]]
    path = os.path.join(tmp, name)
    with open(path, 'wb') as f:
        f.write(to_bytes(header('2', order, diag, **hdr) + raw))
    return path


def make_tagged(tmp, name, version, **hdr):
    """A header with any format tag and no payload (V3, V9, ...)."""
    path = os.path.join(tmp, name)
    with open(path, 'wb') as f:
        f.write(to_bytes(header(version, sorted(BLOCK_BYTES), diag_words(), **hdr)))
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


# ---------------------------------------------------------------- rc5

# The phrases the rc5 specification (tools/savinfo.py [rc5]) asks for.
SPEC_RC5 = 'written by 1.1.0-rc5'
SPEC_OLD = 'older writer (rev 0)'
SPEC_V7 = 'savestate from a frozen session: nothing applied, saving stays off'

WRITER_OLD = 'writer          : older writer (rev 0) -- 1.1.0-rc4 or earlier'
WRITER_RC5 = 'writer          : written by 1.1.0-rc5 (rev 5)'
FROZEN_TEXT = ('FROZEN STATE -- savestate from a frozen session: nothing applied, saving stays off; '
               'the savestate itself loaded, and flash was not touched')
OLD_CORE_NOTE = '(cores before 1.1.0-rc4 count drains as delivery)'

# Title bytes of a save written before 1.0.2: uninitialised staging, not text.
GARBLED = bytes([0x53, 0x52, 0xD1, 0x55, 0x55, 0x0D, 0xD5, 0x54, 0x55, 0x59, 0x54, 0x59])


# ---------------------------------------------------------------- rc6

WRITER_RC6 = 'writer          : written by 1.1.0-rc6 or later (rev 6)'
STA_OFF = 592                  # the Pocket's header before the core's blob
STA_WORDS = 24680              # the core's blob, 32-bit words
DG_TAG = 0xD1


def dg(loads=1, ran=1, ok=1, chk=0x1F, frozen=0, drained=1, held=0):
    """Pad word 8419 as the rc6 bridge stamps it."""
    return ((DG_TAG << 24) | (loads << 20) | (ran << 19) | (ok << 18) | (chk << 13) |
            (frozen << 12) | (drained << 11) | (held << 10))


def make_sta(tmp, name, diag, layout=2, crc=ROM_CRC, check=None, extra=0):
    """A sleep state or Memory: the identity block at 8420, the load
    diagnostic at 8419, and a V4 save image at 8424 as the copier stores it
    (each 32-bit word byte-reversed against the .sav's order)."""
    sav, _, _ = make_v4(tmp, name + '.img', diag_words(word23=0x0001), w21=word21(6))
    img = open(sav, 'rb').read()
    blob = bytearray(4 * STA_WORDS)
    def put(i, v):
        blob[4 * i:4 * i + 4] = (v & 0xFFFFFFFF).to_bytes(4, 'big')
    put(8419, diag)
    put(8420, 0x4E475053)
    put(8421, crc)
    put(8422, layout)
    put(8423, (crc ^ 0xFFFFFFFF) if check is None else check)
    for i in range(len(img) // 4):
        blob[4 * (8424 + i):4 * (8424 + i) + 4] = img[4 * i:4 * i + 4][::-1]
    path = os.path.join(tmp, name)
    with open(path, 'wb') as f:
        f.write(b'\x01SPA' + b'\x00' * (STA_OFF - 4) + bytes(blob) + b'\x00' * (4 + extra))
    return path


def rc6_additions(tmp):
    boot = 'boot or late delivery: '

    # ---- H1-H4: writer revision 6 and the staging check -----------------
    s = Scenario('H1', 'rev 6: "rc6 or later", staging check clean, no reserved-bit note')
    path, _, _ = make_v4(tmp, 'h1.sav', diag_words(word23=0x0001), w21=word21(6))
    rc, out, err = run(path)
    tool_ok(s, rc, err)
    s.eq(line(out, 'writer'), WRITER_RC6, 'writer line')
    s.eq(field(out, 'staging check'), 'clean', 'staging check')
    s.check('reserved bit' not in (field(out, 'last apply') or ''), 'reserved-bit note on a rev 6 file')
    s.check((field(out, 'last apply') or '').startswith(boot + 'ACCEPTED'), 'last apply %r' % field(out, 'last apply'))
    s.done()

    s = Scenario('H2', 'rev 6, word 23 bit 14 set: staging check FLAGGED, verdict decode unaffected')
    path, _, _ = make_v4(tmp, 'h2.sav', diag_words(word23=0x4001), w21=word21(6))
    rc, out, err = run(path)
    tool_ok(s, rc, err)
    s.has(field(out, 'staging check'), 'FLAGGED', 'staging check')
    s.has(field(out, 'staging check'), 'hardware fault', 'staging check')
    s.check('reserved bit' not in (field(out, 'last apply') or ''), 'reserved-bit note on a rev 6 file')
    s.check((field(out, 'last apply') or '').startswith(boot + 'ACCEPTED'), 'last apply %r' % field(out, 'last apply'))
    s.eq(line(out, 'failed check'), None, 'failed check line')
    s.done()

    s = Scenario('H3', 'rev 5, word 23 bit 14 set: the rc5 reserved-bit note, no staging check line')
    path, _, _ = make_v4(tmp, 'h3.sav', diag_words(word23=0x4001), w21=word21(5))
    rc, out, err = run(path)
    tool_ok(s, rc, err)
    s.has(field(out, 'last apply'), '(word 23 has its reserved bit set -- a newer core?)', 'last apply')
    s.eq(line(out, 'staging check'), None, 'staging check line')
    s.done()

    s = Scenario('H4', 'rev 6, word 23 = C306: savestate load, NO IMAGE at word 3, staging FLAGGED')
    path, _, _ = make_v4(tmp, 'h4.sav', diag_words(word23=0xC306), w21=word21(6))
    rc, out, err = run(path)
    tool_ok(s, rc, err)
    s.check((field(out, 'last apply') or '').startswith('savestate load: NO IMAGE'),
            'last apply %r' % field(out, 'last apply'))
    s.has(line(out, 'failed check'), 'header word 3 (format tag)', 'failed check')
    s.has(field(out, 'staging check'), 'FLAGGED', 'staging check')
    s.done()

    # ---- H5-H16: sleep states and Memories ------------------------------
    cases = [
        ('H5', 'pad word 0 (a core before rc6): not recorded', 0,
         'not recorded -- this state was written by a core before 1.1.0-rc6', None),
        ('H6', 'no load in the session: none', dg(loads=0, ran=0, ok=0, chk=0, drained=0),
         'none -- no savestate load since the core started or was last reset from the menu', None),
        ('H7', 'identity refused on the cartridge CRC', dg(ran=0, ok=0, chk=0b11011, drained=0),
         'REFUSED at the identity check (failed: the cartridge (ROM CRC)); the machine was not touched',
         'arrived after startup, with the game already running'),
        ('H8', 'identity refused: short transfer and a bad check word',
         dg(ran=0, ok=0, chk=0b01110, drained=0),
         'REFUSED at the identity check (failed: the transfer reached the end of the savestate, '
         'the identity check word); the machine was not touched', None),
        ('H9', 'every identity term passed but nothing drained: copier timeout',
         dg(ran=0, ok=0, drained=0),
         'FAILED -- the copier timed out waiting for the save engine; nothing was restored', None),
        ('H10', 'drained but not started: the apply refused the image', dg(ran=0, ok=0),
         "REFUSED -- the save engine refused the state's save image; nothing was restored "
         '(a Memory reports "Loading failed", a wake starts the game over)', None),
        ('H11', 'started but not accepted: the engine refused the header', dg(ok=0),
         'REFUSED -- the savestate engine refused the machine-state header, so the machine '
         'was not restored; the save image had already been applied to flash', None),
        ('H12', 'restored, early (the boot apply still held the machine)', dg(held=1),
         'RESTORED -- flash and machine state; a cold start after this came from something '
         'later, such as a power-off',
         'arrived while the core was still starting up (the boot apply held the machine)'),
        ('H13', 'restored, frozen, 15 loads (saturated)', dg(loads=15, frozen=1),
         'RESTORED -- machine state only: the state was captured while saving was off, so '
         'flash was left as it was and saving stays off', None),
        ('H14', 'unknown tag: said so, not decoded', 0xD2000000 | (dg() & 0xFFFFFF),
         'unknown diagnostic word D21FE800 -- written by a newer core?', None),
    ]
    for sid, what, word, want, timing in cases:
        s = Scenario(sid, 'sleep state: ' + what)
        path = make_sta(tmp, sid.lower() + '.sta', word)
        rc, out, err = run(path)
        tool_ok(s, rc, err)
        s.has(line(out, 'size'), 'a sleep state or Memory', 'size line')
        s.eq(line(out, 'layout'), 'layout          : 2 (normal)', 'layout line')
        s.eq(field(out, 'last load'), want, 'last load')
        if timing:
            s.eq(field(out, 'load timing'), timing, 'load timing')
        if sid == 'H13':
            s.eq(field(out, 'loads before it'),
                 '15 or more savestate load(s) since the core started or was last reset '
                 'from the menu', 'loads line')
        # The embedded save image is decoded like a .sav, underneath.
        s.eq(sum(1 for ln in out if ln.startswith('writer ')), 1, 'writer lines')
        s.eq(line(out, 'writer'), WRITER_RC6, 'embedded image writer')
        s.check(any(ln.startswith('payload checksum:') and ln.endswith(' ok') for ln in out),
                'embedded payload checksum not ok')
        s.check(out and out[-1].startswith('VERDICT: looks like a real save'), 'verdict %r' % out[-1:])
        s.done()

    s = Scenario('H15', 'sleep state: layout 3 (frozen) and a damaged identity check word')
    path = make_sta(tmp, 'h15.sta', dg(), layout=3, check=0x12345678)
    rc, out, err = run(path)
    tool_ok(s, rc, err)
    s.has(field(out, 'layout'), '3 -- captured while saving was off', 'layout')
    s.has(line(out, 'ROM CRC32'), 'identity check word MISMATCH', 'ROM CRC32 line')
    s.done()

    s = Scenario('H16', 'a Memory (extra bytes after the blob) reads like a sleep state')
    path = make_sta(tmp, 'h16.sta', dg(held=0), extra=52760)
    rc, out, err = run(path)
    tool_ok(s, rc, err)
    s.has(line(out, 'size'), 'a sleep state or Memory', 'size line')
    s.eq(field(out, 'last load'), 'RESTORED -- flash and machine state; a cold start after this '
         'came from something later, such as a power-off', 'last load')
    s.done()


def rc5_writer_and_frozen(tmp):
    boot, state = 'boot or late delivery: ', 'savestate load: '

    # ---- F: word 21's high byte is the writer revision ------------------
    s = Scenario('F1', 'writer revision 0 (every writer before rc5): "older writer (rev 0)", sub-code intact')
    path, _, _ = make_v4(tmp, 'f1.sav', diag_words(drain=32512, beats=65024 & 0xFFFF, word23=0x8001),
                         w21=word21(0))
    rc, out, err = run(path)
    tool_ok(s, rc, err)
    s.eq(line(out, 'writer'), WRITER_OLD, 'writer line')
    s.has(line(out, 'writer'), SPEC_OLD, 'spec phrase')
    s.has(line(out, 'cartridge'), 'catalogue 0067-03', 'cartridge')
    s.done()

    s = Scenario('F2', 'writer revision 5: "written by 1.1.0-rc5 or later"; the high byte stays out of the sub-code')
    path, _, _ = make_v4(tmp, 'f2.sav', diag_words(drain=32512, beats=65024 & 0xFFFF, word23=0x8001),
                         w21=word21(5))
    rc, out, err = run(path)
    tool_ok(s, rc, err)
    s.eq(line(out, 'writer'), WRITER_RC5, 'writer line')
    s.has(line(out, 'writer'), SPEC_RC5, 'spec phrase')
    s.eq(line(out, 'cartridge'), 'cartridge       : "CARD FIGHT E"   catalogue 0067-03', 'cartridge')
    s.check(len([ln for ln in out if ln.startswith('writer ')]) == 1, 'exactly one writer line')
    s.done()

    split = [
        # id,    word 21, catalogue suffix, writer phrase
        ('F3a', 0x05FF, '0067-FF', 'written by 1.1.0-rc5 (rev 5)'),
        ('F3b', 0x0500, '0067-00', 'written by 1.1.0-rc5 (rev 5)'),
        ('F3c', 0x00FF, '0067-FF', 'older writer (rev 0)'),
        ('F3d', 0xFF05, '0067-05', 'written by 1.1.0-rc6 or later (rev 255'),
    ]
    for sid, w21, cat, phrase in split:
        s = Scenario(sid, 'word 21 = %04X: high byte is the writer, low byte the catalogue sub-code' % w21)
        path, _, _ = make_v4(tmp, 'f3.sav', diag_words(word23=0x0001), w21=w21)
        rc, out, err = run(path)
        tool_ok(s, rc, err)
        s.eq(line(out, 'cartridge'), 'cartridge       : "CARD FIGHT E"   catalogue %s' % cat, 'cartridge')
        s.has(line(out, 'writer'), phrase, 'writer line')
        s.done()

    for sid, rev in (('F4a', 7), ('F4b', 255)):
        s = Scenario(sid, 'writer revision %d: rc6 or later, and the tool says it is newer than it knows' % rev)
        path, _, _ = make_v4(tmp, 'f4.sav', diag_words(word23=0x0001), w21=word21(rev))
        rc, out, err = run(path)
        tool_ok(s, rc, err)
        s.eq(line(out, 'writer'),
             'writer          : written by 1.1.0-rc6 or later (rev %d, newer than this tool knows)' % rev,
             'writer line')
        # Newer than rc5 is also later than rc4: the rc4 decode applies.
        s.eq(line(out, 'ingest split'), 'ingest split    : delivery 32512 beats | drain 0 beats',
             'split line (no old-core note on a rc5+ file)')
        s.check((field(out, 'last apply') or '').startswith(boot + 'ACCEPTED'),
                'last apply: %r' % field(out, 'last apply'))
        s.done()

    # Revisions 1-4 were never written by any core: reported as unknown, and
    # not taken as evidence of rc4 or later -- the old decode is kept.
    for sid, rev in (('F5a', 1), ('F5b', 4)):
        s = Scenario(sid, 'writer revision %d: unknown, and no evidence of rc4 or later' % rev)
        path, _, _ = make_v4(tmp, 'f5.sav', diag_words(word23=0x0001), w21=word21(rev))
        rc, out, err = run(path)
        tool_ok(s, rc, err)
        s.has(line(out, 'writer'), 'unknown writer revision %d' % rev, 'writer line')
        s.check(SPEC_RC5 not in (line(out, 'writer') or ''), 'claims rc5: %r' % line(out, 'writer'))
        s.eq(line(out, 'ingest split'),
             'ingest split    : delivery 32512 beats | drain 0 beats  ' + OLD_CORE_NOTE, 'split line')
        s.has(field(out, 'last apply'), 'ACCEPTED -- the save matched this cartridge; the flash writes count',
              'last apply')
        s.done()

    # Word 21 is stamped on every build, so the writer line is not tied to
    # the diagnostics or to the layout.
    shapes = [
        ('F6a', 'V2 (1.0.2 layout) with old diagnostics',
         lambda: make_v2(tmp, 'f6a.sav', diag_words(word23=1))),
        ('F6b', 'V4 without diagnostics',
         lambda: make_v4(tmp, 'f6b.sav', {})[0]),
        ('F6c', 'V2 written before 1.0.2 (no stamp, word 21 = 0)',
         lambda: make_v2(tmp, 'f6c.sav', {}, w21=0, title=GARBLED, catalogue=0x4197)),
        ('F6d', 'V4 without diagnostics, revision 5',
         lambda: make_v4(tmp, 'f6d.sav', {}, w21=word21(5))[0]),
    ]
    for sid, what, build in shapes:
        s = Scenario(sid, 'writer line on %s' % what)
        rc, out, err = run(build())
        tool_ok(s, rc, err)
        s.eq(line(out, 'writer'), WRITER_RC5 if sid == 'F6d' else WRITER_OLD, 'writer line')
        if sid in ('F6b', 'F6c', 'F6d'):
            s.eq(line(out, 'diagnostics'),
                 'diagnostics     : none recorded (build without save diagnostics)', 'diagnostics line')
        if sid == 'F6c':
            s.eq(line(out, 'cartridge'),
                 'cartridge       : (not stamped -- written by a core older than 1.0.2)', 'cartridge')
        s.done()

    # F17: pre-1.0 development builds left junk in word 21's high byte of
    # their V2 files. Only a V4 file can carry a writer revision, so a V2
    # file must read as an older writer and keep the old diagnostics decode.
    s = Scenario('F17', 'V2 file with junk (0x7F) in word 21 high byte: older writer, old decode')
    rc, out, err = run(make_v2(tmp, 'f17.sav', diag_words(word23=1), w21=word21(0x7F)))
    tool_ok(s, rc, err)
    s.eq(line(out, 'writer'), WRITER_OLD, 'writer line')
    s.eq(line(out, 'diagnostics'), old_diag_line(32512, 0, 1, 'ACCEPTED', 0), 'old-style diagnostics line')
    s.done()

    s = Scenario('F7', 'not a janisc.NGPC save: the magic line and exit 1, no writer line')
    path = os.path.join(tmp, 'f7.sav')
    with open(path, 'wb') as f:
        f.write(b'\x00' * SLOT_BYTES)
    rc, out, err = run(path)
    s.eq(rc, 1, 'exit code')
    s.check(not err, 'stderr: %s' % err.strip())
    s.has(line(out, 'magic'), '<-- NOT a janisc.NGPC save', 'magic')
    s.eq(line(out, 'writer'), None, 'writer line')
    s.eq(len(out), 3, 'line count')
    s.done()

    # ---- the writer revision is evidence of rc4 or later ----------------
    # Before rc5 an accepted boot apply with no drains and fail_idx 0 left
    # nothing to tell rc4 from rc3 (B1/V4 still reads it the old way). With
    # revision 5 in word 21 the file says so, and the rc4 decode applies.
    s = Scenario('F8', 'rev 5, word 23 = 0001, no drains: rc4 decode (origin, no old-core note); rev 0 keeps the old one')
    d = diag_words(beats=32512, drain=0, applies=1, word23=0x0001, p2wr=16384)
    path, _, _ = make_v4(tmp, 'f8.sav', d, w21=word21(5))
    rc, out, err = run(path)
    tool_ok(s, rc, err)
    s.eq(line(out, 'diagnostics'), old_diag_line(32512, 0, 1, 'ACCEPTED', 16384), 'diagnostics line')
    s.eq(line(out, 'ingest split'), 'ingest split    : delivery 32512 beats | drain 0 beats', 'split line')
    s.eq(field(out, 'last apply'),
         boot + 'ACCEPTED -- the save matched this cartridge and was written into its flash', 'last apply')
    s.eq(line(out, 'failed check'), None, 'failed check line')
    path, _, _ = make_v4(tmp, 'f8o.sav', d, w21=word21(0))
    rc, out, err = run(path)
    tool_ok(s, rc, err)
    s.eq(line(out, 'ingest split'),
         'ingest split    : delivery 32512 beats | drain 0 beats  ' + OLD_CORE_NOTE, 'control: split line')
    s.has(field(out, 'last apply'), 'ACCEPTED -- the save matched this cartridge; the flash writes count',
          'control: last apply')
    s.done()

    s = Scenario('F9', 'rev 5, word 23 = 0002: the rc4 label "REJECTED (coverage)"; rev 0 keeps "REJECTED"')
    d = diag_words(beats=32512, drain=0, applies=2, word23=0x0002, p2wr=0)
    path, _, _ = make_v4(tmp, 'f9.sav', d, w21=word21(5))
    rc, out, err = run(path)
    tool_ok(s, rc, err)
    s.eq(line(out, 'diagnostics'), old_diag_line(32512, 0, 2, 'REJECTED (coverage)', 0), 'diagnostics line')
    s.has(field(out, 'last apply'), "REJECTED -- the savestate's save lacks a block", 'last apply')
    path, _, _ = make_v4(tmp, 'f9o.sav', d, w21=word21(0))
    rc, out, err = run(path)
    tool_ok(s, rc, err)
    s.eq(line(out, 'diagnostics'), old_diag_line(32512, 0, 2, 'REJECTED', 0), 'control: diagnostics line')
    s.done()

    s = Scenario('F10', 'rev 5, word 23 = 0000, no applies: "none yet", no origin, no old-core note')
    path, _, _ = make_v4(tmp, 'f10.sav', diag_words(beats=32512, drain=0, applies=0, word23=0),
                         w21=word21(5))
    rc, out, err = run(path)
    tool_ok(s, rc, err)
    s.eq(line(out, 'diagnostics'), old_diag_line(32512, 0, 0, 'none', 0), 'diagnostics line')
    s.eq(line(out, 'ingest split'), 'ingest split    : delivery 32512 beats | drain 0 beats', 'split line')
    s.check((field(out, 'last apply') or '').startswith('none yet -- nothing has been applied'),
            'last apply: %r' % field(out, 'last apply'))
    s.done()

    # ---- verdict 7: a savestate from a frozen session (S11) -------------
    s = Scenario('F11', 'verdict 7 from a savestate load: label, the spec line, no failed check')
    path, _, _ = make_v4(tmp, 'f11.sav', diag_words(beats=65024 & 0xFFFF, drain=32512, applies=2,
                                                    word23=0x8007, p2wr=0), w21=word21(5))
    rc, out, err = run(path)
    tool_ok(s, rc, err)
    s.eq(line(out, 'diagnostics'), old_diag_line(65024, 0, 2, 'FROZEN STATE', 0), 'diagnostics line')
    s.eq(line(out, 'ingest split'), 'ingest split    : delivery 32512 beats | drain 32512 beats', 'split line')
    s.eq(field(out, 'last apply'), state + FROZEN_TEXT, 'last apply')
    s.has(field(out, 'last apply'), SPEC_V7, 'spec phrase')
    s.eq(line(out, 'failed check'), None, 'failed check line')
    s.done()

    s = Scenario('F12', 'verdict 7 in a file with no writer revision and no drains still reads as frozen')
    path, _, _ = make_v4(tmp, 'f12.sav', diag_words(beats=32512, drain=0, applies=1, word23=0x8007, p2wr=0))
    rc, out, err = run(path)
    tool_ok(s, rc, err)
    s.eq(line(out, 'writer'), WRITER_OLD, 'writer line')
    s.eq(line(out, 'diagnostics'), old_diag_line(32512, 0, 1, 'FROZEN STATE', 0), 'diagnostics line')
    s.eq(field(out, 'last apply'), state + FROZEN_TEXT, 'last apply')
    s.eq(line(out, 'ingest split'), 'ingest split    : delivery 32512 beats | drain 0 beats',
         'split line (no old-core note on a code-7 file)')
    s.done()

    # fail_idx means nothing for verdict 7 (nothing was read): never a
    # "failed check" line, even when bits 13:8 are not zero.
    s = Scenario('F13', 'verdict 7 with fail_idx 5: no failed check line')
    path, _, _ = make_v4(tmp, 'f13.sav', diag_words(beats=32512, drain=0, applies=1, word23=0x8507, p2wr=0),
                         w21=word21(5))
    rc, out, err = run(path)
    tool_ok(s, rc, err)
    s.eq(line(out, 'diagnostics'), old_diag_line(32512, 0, 1, 'FROZEN STATE', 0), 'diagnostics line')
    s.eq(line(out, 'failed check'), None, 'failed check line')
    s.done()

    s = Scenario('F14', 'verdict 7 with the reserved bit set: frozen line plus the reserved-bit note')
    path, _, _ = make_v4(tmp, 'f14.sav', diag_words(beats=32512, drain=0, applies=1, word23=0xC007, p2wr=0),
                         w21=word21(5))
    rc, out, err = run(path)
    tool_ok(s, rc, err)
    la = field(out, 'last apply')
    s.check(la is not None and la.startswith(state + FROZEN_TEXT), 'last apply: %r' % la)
    s.has(la, 'reserved bit set', 'reserved-bit note')
    s.done()

    # S11 is served by state applies only, so from_state should be 1; a file
    # that says otherwise still gets the verdict decoded.
    s = Scenario('F15', 'verdict 7 without from_state: still the frozen label and line')
    path, _, _ = make_v4(tmp, 'f15.sav', diag_words(beats=32512, drain=0, applies=1, word23=0x0007, p2wr=0))
    rc, out, err = run(path)
    tool_ok(s, rc, err)
    s.eq(line(out, 'diagnostics'), old_diag_line(32512, 0, 1, 'FROZEN STATE', 0), 'diagnostics line')
    s.has(field(out, 'last apply'), SPEC_V7, 'last apply')
    s.check('not known to this tool' not in (field(out, 'last apply') or ''), 'code 7 read as unknown')
    s.done()

    # The whole report of an rc5 file, line for line: order, the one writer
    # line right under the magic, the frozen verdict, the blank line.
    s = Scenario('F16', 'full report of an rc5 frozen-session file, line for line')
    path, _, _ = make_v4(tmp, 'f16.sav', diag_words(beats=65024 & 0xFFFF, drain=32512, applies=2,
                                                    word23=0x8007, p2wr=0), w21=word21(5))
    rc, out, err = run(path)
    tool_ok(s, rc, err)
    want = [
        'size            : 65024 bytes',
        'magic           : ok (NGPCSAV4)',
        WRITER_RC5,
        'cartridge       : "CARD FIGHT E"   catalogue 0067-03',
        'ROM CRC32       : 94B63A97   (identifies the exact ROM this belongs to)',
        'ROM size        : 2097152 bytes (16 Mbit)',
        'saved blocks    : die0/32, die0/33, die0/34',
        'packed payload  : 1047 words (2094 bytes) for 32768 bytes of flash -- 6%',
        'payload checksum: 89265305 ok',
        '   die0 block 32   8192 bytes : has data (25% written)',
        '   die0 block 33   8192 bytes : ERASED (no data)',
        '   die0 block 34  16384 bytes : has data (1% written)',
        'diagnostics     : ingest 65024 beats / 0 drops | applies 2 | verdict FROZEN STATE | flash writes 0',
        'ingest split    : delivery 32512 beats | drain 32512 beats',
        'last apply      : savestate load: FROZEN STATE -- savestate from a frozen session: nothing applied,',
        '                  saving stays off; the savestate itself loaded, and flash was not touched',
        '',
        'VERDICT: looks like a real save.',
    ]
    compare(s, out, want)
    s.done()


def compare(s, out, want):
    """out without its 'file' line must equal want, line for line."""
    s.check(bool(out) and out[0].startswith('file            : '), 'first line: %r' % out[:1])
    got = out[1:]
    for i in range(max(len(got), len(want))):
        g = got[i] if i < len(got) else '<missing>'
        w = want[i] if i < len(want) else '<missing>'
        if g != w:
            s.errs.append('line %d: got %r, want %r' % (i + 2, g, w))
            break
    s.eq(len(got), len(want), 'line count after the file line')


# What the rc4 tool (git fffda1a) printed for these files, line for line.
# rc5 adds exactly one line -- the writer, under the magic -- and changes
# nothing else. The early exits (V3, a newer tag) print no writer line.
RC4_REPORTS = {
    'G1': [
        'size            : 65024 bytes',
        'magic           : ok (NGPCSAV4)',
        'cartridge       : "CARD FIGHT E"   catalogue 0067-03',
        'ROM CRC32       : 94B63A97   (identifies the exact ROM this belongs to)',
        'ROM size        : 2097152 bytes (16 Mbit)',
        'saved blocks    : die0/32, die0/33, die0/34',
        'packed payload  : 1047 words (2094 bytes) for 32768 bytes of flash -- 6%',
        'payload checksum: 89265305 ok',
        '   die0 block 32   8192 bytes : has data (25% written)',
        '   die0 block 33   8192 bytes : ERASED (no data)',
        '   die0 block 34  16384 bytes : has data (1% written)',
        'diagnostics     : ingest 65024 beats / 0 drops | applies 2 | verdict REFUSED (bad checksum) | flash writes 9',
        'ingest split    : delivery 32512 beats | drain 32512 beats',
        'last apply      : savestate load: REFUSED -- the payload checksum did not match (the image is',
        '                  damaged), so none of it reached flash',
        'failed check    : header word 19 (payload checksum)',
        '',
        'VERDICT: looks like a real save.',
    ],
    'G2': [
        'size            : 65024 bytes',
        'magic           : ok (NGPCSAV2  -- pre-1.1 layout, uncompressed)',
        'cartridge       : "CARD FIGHT E"   catalogue 0067-03',
        'ROM CRC32       : 94B63A97   (identifies the exact ROM this belongs to)',
        'ROM size        : 2097152 bytes (16 Mbit)',
        'saved blocks    : die0/32, die0/33, die0/34',
        '   die0 block 32   8192 bytes : has data (25% written)',
        '   die0 block 33   8192 bytes : ERASED (no data)',
        '   die0 block 34  16384 bytes : has data (1% written)',
        'diagnostics     : ingest 32512 beats / 3 drops | applies 1 | verdict ACCEPTED | flash writes 77',
        'ingest split    : delivery 32512 beats | drain 0 beats  (cores before 1.1.0-rc4 count drains as delivery)',
        'last apply      : ACCEPTED -- the save matched this cartridge; the flash writes count shows how much',
        '                  of it was written',
        '',
        'VERDICT: looks like a real save.',
    ],
    'G3': [
        'size            : 65024 bytes',
        'magic           : ok (NGPCSAV2  -- pre-1.1 layout, uncompressed)',
        'cartridge       : (not stamped -- written by a core older than 1.0.2)',
        'ROM CRC32       : 94B63A97   (identifies the exact ROM this belongs to)',
        'ROM size        : 2097152 bytes (16 Mbit)',
        'saved blocks    : die0/32, die0/33, die0/34',
        '   die0 block 32   8192 bytes : has data (25% written)',
        '   die0 block 33   8192 bytes : ERASED (no data)',
        '   die0 block 34  16384 bytes : has data (1% written)',
        'diagnostics     : none recorded (build without save diagnostics)',
        '',
        'VERDICT: looks like a real save.',
    ],
    'G4': [
        'size            : 65024 bytes',
        'magic           : ok (NGPCSAV4)',
        'cartridge       : "CARD FIGHT E"   catalogue 0067-03',
        'ROM CRC32       : 94B63A97   (identifies the exact ROM this belongs to)',
        'ROM size        : 2097152 bytes (16 Mbit)',
        'saved blocks    : die0/32, die0/33, die0/34',
        'packed payload  : 1047 words (2094 bytes) for 32768 bytes of flash -- 6%',
        'payload checksum: 89265305 MISMATCH, computed BAB8C80E  <-- the file is damaged',
        '   die0 block 32   8192 bytes : has data (25% written)',
        '   die0 block 33   8192 bytes : ERASED (no data)',
        '   die0 block 34  16384 bytes : has data (1% written)',
        'diagnostics     : none recorded (build without save diagnostics)',
        '',
        'VERDICT: THIS FILE IS DAMAGED. Its own checksum does not match its',
        '         contents, so the core will refuse it rather than write',
        '         nonsense into the cartridge. Keep the file: an older copy',
        '         or a backup is the only way back.',
    ],
    'G5': [
        'size            : 65024 bytes',
        'magic           : NGPCSAV3 -- written by the PR #5 test build, not this core;',
        '                  this core refuses it and leaves it on the card',
    ],
    'G6': [
        'size            : 65024 bytes',
        "magic           : ok, but version '9' is from a newer core",
    ],
}


def rc4_output_unchanged(tmp):
    # ---- G: everything rc4 printed, rc5 still prints --------------------
    cases = [
        # id,  what,                                           exit, build
        ('G1', 'rc4 savestate refusal (V4, drains, word 23 = 9303)', 0,
         lambda: make_v4(tmp, 'g1.sav', diag_words(beats=65024 & 0xFFFF, drain=32512, applies=2,
                                                   word23=0x9303, p2wr=9))[0]),
        ('G2', '1.0.2 / rc3 file (V2, old diagnostics)', 0,
         lambda: make_v2(tmp, 'g2.sav', diag_words(beats=32512, drops=3, applies=1, word23=1, p2wr=77))),
        ('G3', 'file from before 1.0.2 (no stamp, no diagnostics)', 0,
         lambda: make_v2(tmp, 'g3.sav', {}, w21=0, title=GARBLED, catalogue=0x4197)),
        ('G4', 'damaged V4 file without diagnostics', 0,
         lambda: make_v4(tmp, 'g4.sav', {}, corrupt=True)[0]),
        ('G5', 'PR #5 test-build file (V3): early exit', 1,
         lambda: make_tagged(tmp, 'g5.sav', '3')),
        ('G6', 'file with a newer format tag (V9): early exit', 1,
         lambda: make_tagged(tmp, 'g6.sav', '9')),
    ]
    for sid, what, code, build in cases:
        s = Scenario(sid, 'rc4 report unchanged but for the writer line: %s' % what)
        rc, out, err = run(build())
        s.eq(rc, code, 'exit code')
        s.check(not err, 'stderr: %s' % err.strip())
        want = list(RC4_REPORTS[sid])
        if code == 0:
            want.insert(2, WRITER_OLD)      # right under the magic line
        compare(s, out, want)
        s.done()


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
            # rc5 defines code 7 (group F), so the first code this tool does
            # not know is now 8: it still prints raw and says so.
            ('C7', 0x0008, 0, 1, '8 (word 23 = 0008)', 'verdict code 8 is not known to this tool', None),
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

        rc5_writer_and_frozen(tmp)
        rc4_output_unchanged(tmp)
        rc6_additions(tmp)

    total = passes + failures
    if failures:
        print('== %d FAILURE(S) of %d savinfo scenarios' % (failures, total))
        return 1
    print('== ALL %d savinfo scenarios PASS' % total)
    return 0


if __name__ == '__main__':
    sys.exit(main())
