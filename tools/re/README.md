# Reverse-engineering helpers

Small tools used to recover the qemu-3dfx additions from the reference
DLLs (`tests/emu/reference/`, see `tests/emu/README.md` for
how to extract them). They wrap `i686-w64-mingw32-objdump` and the PE parser
in `tools/win98-universe.py`; Python 3 standard library only.

| Tool | Use |
|------|-----|
| `xref.py <pe> [string] [f:export] [a:0xVA] [w:0xVA]` | disassembly around references to a string; full disassembly of an export or of the function at an address; every instruction touching a global |
| `annot.py <pe> <start> <stop> [--callers]` | annotated disassembly of a range: import calls resolved to `DLL!name`, string immediates decoded, globals labelled from `globals-<wine-version>.txt`; `--callers` lists who calls each function found |
| `callsites.py <pe> <DLL!sym-substring>... [--before=N] [--after=N]` | every call to an imported function (direct, via register, or via thunk) with context — e.g. where ddraw.dll calls `WINED3D.DLL!wined3d_blit_fpslimit` |

Related tools one level up:

- `tools/win98-calldiff.py --dirs <reference-dir> <our-dir>` — per DLL, the
  imported functions each side calls (with call-site counts) and every
  `GetProcAddress`/`LoadLibrary`/`GetModuleHandle` string argument.
- `tools/win98-universe.py check <dlls...>` — imports that a stock Win98 SE
  system cannot resolve, including DLLs shadowed by app-local copies.

Examples:

```sh
R=tests/emu/reference
tools/re/xref.py $R/1.8.7/wined3d.dll D3D1Hal3Dfx f:wined3d_hal_3dfx
tools/re/annot.py $R/8.0.2/wined3d.dll 1004f434 1004f990 --callers
tools/re/callsites.py $R/8.0.2/ddraw.dll WINED3D.DLL!wined3d_ WINED3D.DLL!wined3d_passthru
```

`globals-1.8.7.txt` / `globals-8.0.2.txt` name the qemu-3dfx configuration
globals of those builds; add a file per version as more are mapped.
