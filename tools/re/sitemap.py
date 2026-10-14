#!/usr/bin/env python3
"""sitemap.py <wined3d.dll> <name=0xVA>... [--globals name=0xVA ...]

For each qemu-3dfx module function (given by address) list every call site,
and for each configuration global every instruction that reads it, together
with the enclosing function and the strings / imports that function uses —
enough to recognise which Wine source function the site lives in.
"""
import sys, re, subprocess, importlib.util, os
here = os.path.dirname(os.path.abspath(__file__))
def load(n, f):
    s = importlib.util.spec_from_file_location(n, os.path.join(here, '..', f))
    m = importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
wu = load('wu', 'win98-universe.py'); cd = load('cd', 'win98-calldiff.py')

path = sys.argv[1]
funcs, globs = {}, {}
target = funcs
for a in sys.argv[2:]:
    if a == '--globals':
        target = globs; continue
    n, v = a.split('='); target[n] = int(v, 16)

pe = wu.PE(path); iat = cd.iat_map(pe)
src = cd.sanitized_copy(path)
dis = subprocess.run([cd.OBJDUMP, '-d', '--no-show-raw-insn', src], capture_output=True, text=True).stdout
if src != path: os.unlink(src)
lines = []
for l in dis.splitlines():
    m = re.match(r'^\s*([0-9a-f]+):\s+(.*)$', l)
    if m: lines.append((int(m.group(1), 16), m.group(2).rstrip()))
idx = {a: i for i, (a, _) in enumerate(lines)}
thunks = {}
for a, t in lines:
    m = re.match(r'jmp\s+\*0x([0-9a-f]+)', t)
    if m and int(m.group(1), 16) in iat: thunks[a] = iat[int(m.group(1), 16)]
exports = {}
eo = pe.off(pe.dirs[0][0])
import struct
(_, _, _, _, _, _, nf, nn, af, an, ao) = struct.unpack_from('<IIHHIIIIIII', pe.d, eo)
for i in range(nn):
    exports[pe.imagebase + pe.u32(af + 4 * pe.u16(ao + 2 * i))] = pe.cstr(pe.u32(an + 4 * i))

def func_bounds(i):
    s = i
    while s > 0:
        t = lines[s][1]
        if t.startswith('push   %ebp') and s + 1 < len(lines) and lines[s + 1][1].startswith('mov    %esp,%ebp'):
            break
        if s < i and t.startswith(('ret', 'jmp ')) and lines[s + 1][1].startswith(('push', 'lea    0x4(%esp)', 'sub')):
            s += 1; break
        s -= 1
    e = i
    while e < len(lines) - 1 and not (lines[e][1].startswith('ret') and e > i + 2 and
                                      lines[e + 1][1].startswith(('push   %ebp', 'lea    0x4(%esp)', 'nop', 'lea    0x0', 'xchg'))):
        e += 1
    return s, e

def describe(s, e):
    strs, imps, calls_exp = [], set(), set()
    for j in range(s, e + 1):
        t = lines[j][1]
        for m in re.finditer(r'\$0x([0-9a-f]{7,8})', t):
            st = cd.string_at(pe, int(m.group(1), 16))
            if st and len(st) > 3 and st not in strs: strs.append(st)
        m = re.search(r'\*0x([0-9a-f]+)', t)
        if m and int(m.group(1), 16) in iat: imps.add(iat[int(m.group(1), 16)].split('!')[1])
        m = re.match(r'(?:call|jmp)\s+([0-9a-f]+)', t)
        if m:
            a = int(m.group(1), 16)
            if a in thunks: imps.add(thunks[a].split('!')[1])
            if a in exports: calls_exp.add(exports[a])
    return strs[:6], sorted(imps)[:12], sorted(calls_exp)[:12]

def report(label, i):
    s, e = func_bounds(i)
    fs = lines[s][0]
    strs, imps, exps = describe(s, e)
    name = exports.get(fs, '')
    print('  %-14s site %x in func %x%s (%d insns)' % (label, lines[i][0], fs, ' = ' + name if name else '', e - s + 1))
    if strs: print('      strings:', strs)
    if imps: print('      imports:', ' '.join(imps))
    if exps: print('      calls exported:', ' '.join(exps))

for n, a in funcs.items():
    print('== %s (%x)' % (n, a))
    key = '%x' % a
    for i, (ad, t) in enumerate(lines):
        if re.match(r'(call|jmp)\s+' + key + r'\b', t):
            report('call', i)
for n, a in globs.items():
    print('== global %s (%x)' % (n, a))
    key = '0x%x' % a
    for i, (ad, t) in enumerate(lines):
        if key in t:
            report('ref', i)
