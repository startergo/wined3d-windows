#!/usr/bin/env python3
"""win98-calldiff.py — disassemble a working and a candidate PE and diff the calls.

For each binary:
  * every call/jmp through the import address table is mapped back to
    DLL!symbol (direct `call *IAT`, and calls into `jmp *IAT` thunks);
  * every string argument pushed before a call to GetProcAddress,
    LoadLibraryA/W, LoadLibraryExA, GetModuleHandleA/W (runtime lookups that
    the import table never shows) is recovered;
then the two are diffed, and runtime-looked-up names are checked against
the Win98 runtime universe.

Usage:
  win98-calldiff.py <working.dll> <ours.dll> [--universe FILE]
  win98-calldiff.py --dirs <working-dir> <our-dir> [--universe FILE]

Needs i686-w64-mingw32-objdump (brew install mingw-w64) or objdump with PE
support on PATH.
"""
import argparse, os, re, shutil, subprocess, sys, importlib.util

def _dest_reg(args):
    """destination register of an AT&T instruction, if it is a plain register"""
    parts = args.split(',')
    d = parts[-1].strip() if parts else ''
    return d if re.match(r'^%e[a-z]{2}$', d) else None
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('wu', os.path.join(HERE, 'win98-universe.py'))
wu = importlib.util.module_from_spec(spec); spec.loader.exec_module(wu)

OBJDUMP = shutil.which('i686-w64-mingw32-objdump') or shutil.which('objdump')
LOOKUP_FUNCS = {'GetProcAddress', 'LoadLibraryA', 'LoadLibraryW', 'LoadLibraryExA',
                'LoadLibraryExW', 'GetModuleHandleA', 'GetModuleHandleW'}


def iat_map(pe):
    """{IAT slot VA: 'DLL!sym'} for normal imports (FirstThunk slots)."""
    m = {}
    if len(pe.dirs) <= 1 or not pe.dirs[1][0]:
        return m
    import struct
    rva = pe.dirs[1][0]
    while True:
        o = pe.off(rva)
        if o is None or o + 20 > len(pe.d):
            break
        oft, _, _, name, ft = struct.unpack_from('<IIIII', pe.d, o)
        if not (oft or name or ft):
            break
        dll = (pe.cstr(name) or '?').upper()
        names = pe._walk_thunks(oft or ft)
        for i, sym in enumerate(names):
            m[pe.imagebase + ft + 4 * i] = '%s!%s' % (dll, sym)
        rva += 20
    return m


def string_at(pe, va):
    rva = va - pe.imagebase
    if rva <= 0:
        return None
    o = pe.off(rva)
    if o is None:
        return None
    d = pe.d
    e = d.find(b'\0', o)
    if e > o and e - o < 128:
        s = d[o:e]
        if all(32 <= c < 127 for c in s):
            return s.decode()
    # UTF-16LE
    s = []
    i = o
    while i + 1 < len(d) and len(s) < 128:
        c = d[i] | (d[i + 1] << 8)
        if c == 0:
            break
        if not (32 <= c < 127):
            return None
        s.append(chr(c)); i += 2
    return ''.join(s) if len(s) >= 2 else None


LINE = re.compile(r'^\s*([0-9a-f]+):\s+(?:[0-9a-f]{2} )+\s*(\S+)\s*(.*)$')


def sanitized_copy(path):
    """binutils rejects a PE whose COFF symbol-table pointer runs past EOF
    (what docker/patch_pe_win98.py leaves behind after truncating). Return a
    temp copy with PointerToSymbolTable/NumberOfSymbols zeroed if needed."""
    import struct, tempfile
    d = bytearray(open(path, 'rb').read())
    o = struct.unpack_from('<I', d, 0x3C)[0]
    psym, nsym = struct.unpack_from('<II', d, o + 12)
    if psym and psym + 18 * nsym > len(d):
        struct.pack_into('<II', d, o + 12, 0, 0)
        # With the string table gone, long section names (/4 = .eh_frame)
        # dangle and BFD rejects the file; give them a short literal name.
        nsec, optsz = struct.unpack_from('<H', d, o + 6)[0], struct.unpack_from('<H', d, o + 20)[0]
        s = o + 24 + optsz
        for i in range(nsec):
            if d[s + 40 * i:s + 40 * i + 1] == b'/':
                d[s + 40 * i:s + 40 * i + 8] = b'.eh_fram'
        fd, tmp = tempfile.mkstemp(suffix='.dll')
        os.write(fd, bytes(d)); os.close(fd)
        print('NOTE %s: COFF symbol table pointer 0x%x (%d syms) is past EOF 0x%x '
              '-- disassembling a sanitized copy' % (path, psym, nsym, len(d)))
        return tmp
    return path


def analyse(path):
    pe = wu.PE(path)
    iat = iat_map(pe)
    src = sanitized_copy(path)
    out = subprocess.run([OBJDUMP, '-d', '--no-show-raw-insn', '-M', 'att', src],
                         capture_output=True, text=True, errors='replace').stdout
    if src != path:
        os.unlink(src)
    if not out.strip():
        sys.exit('objdump produced no disassembly for %s' % path)
    insns = []
    for line in out.splitlines():
        m = re.match(r'^\s*([0-9a-f]+):\s+(\S+)\s*(.*)$', line)
        if m:
            insns.append((int(m.group(1), 16), m.group(2), m.group(3)))
    # thunks: address of `jmp *0xIAT`
    thunks = {}
    for addr, op, args in insns:
        if op.startswith('jmp'):
            mm = re.search(r'\*0x([0-9a-f]+)', args)
            if mm and int(mm.group(1), 16) in iat:
                thunks[addr] = iat[int(mm.group(1), 16)]
    calls = Counter()
    lookups = Counter()
    recent = []          # pushed immediates / movs to (%esp) since last call
    regs = {}            # %reg -> 'DLL!sym' after `mov 0xIAT,%reg`
    for addr, op, args in insns:
        target = None
        if op.startswith('mov'):
            mm = re.match(r'0x([0-9a-f]+),(%e[a-z]{2})$', args.strip())
            if mm and int(mm.group(1), 16) in iat:
                regs[mm.group(2)] = iat[int(mm.group(1), 16)]
        if op.startswith('call'):
            mm = re.search(r'\*0x([0-9a-f]+)', args)
            rm = re.match(r'\*(%e[a-z]{2})$', args.strip())
            if mm and int(mm.group(1), 16) in iat:
                target = iat[int(mm.group(1), 16)]
            elif rm and rm.group(1) in regs:
                target = regs[rm.group(1)]
            else:
                mm = re.match(r'0?x?([0-9a-f]+)\b', args.strip())
                if mm:
                    t = int(mm.group(1), 16)
                    target = thunks.get(t)
            if target:
                calls[target] += 1
                sym = target.split('!', 1)[1]
                if sym in LOOKUP_FUNCS:
                    for v in recent[-4:]:
                        s = string_at(pe, v)
                        if s:
                            lookups['%s("%s")' % (sym, s)] += 1
            recent = []
            for r in ('%eax', '%ecx', '%edx'):               # caller-saved
                regs.pop(r, None)
            continue
        # push $imm / movl $imm,(%esp) / movl $imm,0x4(%esp) / lea / mov $imm,%reg
        for mm in re.finditer(r'\$0x([0-9a-f]+)', args):
            if op.startswith(('push', 'mov', 'lea')):
                recent.append(int(mm.group(1), 16))
        if op.startswith('ret'):
            recent = []
            regs = {}
        elif op.startswith('jmp'):
            recent = []
        # a register stays bound to an IAT slot until something overwrites it
        d = _dest_reg(args)
        if d and d in regs and not (op.startswith('mov') and re.match(r'0x([0-9a-f]+),', args.strip())
                                    and int(args.strip().split(',')[0], 16) in iat):
            del regs[d]
    return calls, lookups


def load_universe(path):
    syms = set()
    for l in open(path, encoding='latin-1'):
        if '!' in l:
            d, s = l.rstrip('\n').split('!', 1)
            syms.add(s.split(' -> ')[0])
    return syms


def compare(ref, new, uni):
    rc, rl = analyse(ref)
    nc, nl = analyse(new)
    print('=' * 78)
    print('working: %s\nours:    %s' % (ref, new))
    gone = sorted(set(rc) - set(nc))
    added = sorted(set(nc) - set(rc))
    print('\n-- imported functions CALLED by working, NEVER called by ours (%d):' % len(gone))
    for s in gone:
        print('   %-48s %3d call sites' % (s, rc[s]))
    print('\n-- imported functions called only by ours (%d):' % len(added))
    for s in added:
        print('   %-48s %3d call sites' % (s, nc[s]))
    changed = [(s, rc[s], nc[s]) for s in sorted(set(rc) & set(nc)) if rc[s] != nc[s]]
    print('\n-- call-site count changes (%d):' % len(changed))
    for s, a, b in changed:
        print('   %-48s %3d -> %3d' % (s, a, b))
    for label, lk in (('working', rl), ('ours', nl)):
        print('\n-- runtime lookups in %s (%d):' % (label, len(lk)))
        for k in sorted(lk):
            flag = ''
            if uni and k.startswith('GetProcAddress('):
                name = k[len('GetProcAddress("'):-2]
                flag = '' if name in uni else '   <-- NOT ON WIN98'
            print('   %s%s' % (k, flag))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('a'); ap.add_argument('b')
    ap.add_argument('--dirs', action='store_true')
    ap.add_argument('--universe', default=os.path.join(HERE, 'win98-runtime-universe.txt'))
    a = ap.parse_args()
    if not OBJDUMP:
        sys.exit('need i686-w64-mingw32-objdump')
    uni = load_universe(a.universe) if os.path.exists(a.universe) else None
    if a.dirs:
        for f in sorted(os.listdir(a.b)):
            if f.lower().endswith('.dll') and os.path.exists(os.path.join(a.a, f)):
                compare(os.path.join(a.a, f), os.path.join(a.b, f), uni)
    else:
        compare(a.a, a.b, uni)


if __name__ == '__main__':
    main()
