#!/usr/bin/env python3
"""win98-universe.py — the Win98 runtime universe and import checker.

Win98 analogue of leopard-webkit-build/tools/10.6-runtime-universe.txt.
On 10.6 the failure class is a missing ObjC selector (runtime abort), so
the universe there is a `strings` dump. On Win98 the failure class is a
missing *export*: the 9x loader refuses to start the process ("The X.EXE
file is linked to missing export KERNEL32.DLL:Foo"), or LoadLibrary fails
for a DLL. That is decided entirely by PE export tables, so this universe
is built from export tables, not strings — it is exact, not a pre-filter.

Pure Python, no dependencies (no pefile). Methodology: WIN98-UNIVERSE.md.

Usage:
  win98-universe.py universe <dir-or-files...> -o win98-runtime-universe.txt
        [--manifest win98-runtime-universe.manifest] [--exclude NAME ...]
      Every 32-bit PE (.DLL/.DRV/.OCX/.ACM/.CPL/.AX) found is read; 16-bit
      NE files are skipped. Output lines (LC_ALL=C sorted, unique):
          KERNEL32.DLL!CreateFileA          named export
          KERNEL32.DLL!#17                  every export ordinal
          FOO.DLL!Bar -> NTDLL.Baz          forwarder
          FOO.DLL!                          module present, exports nothing
      DLL names are upper-cased (the 9x loader is case-insensitive on
      module names); export names are case-sensitive and kept as-is.

  win98-universe.py check <pe-files...> [--universe FILE] [--system-only] [--strict]
      Lists every import (normal + delay-load) of the given EXEs/DLLs:
          MISSING      DLL is in the universe, symbol is not -> load fails
          UNKNOWN-DLL  DLL not in the universe (coverage gap, or must ship
                       with the app; ucrtbase.dll is the classic 9x killer)
      Exit 1 if any MISSING (or any UNKNOWN-DLL with --strict).

  win98-universe.py exports <pe-file>     dump one file's exports
  win98-universe.py imports <pe-file>     dump one file's imports
"""
import argparse, hashlib, os, struct, sys, time

PE_EXTS = ('.dll', '.drv', '.ocx', '.acm', '.cpl', '.ax')


class PE:
    def __init__(self, path):
        self.path = path
        with open(path, 'rb') as f:
            self.d = f.read()
        d = self.d
        if len(d) < 0x40 or d[:2] != b'MZ':
            raise ValueError('not MZ')
        lfanew = struct.unpack_from('<I', d, 0x3C)[0]
        if lfanew + 24 > len(d) or d[lfanew:lfanew + 4] != b'PE\0\0':
            raise ValueError('not PE (16-bit NE/LE or plain DOS)')
        self.machine, nsec, self.timestamp = struct.unpack_from('<HHI', d, lfanew + 4)
        optsize, self.characteristics = struct.unpack_from('<HH', d, lfanew + 20)
        opt = lfanew + 24
        self.magic = struct.unpack_from('<H', d, opt)[0]
        if self.magic == 0x10B:
            self.imagebase = struct.unpack_from('<I', d, opt + 28)[0]
            nrva = struct.unpack_from('<I', d, opt + 92)[0]
            ddir, self.thunk = opt + 96, 4
        elif self.magic == 0x20B:
            self.imagebase = struct.unpack_from('<Q', d, opt + 24)[0]
            nrva = struct.unpack_from('<I', d, opt + 108)[0]
            ddir, self.thunk = opt + 112, 8
        else:
            raise ValueError('bad optional header magic %#x' % self.magic)
        self.dirs = [struct.unpack_from('<II', d, ddir + 8 * i) for i in range(min(nrva, 16))]
        self.sections = []
        s = opt + optsize
        for _ in range(nsec):
            vsize, va, rawsize, rawptr = struct.unpack_from('<IIII', d, s + 8)
            self.sections.append((va, max(vsize, rawsize), rawptr, rawsize))
            s += 40

    def off(self, rva):
        for va, size, rawptr, rawsize in self.sections:
            if va <= rva < va + size:
                o = rva - va
                return None if o >= rawsize else rawptr + o
        return rva if rva < len(self.d) else None   # header / unsectioned

    def cstr(self, rva):
        o = self.off(rva)
        if o is None:
            return None
        e = self.d.find(b'\0', o)
        return self.d[o:e if e >= 0 else len(self.d)].decode('latin-1')

    def _un(self, rva, fmt, n):
        o = self.off(rva)
        return None if o is None or o + n > len(self.d) else struct.unpack_from(fmt, self.d, o)[0]

    def u32(self, rva): return self._un(rva, '<I', 4)
    def u16(self, rva): return self._un(rva, '<H', 2)
    def thunk_val(self, rva):
        return self._un(rva, '<I', 4) if self.thunk == 4 else self._un(rva, '<Q', 8)

    def exports(self):
        """([(ordinal, name or None, forwarder or None)], internal dll name)"""
        if not self.dirs or self.dirs[0][0] == 0:
            return [], None
        erva, esize = self.dirs[0]
        o = self.off(erva)
        if o is None or o + 40 > len(self.d):
            return [], None
        (_, _, _, _, name_rva, base, nfunc, nnames,
         afunc, anames, aords) = struct.unpack_from('<IIHHIIIIIII', self.d, o)
        if nfunc > 65536 or nnames > 65536:
            return [], None
        names = {}
        for i in range(nnames):
            nrva, idx = self.u32(anames + 4 * i), self.u16(aords + 2 * i)
            if nrva is not None and idx is not None:
                names.setdefault(idx, []).append(self.cstr(nrva))
        out = []
        for i in range(nfunc):
            frva = self.u32(afunc + 4 * i)
            if not frva:
                continue                              # unused ordinal slot
            fwd = self.cstr(frva) if erva <= frva < erva + esize else None
            for n in names.get(i, [None]):
                out.append((base + i, n, fwd))
        return out, self.cstr(name_rva)

    def _walk_thunks(self, rva, va_based=False):
        flag = 1 << (self.thunk * 8 - 1)
        res = []
        for _ in range(65536):
            v = self.thunk_val(rva)
            if not v:
                break
            if v & flag:
                res.append('#%d' % (v & 0xFFFF))
            else:
                n = self.cstr(((v - self.imagebase) if va_based else v) + 2)
                if n is None:
                    break
                res.append(n)
            rva += self.thunk
        return res

    def imports(self):
        """[(DLL, symbol, 'import'|'delay')]"""
        out = []
        if len(self.dirs) > 1 and self.dirs[1][0]:
            rva = self.dirs[1][0]
            for _ in range(4096):
                o = self.off(rva)
                if o is None or o + 20 > len(self.d):
                    break
                oft, _, _, name, ft = struct.unpack_from('<IIIII', self.d, o)
                if not (oft or name or ft):
                    break
                dll = self.cstr(name)
                if dll:
                    out += [(dll.upper(), s, 'import') for s in self._walk_thunks(oft or ft)]
                rva += 20
        if len(self.dirs) > 13 and self.dirs[13][0]:
            rva = self.dirs[13][0]
            for _ in range(4096):
                o = self.off(rva)
                if o is None or o + 32 > len(self.d):
                    break
                attrs, name, _, _, intab = struct.unpack_from('<IIIII', self.d, o)
                if not name:
                    break
                va_based = not (attrs & 1)        # VC6-era delay tables hold VAs
                if va_based:
                    name -= self.imagebase
                    intab -= self.imagebase
                dll = self.cstr(name)
                if dll:
                    out += [(dll.upper(), s, 'delay') for s in self._walk_thunks(intab, va_based)]
                rva += 32
        return out


def file_version(d):
    """FileVersion from VS_FIXEDFILEINFO (signature 0xFEEF04BD), or ''."""
    i = d.find(b'\xbd\x04\xef\xfe')
    if i < 0 or i + 16 > len(d):
        return ''
    ms, ls = struct.unpack_from('<II', d, i + 8)
    return '%d.%d.%d.%d' % (ms >> 16, ms & 0xFFFF, ls >> 16, ls & 0xFFFF)


def gather(paths):
    files = []
    for p in paths:
        if os.path.isdir(p):
            for root, _, fs in os.walk(p):
                files += [os.path.join(root, f) for f in fs if f.lower().endswith(PE_EXTS)]
        else:
            files.append(p)
    # First occurrence of a module name wins (pass SYSTEM before WINDOWS).
    seen, uniq = set(), []
    for f in files:
        b = os.path.basename(f).upper()
        if b not in seen:
            seen.add(b)
            uniq.append(f)
    return sorted(uniq, key=lambda x: os.path.basename(x).upper())


def cmd_universe(a):
    lines, manifest, skipped = set(), [], 0
    exclude = set(x.upper() for x in (a.exclude or []))
    for path in gather(a.paths):
        base = os.path.basename(path).upper()
        if base in exclude:
            manifest.append('%-14s EXCLUDED (--exclude)' % base)
            continue
        try:
            pe = PE(path)
        except (ValueError, struct.error):
            skipped += 1
            continue
        exps, _ = pe.exports()
        for ordn, name, fwd in exps:
            lines.add('%s!#%d' % (base, ordn))
            if name:
                lines.add('%s!%s%s' % (base, name, (' -> ' + fwd) if fwd else ''))
        if not exps:
            lines.add('%s!' % base)
        flag = ''
        # A PE link date after 2003 cannot be stock Win98/98SE or its updates.
        if 1072915200 < pe.timestamp < 0xF0000000:
            flag = '  NON-STOCK? (linked %s)' % time.strftime('%Y-%m-%d', time.gmtime(pe.timestamp))
        manifest.append('%-14s %-16s %8d  md5:%s  exports:%d%s' % (
            base, file_version(pe.d) or '-', len(pe.d),
            hashlib.md5(pe.d).hexdigest(), len(exps), flag))
    out = sorted(lines, key=lambda s: s.encode('latin-1'))
    with open(a.output, 'w', encoding='latin-1', newline='\n') as f:
        f.write('\n'.join(out) + '\n')
    if a.manifest:
        with open(a.manifest, 'w') as f:
            f.write('# Win98 runtime universe manifest - one line per 32-bit PE module scanned\n')
            f.write('# name  FileVersion  size  md5  export-count  [NON-STOCK? flag]\n')
            f.write('\n'.join(manifest) + '\n')
    n = sum(1 for m in manifest if 'EXCLUDED' not in m)
    print('[universe] %d PE modules, %d skipped (16-bit/non-PE), %d lines -> %s'
          % (n, skipped, len(out), a.output))
    flagged = [m.split()[0] for m in manifest if 'NON-STOCK' in m]
    if flagged:
        print('[universe] non-stock-looking modules (see manifest): ' + ' '.join(flagged))


def load_universe(path):
    syms, dlls = set(), set()
    for line in open(path, encoding='latin-1'):
        line = line.rstrip('\n')
        if '!' in line:
            dll, sym = line.split('!', 1)
            dlls.add(dll)
            if sym:
                syms.add((dll, sym.split(' -> ')[0]))
    return syms, dlls


def cmd_check(a):
    syms, dlls = load_universe(a.universe)
    # The 9x loader searches the application's directory BEFORE
    # WINDOWS\SYSTEM, so a DLL we ship (e.g. a Wine-built msvcrt.dll next to
    # wined3d.dll) shadows the system copy of the same name. Model that:
    # every file passed to `check` is treated as app-local, and imports of
    # its name resolve against ITS exports, not the system's.
    local = {}
    for path in a.files:
        try:
            exps, _ = PE(path).exports()
        except (ValueError, struct.error):
            continue
        s = set()
        for o, n, _f in exps:
            s.add('#%d' % o)
            if n:
                s.add(n)
        local[os.path.basename(path).upper()] = s
    shadowed = sorted(set(local) & dlls)
    if shadowed:
        print('NOTE app-local copies SHADOW system modules (loaded instead of '
              'WINDOWS\\SYSTEM): ' + ' '.join(shadowed))
    bad = 0
    results = {}
    for path in a.files:
        try:
            imps = PE(path).imports()
        except (ValueError, struct.error) as e:
            print('%s: not a PE (%s)' % (path, e))
            continue
        missing, unknown = [], {}
        for dll, sym, kind in imps:
            if dll in local:
                if sym not in local[dll]:
                    missing.append((dll + ' (app-local)', sym, kind))
            elif dll in dlls:
                if (dll, sym) not in syms:
                    missing.append((dll, sym, kind))
            else:
                unknown[dll] = unknown.get(dll, 0) + 1
        results[path] = (imps, missing, unknown)
    # A module that imports a failing app-local module fails too (the loader
    # aborts the whole load). Propagate to a fixed point.
    failing = set(os.path.basename(p).upper() for p, r in results.items() if r[1])
    changed = True
    while changed:
        changed = False
        for p, (imps, _, _) in results.items():
            b = os.path.basename(p).upper()
            if b not in failing and any(d in failing for d, _, k in imps if k == 'import'):
                failing.add(b)
                changed = True
    for path, (imps, missing, unknown) in results.items():
        print('== %s: %d imports' % (path, len(imps)))
        for dll, sym, kind in missing:
            print('  MISSING      %s!%s%s' % (dll, sym, '  (delay-load)' if kind == 'delay' else ''))
        via = sorted(set(d for d, _, k in imps if k == 'import' and d in failing))
        for d in via:
            print('  FAILS-VIA    %s (app-local dependency cannot load)' % d)
        if not a.system_only:
            for dll, n in sorted(unknown.items()):
                print('  UNKNOWN-DLL  %s (%d symbols)' % (dll, n))
        if not missing and not via and (a.system_only or not unknown):
            print('  OK')
        bad += len(missing) + len(via) + (len(unknown) if a.strict else 0)
    sys.exit(1 if bad else 0)


def cmd_exports(a):
    exps, internal = PE(a.file).exports()
    print('# internal name: %s' % internal)
    for o, n, f in exps:
        print('%5d %s%s' % (o, n or '(ordinal only)', (' -> ' + f) if f else ''))


def cmd_imports(a):
    for dll, sym, kind in PE(a.file).imports():
        print('%s!%s%s' % (dll, sym, '  (delay)' if kind == 'delay' else ''))


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    default_u = os.path.join(here, 'win98-runtime-universe.txt')
    ap = argparse.ArgumentParser(description='Win98 runtime universe and import checker')
    sp = ap.add_subparsers(dest='cmd', required=True)
    u = sp.add_parser('universe')
    u.add_argument('paths', nargs='+')
    u.add_argument('-o', '--output', default=default_u)
    u.add_argument('--manifest')
    u.add_argument('--exclude', nargs='*', help='module names to leave out (e.g. a replaced DDRAW.DLL)')
    c = sp.add_parser('check')
    c.add_argument('files', nargs='+')
    c.add_argument('--universe', default=default_u)
    c.add_argument('--system-only', action='store_true', help='hide UNKNOWN-DLL lines')
    c.add_argument('--strict', action='store_true', help='UNKNOWN-DLL also fails')
    sp.add_parser('exports').add_argument('file')
    sp.add_parser('imports').add_argument('file')
    a = ap.parse_args()
    {'universe': cmd_universe, 'check': cmd_check,
     'exports': cmd_exports, 'imports': cmd_imports}[a.cmd](a)


if __name__ == '__main__':
    main()
