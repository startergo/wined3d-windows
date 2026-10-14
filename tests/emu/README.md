# Emulator differential tests

These tests run **our code and the qemu-3dfx reference binaries side by side
in an x86 emulator** and compare what they do: return values, memory writes,
and the Windows API calls they make. They need no Windows, Wine, Docker or VM.

The qemu-3dfx project ships prebuilt Wine DLLs but has never
published the modified Wine source. Everything our build re-creates from those
binaries — the qemu-3dfx module in `qemu3dfx_hooks.c`, the Win9x D3DKMT layer
in `docker/d3dkmt_stubs.c` — is checked here against the original machine code.

| Test | Ours | Reference | What is compared |
|---|---|---|---|
| `test_module.py` | `qemu3dfx_hooks.c` | qemu-3dfx module inside `wined3d.dll` 1.8.7 and 8.0.2 | the 8 `wined3d_*` exports and every internal helper, under 20 registry configurations × 5 executable names; adapter detection; host-cursor channel; Silent Hill 4 quirk |
| `test_ddraw.py` | `qemu3dfx_ddraw_hooks.c` | `ddrawwq.dll` forwarders in `ddraw.dll` 8.0.2 | `DDInternalLock`/`Unlock`, `D3DParseUnknownCommand`, `CompleteCreateSysmemSurface`, `Acquire`/`ReleaseDDThreadLock` with `ddrawwq.dll` absent, complete, or missing core/optional exports: return values, forwarded calls and arguments, load/unload sequence |
| `test_d3dkmt.py` | `docker/d3dkmt_stubs.c` | `D3DKMT*` in `wined3d.dll` 2.0.5 … 8.0.2 | `CreateDCFromMemory`/`DestroyDCFromMemory` for all 9 surface formats and several pitches: `BITMAPINFO`, copy-in, copy-back, cleanup, bookkeeping list, GDI failure paths; stub return codes |

Current baseline: **module 1918 checks, ddraw 42 checks, D3DKMT 3815 checks, 0 failures.**

## Requirements

- Python 3 with [Unicorn](https://www.unicorn-engine.org/): `python3 -m pip install --user unicorn`
- `i686-w64-mingw32-gcc` (macOS: `brew install mingw-w64`; Debian/Ubuntu: `apt install gcc-mingw-w64-i686`)
- 7-Zip (`7zz` or `7z`) to extract the reference DLLs (`brew install sevenzip` / `apt install 7zip`)

## Setup (once)

The reference DLLs are third-party binaries and are not committed. Extract
them from the qemu-3dfx add-ons bundle (`.tar.zst`) or its ISO image:

```sh
tests/emu/extract-reference.sh /path/to/bundle.tar.zst
# or, from the ISO directly:
tests/emu/extract-reference.sh /path/to/image.iso
```

This creates `tests/emu/reference/<wine-version>/{wined3d,d3d8,d3d9,ddraw}.dll`.
Point `QEMU3DFX_REF` at another directory to test against a different set.

## Running

```sh
make test-emu                 # build test DLLs + run everything
tests/emu/run.sh              # same
tests/emu/run.sh module       # only qemu3dfx_hooks.c
tests/emu/run.sh ddraw        # only qemu3dfx_ddraw_hooks.c
tests/emu/run.sh d3dkmt       # only d3dkmt_stubs.c

python3 tests/emu/test_module.py internals     # one suite
python3 tests/emu/test_d3dkmt.py 8.0.2 6.0.4   # selected Wine versions
```

`run.sh` first calls `build.sh`, which compiles:

- `build/hooks-<maj>.<min>.dll` — `qemu3dfx_hooks.c` for every Wine version
  the Docker build supports (with `-Werror`, so it doubles as a compile check);
- `build/d3dkmt-ref.dll` — `d3dkmt_stubs.c` with `-DQEMU3DFX_D3DKMT_REFERENCE_PALETTE`
  for bit-exact comparison, and `build/d3dkmt.dll` as shipped;
- `build/ddraw-hooks.dll` — `qemu3dfx_ddraw_hooks.c`, importing the wined3d
  mutex from a generated `wined3d.dll` import library.

A failing check prints the label and both values:

```
  FAIL 8.0.2 {...} exe=GAME.EXE rtv
       ref =(...)
       ours=(...)
```

## How it works

`emu.py` is a small Win32 user-mode emulator on Unicorn:

- **PE loader.** Each DLL is mapped at its preferred base (reference
  `wined3d.dll` at `0x10000000`, our test DLLs at `0x20000000`), so both live
  in one address space. No relocation is needed.
- **Imports are Python.** Every import is bound to a stub address; executing
  it runs `api_<Name>` in `emu.py` and returns to the caller with the correct
  stdcall/cdecl stack cleanup. Unknown imports return 0 (use
  `Emu(env, trace_unknown=True)` to log them).
- **One shared environment.** An `Env` dict defines the registry
  (`registry={'def': {...}, 'app': {...}}`, `str` = `REG_SZ`, `int` =
  `REG_DWORD`), executable path, display adapter string, a scripted
  `GetTickCount` clock, cursor state, window/client rects, loaded modules
  (`GetModuleHandleA`), and GDI failure injection (`gdi_fail='dc'|'dib'|'bits'`).
  Both sides of a comparison get identical copies.
- **Real initialisation for the reference.** `test_module.py` runs the
  reference `DllMain(DLL_PROCESS_ATTACH)` so its own `wined3d_dll_init`
  reads the fake registry. The configuration comparison therefore does not
  depend on our reading of the disassembly.
- **CPU state.** Flat 32-bit GDT segments, an `FS` segment with a minimal TEB
  (MinGW's CRT startup reads it), a private stack, and a bump-allocated heap.
- **Logging.** Every handled API call is appended to `emu.log`; tests compare
  the filtered sequence (e.g. `Sleep`/`GetTickCount` for the FPS limiter,
  `glDebugMessageInsertARB` payloads for the cursor channel).

### Calling reference internals

Internal reference functions are called by address. Tables at the top of each
test give them per Wine version, e.g. in `test_module.py`:

```python
REF802_INTERNAL = dict(display_roi=0x1004f476, override_mode=0x1004f4a5, ...)
```

Addresses come from the reverse-engineering helpers in `tools/re/`
(`annot.py`, `xref.py`, `callsites.py`); each implementation in
`qemu3dfx_hooks.c` / `d3dkmt_stubs.c` cites the reference address it was
derived from.

### Adding a test

1. Find the reference function (`tools/re/annot.py <dll> <start> <stop> --callers`).
2. Export the corresponding function from our code (the test DLLs are linked
   with `--export-all-symbols`).
3. Write a suite: create a `Side`/`Emu` for each, call both with the same
   arguments, `compare()` results and memory.
4. If the code calls a Windows API the emulator doesn't know yet, add an
   `api_<Name>` method to `emu.py` (and its argument count to `NARGS` if it is
   stdcall).

## Known, intentional differences

These are excluded from the comparison or tested with a reference-behaviour
build, and documented in the sources:

- `d3dkmt_stubs.c` fills the output handles/LUIDs of the adapter "success"
  stubs; the reference leaves them uninitialised.
- `d3dkmt_stubs.c` copies the P8 palette into the DIB. The reference builds a
  52-byte `BITMAPINFO` on the stack, so `CreateDIBSection` reads its 256
  palette entries from stack garbage. The bit-exact test compares only the
  defined part.
- `qemu3dfx_ddraw_hooks.c` returns `E_NOTIMPL` when `ddrawwq.dll` lacks an
  optional export (the reference calls through a NULL pointer), and falls
  back to the wined3d mutex for `Acquire`/`ReleaseDDThreadLock` without
  `ddrawwq.dll` (the reference does nothing). `test_ddraw.py` asserts both.
- The reference stores the DLL instance handle in the first latch from
  `DllMain`; `test_module.py` performs the same call for our side, mirroring
  the call site that wined3d's `DllMain` must make.
