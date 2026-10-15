#!/usr/bin/env python3
"""expdiff.py <reference.dll> <ours.dll> — compare same-named exports.

For every export present in both DLLs, cut the function out (bounds: next
call target / export / symbol), normalise to a mnemonic sequence and score
similarity (difflib ratio on mnemonics, plus call-count delta). Functions the
reference changed stand out as low scores compared with the overall spread.
"""
import difflib, re, subprocess, sys
sys.path.insert(0, __file__.rsplit('/', 1)[0])
import importlib.util
spec = importlib.util.spec_from_file_location('fm', __file__.rsplit('/', 1)[0] + '/funcmatch.py')
fm = importlib.util.module_from_spec(spec); spec.loader.exec_module(fm)


def disasm(path):
    out = subprocess.run(['i686-w64-mingw32-objdump', '-d', '--no-show-raw-insn', path],
                         capture_output=True, text=True).stdout
    ins = []
    for l in out.splitlines():
        m = re.match(r'\s*([0-9a-f]+):\t(\S+)\s*(.*)', l)
        if m:
            ins.append((int(m.group(1), 16), m.group(2), m.group(3)))
    return ins


def functions(path):
    pe = fm.wu.PE(path)
    ex = fm.exports_of(pe)                      # va -> name
    ins = disasm(path)
    starts = set(ex)
    for a, mn, op in ins:
        if mn == 'call':
            m = re.match(r'([0-9a-f]+)\b', op)
            if m:
                starts.add(int(m.group(1), 16))
    starts = sorted(starts)
    import bisect
    addrs = [a for a, _, _ in ins]
    res = {}
    for va, name in ex.items():
        i = bisect.bisect_left(addrs, va)
        j = bisect.bisect_right(starts, va)
        end = starts[j] if j < len(starts) else va + 0x4000
        seq = []
        calls = 0
        k = i
        while k < len(ins) and ins[k][0] < end and len(seq) < 4000:
            mn = ins[k][1]
            seq.append(mn)
            calls += mn == 'call'
            k += 1
        res[name] = (va, seq, calls)
    return res


ref = functions(sys.argv[1])
ours = functions(sys.argv[2])
rows = []
for name in sorted(set(ref) & set(ours)):
    a, b = ref[name], ours[name]
    if len(a[1]) < 6 and len(b[1]) < 6:
        continue
    r = difflib.SequenceMatcher(None, a[1], b[1], autojunk=False).ratio()
    rows.append((r, name, len(a[1]), len(b[1]), a[2], b[2], a[0]))
rows.sort()
import statistics
print('compared %d exports; median ratio %.2f' % (len(rows), statistics.median(r[0] for r in rows)))
print('ratio  ref#ins ours#ins ref_calls ours_calls  name (ref va)')
for r, name, la, lb, ca, cb, va in rows[:int(sys.argv[3]) if len(sys.argv) > 3 else 40]:
    print('%.2f  %6d %6d   %4d %4d   %s (%x)' % (r, la, lb, ca, cb, name, va))
