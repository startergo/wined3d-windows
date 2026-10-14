#!/usr/bin/env python3
"""callsites.py <pe> <DLL!sym-substring>... [--before N] [--after N]

Show every call to an imported function (direct `call *IAT`, via
`mov IAT,%reg; call *%reg`, or through a `jmp *IAT` thunk), with the
surrounding instructions, the enclosing function's start address, and
any referenced strings decoded inline.
"""
import sys, re, subprocess, importlib.util, os

def _dest_reg(args):
    """destination register of an AT&T instruction, if it is a plain register"""
    parts = args.split(',')
    d = parts[-1].strip() if parts else ''
    return d if re.match(r'^%e[a-z]{2}$', d) else None
here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('wu', os.path.join(here, '..', 'win98-universe.py'))
wu = importlib.util.module_from_spec(spec); spec.loader.exec_module(wu)
spec2 = importlib.util.spec_from_file_location('cd', os.path.join(here, '..', 'win98-calldiff.py'))
cd = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(cd)

args = [a for a in sys.argv[1:] if not a.startswith('--')]
before = 14; after = 6
for a in sys.argv[1:]:
    if a.startswith('--before='): before = int(a.split('=')[1])
    if a.startswith('--after='): after = int(a.split('=')[1])
path, wanted = args[0], args[1:]
pe = wu.PE(path)
iat = cd.iat_map(pe)
src = cd.sanitized_copy(path)
dis = subprocess.run([cd.OBJDUMP, '-d', '--no-show-raw-insn', src], capture_output=True, text=True).stdout
if src != path:
    os.unlink(src)
lines = []
for l in dis.splitlines():
    m = re.match(r'^\s*([0-9a-f]+):\s+(.*)$', l)
    if m:
        lines.append((int(m.group(1), 16), m.group(2).rstrip()))
thunks = {}
for a, t in lines:
    m = re.match(r'jmp\s+\*0x([0-9a-f]+)', t)
    if m and int(m.group(1), 16) in iat:
        thunks[a] = iat[int(m.group(1), 16)]

def deco(t):
    def r(m):
        v = int(m.group(1), 16)
        s = cd.string_at(pe, v)
        if s and len(s) > 2:
            return '$"%s"' % s
        if v in iat:
            return '$&' + iat[v]
        return m.group(0)
    t = re.sub(r'\$0x([0-9a-f]{6,8})', r, t)
    m = re.search(r'\*0x([0-9a-f]+)', t)
    if m and int(m.group(1), 16) in iat:
        t += '    ; ' + iat[int(m.group(1), 16)]
    m = re.match(r'(call|jmp)\s+([0-9a-f]+)', t)
    if m and int(m.group(2), 16) in thunks:
        t += '    ; ' + thunks[int(m.group(2), 16)]
    return t

def func_start(i):
    for j in range(i, max(0, i - 3000), -1):
        t = lines[j][1]
        if t.startswith('push   %ebp') and j + 1 < len(lines) and lines[j + 1][1].startswith('mov    %esp,%ebp'):
            return lines[j][0]
        if t.startswith('ret') and j != i:
            return lines[j + 1][0]
    return None

regs = {}
for i, (a, t) in enumerate(lines):
    tgt = None
    m = re.match(r'mov\s+0x([0-9a-f]+),(%e[a-z]{2})$', t)
    if m and int(m.group(1), 16) in iat:
        regs[m.group(2)] = iat[int(m.group(1), 16)]
    if t.startswith('call') or t.startswith('jmp'):
        m = re.search(r'\*0x([0-9a-f]+)', t)
        rm = re.match(r'(?:call|jmp)\s+\*(%e[a-z]{2})$', t)
        m2 = re.match(r'(?:call|jmp)\s+([0-9a-f]+)', t)
        if m and int(m.group(1), 16) in iat:
            tgt = iat[int(m.group(1), 16)]
        elif rm and rm.group(1) in regs:
            tgt = regs[rm.group(1)]
        elif m2 and int(m2.group(1), 16) in thunks:
            tgt = thunks[int(m2.group(1), 16)]
        if t.startswith('jmp') and a in thunks:
            tgt = None
    if tgt and any(w in tgt for w in wanted):
        fs = func_start(i)
        print('==== %s called at %#x (function starts ~%s)' % (tgt, a, hex(fs) if fs else '?'))
        for j in range(max(0, i - before), min(len(lines), i + after + 1)):
            mark = '>>' if j == i else '  '
            print('  %s %x: %s' % (mark, lines[j][0], deco(lines[j][1])))
    if t.startswith('ret'):
        regs = {}
    m = re.match(r'(\S+)\s+(.*)$', t)
    if m:
        d = _dest_reg(m.group(2))
        if d and d in regs and not re.match(r'mov\s+0x([0-9a-f]+),' + re.escape(d) + r'$', t):
            del regs[d]
        if m.group(1).startswith('call'):
            for r in ('%eax', '%ecx', '%edx'):
                regs.pop(r, None)
