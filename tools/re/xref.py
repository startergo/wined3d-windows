#!/usr/bin/env python3
"""xref.py <pe> [string ...] [f:export ...] [a:0xVA ...]

Reverse-engineering helper for the qemu-3dfx reference DLLs:
  string     disassembly around every instruction referencing that string's VA
  f:name     full disassembly of the named export (up to the first ret)
  a:0xVA     disassembly of the function at that VA (up to the first ret)
  w:0xVA     every instruction that writes/reads that data VA (globals)
"""
import sys, re, subprocess, struct, importlib.util, os
spec = importlib.util.spec_from_file_location(
    'wu', os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'win98-universe.py'))
wu = importlib.util.module_from_spec(spec); spec.loader.exec_module(wu)

path = sys.argv[1]
pe = wu.PE(path)

def off2va(o):
    for va, size, rawptr, rawsize in pe.sections:
        if rawptr <= o < rawptr + rawsize:
            return pe.imagebase + va + (o - rawptr)
    return None

dis = subprocess.run(['i686-w64-mingw32-objdump', '-d', '--no-show-raw-insn', path],
                     capture_output=True, text=True).stdout.splitlines()
lines = []
for l in dis:
    m = re.match(r'^\s*([0-9a-f]+):\s+(.*)$', l)
    if m:
        lines.append((int(m.group(1), 16), m.group(2).rstrip()))
idx = {a: i for i, (a, _) in enumerate(lines)}

def func_at(va, limit=200):
    i0 = idx.get(va)
    if i0 is None:
        print('     (no instruction at %#x)' % va); return
    for j in range(i0, min(len(lines), i0 + limit)):
        print('     %x: %s' % lines[j])
        if lines[j][1].startswith('ret'):
            break

exports = {}
if pe.dirs and pe.dirs[0][0]:
    eo = pe.off(pe.dirs[0][0])
    (_, _, _, _, _, base, nfunc, nnames, afunc, anames, aords) = struct.unpack_from('<IIHHIIIIIII', pe.d, eo)
    for i in range(nnames):
        n = pe.cstr(pe.u32(anames + 4 * i))
        exports[n] = pe.imagebase + pe.u32(afunc + 4 * pe.u16(aords + 2 * i))

for a in sys.argv[2:]:
    if a.startswith('f:'):
        n = a[2:]
        print('#### export %s at %#x' % (n, exports.get(n, 0)))
        if n in exports:
            func_at(exports[n])
    elif a.startswith('a:'):
        va = int(a[2:], 16)
        print('#### function at %#x' % va)
        func_at(va)
    elif a.startswith('w:'):
        key = '0x%x' % int(a[2:], 16)
        print('#### refs to %s' % key)
        for i, (ad, t) in enumerate(lines):
            if key in t:
                print('     %x: %s' % (ad, t))
    else:
        o = pe.d.find(b'\0' + a.encode() + b'\0')
        va = off2va(o + 1) if o >= 0 else None
        print('#### string %r at VA %#x' % (a, va or 0))
        if not va:
            continue
        key = '0x%x' % va
        for i, (ad, t) in enumerate(lines):
            if key in t:
                print('  -- xref at %#x' % ad)
                for j in range(max(0, i - 15), min(len(lines), i + 30)):
                    print('     %x: %s' % lines[j])
