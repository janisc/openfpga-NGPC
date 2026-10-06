#!/usr/bin/env python3
"""rc6 family F: checks on what sim/tb_rc6f_stamp.sv and sim/tb_rc6f_held.sv
wrote. No dependencies.

    python3 sim/tb_rc6f_check.py sta <hexdir> <stadir>
        Every capture <hexdir>/g<group>_<name>.hex (24680 words, one per
        line) is written out as a sleep state / Memory in the Pocket's .sta
        layout -- a 592-byte header, then the blob as big-endian 32-bit
        words -- and decoded with tools/savinfo.py exactly as a user would
        (python3 tools/savinfo.py <file>). Word 8419 is checked against the
        value the scenario's meaning implies (the table below, written from
        the rc6 field list, not from the bench), and savinfo's lines against
        that meaning, word for word in tools/savinfo.py's 1.1.0 wording
        (last_text below follows it): which load it says ended how, the load
        count, the timing, the layout, the heading over the embedded image,
        the cartridge, and the save image underneath.

    python3 sim/tb_rc6f_check.py held <hexdir> <stadir>
        The same for sim/tb_rc6f_held.sv's captures <hexdir>/<name>.hex (the
        real bridge, copier and save engine; cartridge CRC 600DCA57).

    python3 sim/tb_rc6f_check.py cmp <logdir> <hexdir6> <hexdir5>
        The rc5 comparison: for every group, the decision lines (RC6F DEC)
        of the rc6 and rc5 builds must be identical, the capture lines
        (RC6F CAP) identical but for word 8419, every captured blob
        identical word for word but for 8419, and the rc5 build's own
        failures must all be word-8419 failures.

    python3 sim/tb_rc6f_check.py show <hexdir> <stadir>
        Every <hexdir>/*.hex through savinfo, its load lines printed; nothing
        is judged.

Each judging mode ends with one line, "== RC6F CHECK <mode>: ALL PASS (...)"
or "== RC6F CHECK <mode>: N FAILURE(S)", and exits non-zero on a failure.
"""
import glob
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SAVINFO = os.path.join(ROOT, 'tools', 'savinfo.py')

WORDS = 24680
STA_OFF = 592
PAD_DIAG = 8419
CRC_STAMP = 0x94B63A97     # tb_rc6f_stamp's cartridge (tb_rc6f_mkimg.py)
CRC_HELD = 0x600DCA57      # tb_rc5_loadpath's CRC_A
TIMEOUT_S = 60

# The identity terms in word 8419's bit order (bit 17 first) and savinfo's
# words for them.
TERMS = ('full', 'magic', 'crc', 'layout', 'ncrc')
TERM_TEXT = {
    'full': 'the transfer reached the end of the savestate',
    'magic': 'the identity magic (a savestate of this core)',
    'crc': 'the cartridge (ROM CRC)',
    'layout': 'the layout',
    'ncrc': 'the identity check word',
}

# name: (loads, how the last load ended, identity terms that failed,
#        loaded state frozen, the boot hold at the check, capture layout)
# none: no load since reset; id: refused at the identity gate; timeout:
# the copier's timeout; apply: drained, the apply refused; engine: started,
# the engine refused the header; restored.
R, N = 'restored', 'none'
TABLE = {
    'A0': (0, N, (), 0, 0, 2),
    'A1': (0, N, (), 0, 0, 3),
    'F1': (1, R, (), 0, 0, 2),
    'F1b': (1, R, (), 0, 0, 3),
    'F2': (1, R, (), 0, 1, 2),
    'F3': (1, R, (), 1, 0, 2),
    'E1': (1, 'engine', (), 0, 0, 3),
    'D1': (1, 'apply', (), 0, 0, 3),
    'D2': (1, 'apply', (), 1, 0, 3),
    'C1': (1, 'timeout', (), 0, 0, 3),
    'C2': (1, 'timeout', (), 0, 0, 2),
    'C3': (1, 'timeout', (), 0, 0, 2),
    'C4': (1, 'timeout', (), 1, 0, 3),
    'B1': (1, 'id', ('full',), 0, 0, 2),
    'B2': (1, 'id', ('magic',), 0, 0, 3),
    'B3': (1, 'id', ('crc',), 0, 0, 2),
    'B4': (1, 'id', ('layout',), 0, 0, 3),
    'B4c': (1, 'id', ('layout',), 0, 0, 2),
    'B5': (1, 'id', ('ncrc',), 0, 0, 2),
    'B6': (1, 'id', TERMS, 0, 0, 2),
    'B7': (1, 'id', ('crc', 'ncrc'), 0, 0, 2),
    'B8': (1, 'id', ('magic',), 0, 0, 2),
    'H1': (1, 'id', ('magic',), 0, 1, 2),
    'H2': (1, 'id', ('magic',), 0, 0, 2),
    'H3': (1, R, (), 0, 0, 2),
    'H4': (1, R, (), 0, 1, 2),
    'H5': (1, 'timeout', (), 0, 1, 3),
    'H6': (1, 'id', ('magic',), 0, 0, 2),
    'H7': (1, R, (), 0, 0, 2),
    'Q1': (1, R, (), 0, 1, 2),
    'Q2': (2, 'id', ('full',), 0, 0, 2),
    'Q3': (3, R, (), 0, 0, 2),
    'Q4': (4, 'timeout', (), 0, 0, 3),
    'Q5': (5, 'apply', (), 0, 0, 3),
    'Q6': (6, 'engine', (), 0, 0, 3),
    'Q7': (7, R, (), 1, 0, 2),
    'Q8': (8, 'id', ('magic',), 0, 0, 2),
    'Q14': (14, 'id', ('full',), 0, 0, 2),
    'Q15': (15, 'id', ('full',), 0, 0, 2),
    'Q16': (15, R, (), 0, 1, 2),
    'Q17': (15, 'id', ('full',), 0, 0, 2),
    'Q18': (0, N, (), 0, 0, 2),
    'S1': (1, R, (), 0, 0, 2),
    'S2': (1, R, (), 0, 0, 2),
    'S3': (1, R, (), 0, 0, 2),
    'S4': (1, R, (), 0, 0, 2),
    'S5': (1, 'id', ('magic',), 0, 0, 2),
}

# sim/tb_rc6f_held.sv. HELD-LATE is the session's second load (HELD-IDLE
# first); C3-REAL's timeout fails a wake-shaped load, which freezes the
# session (S1c), so its capture is layout 3.
HELD_TABLE = {
    'HELD-IDLE': (1, R, (), 0, 0, 2),
    'HELD-LATE': (2, R, (), 0, 0, 2),
    'HELD-EARLY': (1, R, (), 0, 1, 2),
    'C3-REAL': (1, 'timeout', (), 0, 0, 3),
}

# savinfo's texts, as tools/savinfo.py words them for 1.1.0
SINCE = 'since the core started or was last reset from the menu'
NONE_TEXT = 'none -- no savestate load ' + SINCE
LAYOUT_TEXT = {2: '2 (normal)',
               3: '3 -- captured while saving was off: the image below is the file the core '
                  'refused, not a save'}
CARRY_TEXT = {2: 'The save image this state carries (loading the state restores it):',
              3: 'The file this state carries (loading the state applies nothing; saving stays off):'}
HELD_TEXT = 'arrived while the core was still starting up (the boot apply held the machine)'
FREE_TEXT = 'arrived after startup, with the game already running'


def loads_text(loads):
    return '%d%s savestate load(s) %s' % (loads, ' or more' if loads == 15 else '', SINCE)


def last_text(kind, failed, frozen):
    if kind == 'id':
        return ('REFUSED at the identity check (failed: %s); the machine was not touched'
                % ', '.join(TERM_TEXT[t] for t in TERMS if t in failed))
    if kind == 'timeout':
        return 'FAILED -- the copier timed out waiting for the save engine; nothing was restored'
    if kind == 'apply':
        return ("REFUSED -- the save engine refused the state's save image; nothing was restored, "
                'and the game restarted because the check runs with the machine already stopped '
                '(a Memory also reports "Loading failed")')
    if kind == 'engine':
        return ('REFUSED -- the savestate engine refused the machine-state header, so the machine '
                'was not restored' + ('' if frozen else
                                      "; flash had already been restored from the state's save "
                                      'image, or left as it was if the state carried none'))
    if frozen:
        return ('RESTORED -- machine state only: the state was captured while saving was off, so '
                'flash was left as it was and saving stays off')
    return ("RESTORED -- the machine state; flash restored from the state's save image, or left "
            'as it was if the state carried none. A cold start after this came from something '
            'later, such as a power-off')


def expected_word(loads, kind, failed, frozen, held):
    if kind == N:
        return 0xD1000000 | (loads << 20)
    ran = kind in ('engine', R)
    ok = kind == R
    drained = kind in ('apply', 'engine', R)
    chk = 0
    for i, t in enumerate(TERMS):
        if t not in failed:
            chk |= 1 << (4 - i)
    return ((0xD1 << 24) | (loads << 20) | (ran << 19) | (ok << 18) | (chk << 13) |
            (frozen << 12) | (drained << 11) | (held << 10))


def read_hex(path):
    words = []
    for ln in open(path):
        ln = ln.strip()
        if not ln or ln.startswith('//') or ln.startswith('@'):
            continue
        words.append(int(ln, 16))
    return words


def write_sta(words, path):
    blob = b''.join((w & 0xFFFFFFFF).to_bytes(4, 'big') for w in words)
    with open(path, 'wb') as f:
        f.write(b'\x01SPA' + b'\x00' * (STA_OFF - 4) + blob + b'\x00' * 4)


def field(lines, label):
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


def name_of(path):
    m = re.match(r'g(\d+)_(.+)\.hex$', os.path.basename(path))
    return (int(m.group(1)), m.group(2)) if m else (None, None)


def savinfo(words, sta):
    write_sta(words, sta)
    try:
        r = subprocess.run([sys.executable, SAVINFO, sta], capture_output=True,
                           text=True, timeout=TIMEOUT_S)
        rc, out, err = r.returncode, r.stdout.splitlines(), r.stderr
    except subprocess.TimeoutExpired:
        rc, out, err = -1, [], 'savinfo.py ran longer than %d s' % TIMEOUT_S
    with open(sta + '.txt', 'w') as f:
        f.write('\n'.join(out) + '\n')
    return rc, out, err


def judge(words, sta, entry, crc):
    """(errors, savinfo lines) for one capture against its table entry."""
    loads, kind, failed, frozen, held, layout = entry
    errs = []
    if len(words) != WORDS:
        errs.append('%d words, want %d' % (len(words), WORDS))
    want = expected_word(loads, kind, failed, frozen, held)
    if len(words) > PAD_DIAG and words[PAD_DIAG] != want:
        errs.append('word 8419 = %08X, the table says %08X' % (words[PAD_DIAG], want))
    if len(words) > 8422 and words[8422] != layout:
        errs.append('identity layout word %d, the table says %d' % (words[8422], layout))
    rc, out, err = savinfo(words, sta)
    if rc != 0 or err.strip():
        errs.append('savinfo exit %d, stderr %r' % (rc, err.strip()[-200:]))

    size = field(out, 'size') or ''
    if 'a sleep state or Memory' not in size:
        errs.append('not read as a savestate: size %r' % size)
    crcl = next((ln for ln in out if ln.startswith('ROM CRC32       : ')), '')
    if not crcl.startswith('ROM CRC32       : %08X' % crc) or 'MISMATCH' in crcl:
        errs.append('state ROM CRC line %r' % crcl)
    lay = field(out, 'layout') or ''
    if lay != LAYOUT_TEXT[layout]:
        errs.append('layout %r, want %r' % (lay, LAYOUT_TEXT[layout]))
    if CARRY_TEXT[layout] not in out or CARRY_TEXT[5 - layout] in out:
        errs.append('the heading over the embedded image is not %r' % CARRY_TEXT[layout])

    last = field(out, 'last load') or ''
    cnt = field(out, 'loads before it')
    tim = field(out, 'load timing')
    if kind == N:
        if last != NONE_TEXT:
            errs.append('last load %r, want %r' % (last, NONE_TEXT))
        if cnt is not None or tim is not None:
            errs.append('a count or timing line for a session with no load')
    else:
        want_last = last_text(kind, failed, frozen)
        if last != want_last:
            errs.append('last load %r, want %r' % (last, want_last))
        if cnt != loads_text(loads):
            errs.append('loads line %r, want %r' % (cnt, loads_text(loads)))
        want_tim = HELD_TEXT if held else FREE_TEXT
        if tim != want_tim:
            errs.append('load timing %r, want %r' % (tim, want_tim))

    # the save image underneath decodes as the real save it is
    if not any(ln.startswith('payload checksum:') and ln.endswith(' ok') for ln in out):
        errs.append('embedded save image: payload checksum not ok')
    if not (out and out[-1].startswith('VERDICT: looks like a real save')):
        errs.append('embedded save image verdict %r' % (out[-1:] or ''))
    if field(out, 'writer') not in ('written by 1.1.0-rc6 or 1.1.0 (rev 6)', 'written by 1.1.1 or later (rev 7)'):
        errs.append('embedded writer %r' % field(out, 'writer'))
    return errs, out


def summary(out, entry):
    kind = entry[1]
    last = field(out, 'last load') or ''
    if kind == N:
        return last[:78]
    return '%s | %s | %s' % (last[:78], (field(out, 'loads before it') or '').split(' savestate')[0],
                             'held' if entry[4] else 'not held')


def mode_sta(hexdir, stadir):
    os.makedirs(stadir, exist_ok=True)
    files = sorted(glob.glob(os.path.join(hexdir, 'g*_*.hex')))
    nfail, nok = 0, 0
    if not files:
        print('   FAIL: no captures in %s' % hexdir)
        nfail += 1
    seen = set()
    for hx in files:
        grp, name = name_of(hx)
        tag = 'g%s_%s' % (grp, name)
        if name not in TABLE:
            print('   FAIL %s: no expectation for %s' % (tag, name))
            nfail += 1
            continue
        seen.add(name)
        words = read_hex(hx)
        errs, out = judge(words, os.path.join(stadir, tag + '.sta'), TABLE[name], CRC_STAMP)
        w = words[PAD_DIAG] if len(words) > PAD_DIAG else 0
        if errs:
            nfail += 1
            print('   FAIL %-7s %08X: %s' % (tag, w, '; '.join(errs)))
        else:
            nok += 1
            print('   PASS %-7s %08X  last load: %s' % (tag, w, summary(out, TABLE[name])))
    missing = sorted(set(TABLE) - seen)
    if files and missing:
        nfail += 1
        print('   FAIL: no capture for %s' % ', '.join(missing))
    if nfail:
        print('== RC6F CHECK sta: %d FAILURE(S)' % nfail)
        return 1
    print('== RC6F CHECK sta: ALL PASS (%d captures decoded)' % nok)
    return 0


def mode_held(hexdir, stadir):
    os.makedirs(stadir, exist_ok=True)
    nfail, nok = 0, 0
    for name in sorted(HELD_TABLE):
        hx = os.path.join(hexdir, name + '.hex')
        if not os.path.exists(hx):
            nfail += 1
            print('   FAIL %-10s: no capture (%s)' % (name, hx))
            continue
        words = read_hex(hx)
        errs, out = judge(words, os.path.join(stadir, name + '.sta'), HELD_TABLE[name], CRC_HELD)
        w = words[PAD_DIAG] if len(words) > PAD_DIAG else 0
        if errs:
            nfail += 1
            print('   FAIL %-10s %08X: %s' % (name, w, '; '.join(errs)))
        else:
            nok += 1
            print('   PASS %-10s %08X' % (name, w))
        for label in ('layout', 'loads before it', 'last load', 'load timing'):
            print('        %-15s: %s' % (label, field(out, label)))
    if nfail:
        print('== RC6F CHECK held: %d FAILURE(S)' % nfail)
        return 1
    print('== RC6F CHECK held: ALL PASS (%d captures decoded)' % nok)
    return 0


def lines_of(path, tag):
    return [ln.rstrip('\n') for ln in open(path) if ln.startswith(tag)]


def mode_cmp(logdir, hex6, hex5):
    nfail, ndec, ncap, nblob = 0, 0, 0, 0
    for g in range(1, 7):
        l6 = os.path.join(logdir, 'rc6_g%d.log' % g)
        l5 = os.path.join(logdir, 'rc5_g%d.log' % g)
        if not (os.path.exists(l6) and os.path.exists(l5)):
            print('   FAIL group %d: missing log (%s, %s)' % (g, l6, l5))
            nfail += 1
            continue
        d6, d5 = lines_of(l6, 'RC6F DEC'), lines_of(l5, 'RC6F DEC')
        if d6 != d5 or not d6:
            nfail += 1
            print('   FAIL group %d: load decisions differ between rc6 and rc5' % g)
            for a, b in zip(d6, d5):
                if a != b:
                    print('      rc6: %s\n      rc5: %s' % (a, b))
            if len(d6) != len(d5):
                print('      %d decisions on rc6, %d on rc5' % (len(d6), len(d5)))
        ndec += len(d6)
        # 8419 is the rc6 load stamp, 8418 the 1.1.1 PSRAM report: rc5 has neither
        strip = lambda ls: [re.sub(r' w841[89]=[0-9a-fx]+', '', x) for x in ls]
        c6, c5 = lines_of(l6, 'RC6F CAP'), lines_of(l5, 'RC6F CAP')
        if strip(c6) != strip(c5) or not c6:
            nfail += 1
            print('   FAIL group %d: capture lines differ beyond words 8418/8419' % g)
            for a, b in zip(c6, c5):
                if strip([a]) != strip([b]):
                    print('      rc6: %s\n      rc5: %s' % (a, b))
        ncap += len(c6)
        # rc5's own failures: word 8419 only
        other = [ln for ln in open(l5) if ln.startswith('   FAIL') and ': word 8419 = ' not in ln]
        if other:
            nfail += 1
            print('   FAIL group %d: the rc5 build failed a check other than word 8419:' % g)
            for ln in other[:5]:
                print('      ' + ln.rstrip())
    for f6 in sorted(glob.glob(os.path.join(hex6, 'g*_*.hex'))):
        f5 = os.path.join(hex5, os.path.basename(f6))
        if not os.path.exists(f5):
            nfail += 1
            print('   FAIL %s: no rc5 capture' % os.path.basename(f6))
            continue
        w6, w5 = read_hex(f6), read_hex(f5)
        diff = [i for i in range(max(len(w6), len(w5)))
                if i not in (PAD_DIAG, PAD_DIAG - 1) and (i >= len(w6) or i >= len(w5) or w6[i] != w5[i])]
        nblob += 1
        if diff:
            nfail += 1
            print('   FAIL %s: %d words differ from rc5 besides 8418/8419 (first %s)' % (
                os.path.basename(f6), len(diff), diff[:6]))
        else:
            print('   same %-12s rc6 8419=%08X rc5 8419=%08X, 8420..8423 %08X %08X %08X %08X' % (
                os.path.basename(f6)[:-4], w6[PAD_DIAG], w5[PAD_DIAG], *w6[8420:8424]))
    if nfail:
        print('== RC6F CHECK cmp: %d FAILURE(S)' % nfail)
        return 1
    print('== RC6F CHECK cmp: ALL PASS (%d decisions, %d captures, %d blobs identical to rc5 but word 8419)'
          % (ndec, ncap, nblob))
    return 0


def mode_show(hexdir, stadir):
    """Write every <hexdir>/*.hex as a .sta and print what savinfo says of
    its last load; nothing is judged."""
    os.makedirs(stadir, exist_ok=True)
    for hx in sorted(glob.glob(os.path.join(hexdir, '*.hex'))):
        name = os.path.basename(hx)[:-4]
        words = read_hex(hx)
        rc, out, err = savinfo(words, os.path.join(stadir, name + '.sta'))
        print('   %-10s %08X savinfo exit %d' % (name, words[PAD_DIAG], rc))
        for label in ('loads before it', 'last load', 'load timing'):
            print('      %-15s: %s' % (label, field(out, label)))
    return 0


if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[1] == 'show':
        sys.exit(mode_show(sys.argv[2], sys.argv[3]))
    if len(sys.argv) == 4 and sys.argv[1] == 'sta':
        sys.exit(mode_sta(sys.argv[2], sys.argv[3]))
    if len(sys.argv) == 4 and sys.argv[1] == 'held':
        sys.exit(mode_held(sys.argv[2], sys.argv[3]))
    if len(sys.argv) == 5 and sys.argv[1] == 'cmp':
        sys.exit(mode_cmp(sys.argv[2], sys.argv[3], sys.argv[4]))
    print(__doc__)
    sys.exit(2)
