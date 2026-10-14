#!/usr/bin/env python3
"""annot.py <pe> <start> <stop> [--callers]

Annotated disassembly of [start, stop): import calls/IAT loads resolved to
DLL!sym, immediate string pointers decoded, data globals labelled from
re/globals-<basename>.txt if present.  With --callers, list every call site
(anywhere in the image) of each function that starts inside the range.
"""
import sys, re, subprocess, importlib.util, os
here = os.path.dirname(os.path.abspath(__file__))
def load(name, f):
    s = importlib.util.spec_from_file_location(name, os.path.join(here, '..', f))
    m = importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
wu = load('wu', 'win98-universe.py'); cd = load('cd', 'win98-calldiff.py')

path, start, stop = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3], 16)
pe = wu.PE(path); iat = cd.iat_map(pe)
labels = {}
gl = os.path.join(here, 'globals-%s.txt' % os.path.basename(os.path.dirname(path)))
if os.path.exists(gl):
    for l in open(gl):
        if l.strip() and not l.startswith('#'):
            a, n = l.split(None, 1); labels[int(a, 16)] = n.strip()
src = cd.sanitized_copy(path)
dis = subprocess.run([cd.OBJDUMP, '-d', '--no-show-raw-insn', src], capture_output=True, text=True).stdout
if src != path: os.unlink(src)
lines = []
for l in dis.splitlines():
    m = re.match(r'^\s*([0-9a-f]+):\s+(.*)$', l)
    if m: lines.append((int(m.group(1), 16), m.group(2).rstrip()))
thunks = {}
for a, t in lines:
    m = re.match(r'jmp\s+\*0x([0-9a-f]+)', t)
    if m and int(m.group(1), 16) in iat: thunks[a] = iat[int(m.group(1), 16)]

def deco(t):
    notes = []
    for m in re.finditer(r'0x([0-9a-f]{7,8})', t):
        v = int(m.group(1), 16)
        if v in labels: notes.append('%s=%s' % (m.group(0), labels[v]))
        elif v in iat: notes.append(iat[v])
        else:
            s = cd.string_at(pe, v)
            if s and len(s) > 2: notes.append('"%s"' % s)
    m = re.match(r'(call|jmp)\s+([0-9a-f]+)', t)
    if m and int(m.group(2), 16) in thunks: notes.append(thunks[int(m.group(2), 16)])
    return t + ('    ; ' + ', '.join(notes) if notes else '')

starts = []
for i, (a, t) in enumerate(lines):
    if start <= a < stop:
        if t.startswith('push   %ebp') and i + 1 < len(lines) and lines[i + 1][1].startswith('mov    %esp,%ebp'):
            starts.append(a); print('\n---- func %x' % a)
        print('  %x: %s' % (a, deco(t)))
if '--callers' in sys.argv:
    print('\n==== callers')
    for f in starts:
        key = '%x' % f
        sites = [a for a, t in lines if re.match(r'(call|jmp)\s+' + key + r'\b', t)]
        print('  %s <- %s' % (key, ' '.join('%x' % s for s in sites) or '(none: exported or indirect)'))
