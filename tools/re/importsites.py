#!/usr/bin/env python3
"""importsites.py <reference.dll> <named.dll> <DLL!pattern> ...

Every call site of the matching imports in both DLLs — direct `call *[IAT]`
and calls through `jmp *[IAT]` thunks — with the enclosing function: named
from the symbol table for <named.dll> (a build that kept its COFF symbols),
and for <reference.dll> by fingerprint match against <named.dll>
(see funcmatch.py).  Used to align our call-site placement with the
reference's.

  importsites.py tests/emu/reference/8.0.2/ddraw.dll re-work/ddraw-8.0.2-symbols.dll \\
      'WINED3D.DLL!wined3d_(hal_3dfx|enum_hal_last|passthru|override_.*|.*fpslimit|surface_ddheap)$'
"""
import os, re, sys, bisect, importlib.util
here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('funcmatch', os.path.join(here, 'funcmatch.py'))
fm = importlib.util.module_from_spec(spec); spec.loader.exec_module(fm)


def sites(img, pattern):
    """[(import name, call address)]"""
    out = []
    rx = re.compile(pattern)
    for a, t in img.lines:
        name = None
        m = re.match(r'call\s+\*0x([0-9a-f]+)', t)
        if m and int(m.group(1), 16) in img.iat:
            name = img.iat[int(m.group(1), 16)]
        m = re.match(r'call\s+([0-9a-f]+)', t)
        if m and int(m.group(1), 16) in img.thunks:
            name = img.thunks[int(m.group(1), 16)]
        if name:
            name = name.split('@')[0]
            if rx.search(name):
                out.append((name, a))
    return out


def main():
    ref = fm.Image(sys.argv[1]); named = fm.Image(sys.argv[2], symbols=True)
    pats = sys.argv[3:]
    cands = [(n, a, named.fingerprint(a, e)) for n, a, e in named.ranges()]
    starts = named.starts
    for pat in pats:
        print('#### %s' % pat)
        print('  reference:')
        cache = {}
        for name, a in sites(ref, pat):
            s, e = ref.bounds_guess(a)
            if s not in cache:
                fp, n = ref.fingerprint(s, e)
                best = sorted(((fm.sim(fp, f, n, m), nm) for nm, _, (f, m) in cands), reverse=True)[:2]
                cache[s] = '  '.join('%s %.2f' % (nm, sc) for sc, nm in best)
            print('    %-40s %x  in %x: %s' % (name.split('!')[1], a, s, cache[s]))
        print('  ours:')
        for name, a in sites(named, pat):
            fn = named.syms[starts[bisect.bisect_right(starts, a) - 1]]
            print('    %-40s %x  in %s' % (name.split('!')[1], a, fn))


if __name__ == '__main__':
    main()
