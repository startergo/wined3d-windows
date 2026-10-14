#!/usr/bin/env python3
"""placement.py <symbols.dll> <callee regex>

For a build that kept its COFF symbol table (/build/wined3d.dll or
/build/winedd.dll from the Docker image), list every function that calls a
callee matching <callee regex> — internal functions by symbol name, imports
by their DLL!name (direct or through a jmp thunk).  Used to check that our
call-site placement matches the reference's (see CALLSITES.md).

  placement.py re-work/wined3d-6.0.4-symbols.dll '^qemu3dfx_'
  placement.py re-work/ddraw-6.0.4-symbols.dll 'wined3d_(hal_3dfx|passthru|.*fpslimit)|qemu3dfx_ddthru$'
"""
import os, re, sys, bisect, importlib.util
here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('funcmatch', os.path.join(here, 'funcmatch.py'))
fm = importlib.util.module_from_spec(spec); spec.loader.exec_module(fm)


def main():
    img = fm.Image(sys.argv[1], symbols=True)
    rx = re.compile(sys.argv[2])
    targets = {a: n for a, n in img.syms.items() if rx.search(n)}
    for a, n in img.thunks.items():
        short = n.split('!')[-1].split('@')[0]
        if rx.search(short):
            targets[a] = short
    iat = {a: n.split('!')[-1].split('@')[0] for a, n in img.iat.items()}
    out = {}
    for a, t in img.lines:
        name = None
        m = re.match(r'call\s+([0-9a-f]+)', t)
        if m and int(m.group(1), 16) in targets:
            name = targets[int(m.group(1), 16)]
        m = re.match(r'call\s+\*0x([0-9a-f]+)', t)
        if m and rx.search(iat.get(int(m.group(1), 16), '')):
            name = iat[int(m.group(1), 16)]
        if not name:
            continue
        fn = img.syms[img.starts[bisect.bisect_right(img.starts, a) - 1]]
        if rx.search(fn):
            continue                        # calls inside the matched set itself
        out.setdefault(name, set()).add(fn)
    for k in sorted(out):
        print('%-36s <- %s' % (k, ', '.join(sorted(out[k]))))


if __name__ == '__main__':
    main()
