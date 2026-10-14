#!/usr/bin/env python3
"""modsites.py <wined3d.dll> [--named <symbols.dll>]

Locate the qemu-3dfx module inside a reference wined3d.dll and list how the
rest of wined3d uses it, without knowing the module's addresses beforehand:

  - the module region is taken around the qemu-3dfx exports (wined3d_hal_3dfx,
    wined3d_passthru, ...);
  - every function in that region called from outside it is named by
    fingerprint against the internals identified in 1.8.7 and 8.0.2
    (tests/emu/test_module.py);
  - every module global read from outside the region is listed (the core
    reads some config values and latches directly);
  - each external call site / read is shown with its enclosing function,
    named against <symbols.dll> (a build of the same Wine version that kept
    its symbol table) when given.
"""
import os, re, sys, struct, importlib.util
here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('funcmatch', os.path.join(here, 'funcmatch.py'))
fm = importlib.util.module_from_spec(spec); spec.loader.exec_module(fm)

REF = os.path.join(here, '..', '..', 'tests', 'emu', 'reference')
KNOWN = {
    '1.8.7': dict(display_roi=0x10029473, override_mode=0x100294a2, swap_interval=0x1002954b,
                  scale_window=0x1002987b, latch0=0x10029431, latch1=0x10029447,
                  latch2=0x1002945d, is_qemu_bochs=0x100290fc, set_host_cursor=0x10029561,
                  cursor_sync=0x10029592),
    '8.0.2': dict(display_roi=0x1004f476, override_mode=0x1004f4a5, swap_interval=0x1004f54e,
                  scale_window=0x1004f8db, latch0=0x1004f434, latch1=0x1004f44a,
                  latch2=0x1004f460, is_qemu_bochs=0x1004ee85, set_host_cursor=0x1004f5a8,
                  cursor_sync=0x1004f5d9, sysmem_quirk=0x1004f563),
}
QEXPORTS = re.compile(r'^wined3d_(hal_3dfx|enum_hal_last|passthru|override_cooplevel|'
                      r'override_rendertarget_view|blit_fpslimit|flip_fpslimit|surface_ddheap)$')


def known_fingerprints():
    out = []
    for ver, names in KNOWN.items():
        img = fm.Image(os.path.join(REF, ver, 'wined3d.dll'))
        for n, a in names.items():
            s, e = img.bounds_guess(a)
            f, k = img.fingerprint(a, e)
            out.append((n, ver, f, k))
    return out


def main():
    path = sys.argv[1]
    named = None
    if '--named' in sys.argv:
        named = fm.Image(sys.argv[sys.argv.index('--named') + 1], symbols=True)
    img = fm.Image(path)
    exp = [a for a, n in img.ex.items() if QEXPORTS.match(n)]
    lo, hi = min(exp) - 0x1000, max(exp) + 0x1000
    inside = lambda a: lo <= a < hi
    targets = {}
    reads = {}
    module_globals = set()
    for a, t in img.lines:
        if inside(a):
            for g in re.findall(r'0x(1[0-9a-f]{7})\b', t):
                module_globals.add(int(g, 16))
    for a, t in img.lines:
        m = re.match(r'call\s+([0-9a-f]+)', t)
        if m:
            d = int(m.group(1), 16)
            if inside(d) and not inside(a) and d not in img.ex:
                targets.setdefault(d, []).append(a)
        if not inside(a):
            for g in re.findall(r'0x(1[0-9a-f]{7})\b', t):
                g = int(g, 16)
                if g in module_globals and not (lo <= g < hi) and not t.startswith(('call', 'jmp')):
                    reads.setdefault(g, []).append(a)
    kfp = known_fingerprints()

    def enclosing(a):
        s, e = img.bounds_guess(a)
        if not named:
            return '%x' % s
        f, k = img.fingerprint(s, e)
        best = max(((fm.sim(f, g, k, m), n) for n, _, (g, m) in
                    [(n, x, named.fingerprint(x, y)) for n, x, y in named.ranges()]), default=(0, '?'))
        return '%x %s %.2f' % (s, best[1], best[0])

    cache = {}
    def enc(a):
        s, _ = img.bounds_guess(a)
        if s not in cache:
            cache[s] = enclosing(a)
        return cache[s]

    print('module region %x-%x (%d qemu-3dfx exports)' % (lo, hi, len(exp)))
    for d in sorted(targets):
        s, e = img.bounds_guess(d)
        f, k = img.fingerprint(d, e)
        best = sorted(((fm.sim(f, g, k, m), n, v) for n, v, g, m in kfp), reverse=True)[:2]
        print('== %x  ~ %s' % (d, '  '.join('%s(%s) %.2f' % (n, v, sc) for sc, n, v in best)))
        for a in targets[d]:
            print('     call %x  in %s' % (a, enc(a)))
    for g in sorted(reads):
        print('== global %x read from outside' % g)
        for a in reads[g]:
            print('     ref  %x  in %s' % (a, enc(a)))


if __name__ == '__main__':
    main()
