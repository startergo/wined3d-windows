# The Win98 Runtime Universe — Missing-Export Class

Win98 counterpart of `leopard-webkit-build/tools/10.6-runtime-universe.txt`
and its selector sweep (`SELECTOR-SWEEP.md` there).

On 10.6 the failure class is a selector the runtime doesn't have
(`doesNotRecognizeSelector:` → abort), only discoverable at send time, so
the universe there is a `strings` dump used as a cheap pre-filter.

On Win98 the failure class is an **import the system doesn't export**, and
it fails at load time, all-or-nothing:

- an EXE won't start: *"The FOO.EXE file is linked to missing export
  KERNEL32.DLL:GetFileSizeEx"*;
- a DLL's `LoadLibrary` returns NULL (the app usually just reports the
  DLL as "not found" — e.g. our d3d9.dll silently falling back);
- a delay-loaded import faults on first call instead.

Typical sources: a newer mingw/MSVC CRT pulling in NT-only APIs, Wine code
that grew a 2000/XP call, `ucrtbase.dll`/`api-ms-win-*` imports (absent on
9x entirely — what `docker/patch_pe_win98.py` exists to rewrite).

This is decided purely by PE export tables, so the universe is built from
**export tables, not strings**. That makes it exact rather than a
pre-filter: no colon artifacts, no 4-char `strings` cutoff, ordinal-only
exports included.

## 1. The universe files

| File | What |
|---|---|
| `tools/win98-runtime-universe.txt` | every export of every 32-bit PE module in `WINDOWS\SYSTEM` + `WINDOWS`, `LC_ALL=C` sorted |
| `tools/win98-runtime-universe.manifest` | one line per module: FileVersion, size, md5, export count, `NON-STOCK?` flag |

Line format:

    KERNEL32.DLL!CreateFileA                 named export
    KERNEL32.DLL!#17                         every ordinal (ordinal imports)
    FOO.DLL!Bar -> NTDLL.Baz                 forwarder
    FOO.DLL!                                 module present, exports nothing

Module names are upper-cased (the 9x loader is case-insensitive on module
names); export names keep their case (lookup is case-sensitive).

Quick lookups:

    grep -xF 'KERNEL32.DLL!GetFileSizeEx' tools/win98-runtime-universe.txt   # absent on 98
    grep '^USER32.DLL!GetMonitorInfo' tools/win98-runtime-universe.txt        # present (98+)

## 2. What it was generated from — read this before trusting a verdict

Unlike 10.6.8, **Win98 installs are not identical**. The 10.6 universe is
the same on every 10.6.8 box; a Win98 universe is the union of 98SE plus
whatever DirectX/IE/WMP/runtime redistributables and wrappers that machine
has. Current file: the qemu-3dfx VM disk
(`qemu-3dfx-3-2/win98/win98.qcow2`), scanned 2026-10-13:

- Core OS: stock **Windows 98 SE** — KERNEL32 4.10.2222, USER32 4.10.2231,
  GDI32 4.10.1998, ADVAPI32 4.80.1675, MSVCRT 6.0.8397.
- Installed on top (flagged `NON-STOCK?` in the manifest — linked after
  2003): DirectX 9.0c (4.9.0.904) incl. D3DX9_24..31, WMP 9/10 codecs,
  .NET 2.0, VC8 runtime (MSVCR80/MSVCP80), MSXML 3/4, IE6-era ADVPACK.
- **Wrappers, not Microsoft**: `DDRAW.DLL` and `DSOUND.DLL` (linked
  2023, ~20 KB; the real DX9 modules sit beside them as `DDRAWWQ.DLL` /
  `DSOUNDWQ.DLL`) and `GLIDE.DLL`/`GLIDE2X.DLL`/`GLIDE3X.DLL` (qemu-3dfx,
  linked 2026-05-02).

Consequences:

- A **MISSING** verdict against KERNEL32/USER32/GDI32/ADVAPI32/MSVCRT is
  a real 98SE fact — those are stock.
- A **present** verdict for a DX9/VC8/.NET/MSXML module only holds on a
  machine with that redistributable installed. Ask whether the target
  user will have it.
- `DDRAW.DLL`/`DSOUND.DLL` reflect the wrapper (16 / 12 exports), not
  Microsoft's. For a "what does real DirectX export" universe, regenerate
  with `--exclude DDRAW.DLL DSOUND.DLL` and look at `DDRAWWQ.DLL` /
  `DSOUNDWQ.DLL` lines instead.
- Plain Win98 (first edition) or a KernelEx-patched install gives a
  different answer — regenerate from that disk.

## 3. Regenerate

From the VM disk (VM shut down; the image is only read):

    tools/win98-universe.sh ~/Downloads/qemu-3dfx-3-2/win98/win98.qcow2

From any other Win98 image or an extracted `WINDOWS` folder:

    tools/win98-universe.sh /path/to/win98.img
    tools/win98-universe.sh /path/to/WINDOWS
    tools/win98-universe.sh disk.qcow2 --exclude DDRAW.DLL DSOUND.DLL

7-Zip (`7z`/`7zz`) reads qcow2/vhd/vmdk/raw and walks MBR→FAT32 itself —
no `qemu-img convert`, no mounting. Only python3 stdlib is needed (no
`pefile`).

## 4. Checking our binaries

    tools/win98-universe.py check output/6.0.4/*.dll

Verdicts per import (normal and delay-load):

| Verdict | Meaning | Action |
|---|---|---|
| `MISSING` | module exists on Win98, symbol doesn't | real load failure — fix |
| `UNKNOWN-DLL` | module not on Win98 at all | fine if we ship it (`wined3d.dll`); fatal if not (`ucrtbase.dll`, `api-ms-win-*`) |
| `FAILS-VIA` | its own imports are fine, but an app-local DLL it imports can't load | fix that DLL (the loader aborts the whole chain) |
| `OK` | every import resolves | — |

**Pass the whole set you deploy in one `check` call.** The 9x loader looks
in the application's folder before `WINDOWS\SYSTEM`, so every file given to
`check` is treated as app-local: a shipped `msvcrt.dll` *shadows* the stock
MSVCRT and imports resolve against it (reported as a `NOTE ... SHADOW`
line). Checking files one at a time hides exactly this failure.

`--system-only` hides UNKNOWN-DLL lines; `--strict` makes them fail too.
Exit code 1 on any MISSING — usable as a CI/Docker post-build gate right
after `patch_pe_win98.py`.

Baseline (2026-10-13), each `output/<ver>/` checked as one deployed set:

- 1.8.7 … 5.0.5, 7.0.2, 8.0.2: all OK against stock Win98 SE.
- **6.0.4: FAILED (fixed).** It was the only entry built with `BUILD_MSVCRT=1`; the
  Wine-built `msvcrt.dll` shadows Win98's and imports 12 symbols 98 lacks
  (`GetFileSizeEx`, `DelayLoadFailureHook`, `ResolveDelayLoadedAPI`,
  `VerifyConsoleIoHandle`, `NTDLL!NtQuerySystemTime`, `Rtl*Bits`,
  `RtlTimeToSecondsSince1970`, `LdrAddRefDll`, `__wine_init_unix_lib`, and
  `__wine_dbg_strdup`, which `patch_msvcrt.py` redirects to on the false
  assumption that NTDLL exports it). `wined3d.dll` → `FAILS-VIA MSVCRT.DLL`,
  and d3d8/d3d9/ddraw → `FAILS-VIA WINED3D.DLL`. Without the bundled
  msvcrt, all four resolve against stock MSVCRT 6.0.8397 — `build-docker.sh`
  now builds 6.0.4 with `BUILD_MSVCRT=0`, and the rebuilt DLLs pass.

Helpers: `win98-universe.py exports X.DLL`, `win98-universe.py imports X.DLL`.

## 5. What the universe can't see (the Win98 "runtime probe" cases)

The 10.6 sweep's ground truth is a live probe; Win98 has the same gap in
two places:

1. **Exported stubs.** 9x KERNEL32 exports many Unicode/NT APIs that just
   return `ERROR_CALL_NOT_IMPLEMENTED` (e.g. most `*W` file APIs,
   `CreateFileW` included). The import resolves, so the universe says
   present — but the call fails at runtime. When a `*W` or NT-flavored call
   shows up in a 9x code path, assume stub until tested in the VM.
2. **Runtime lookups.** `GetProcAddress`/`LoadLibrary` strings never appear
   in the import table. `grep` the universe for the name by hand; that is
   the strings-diff analogue and is exactly what the 10.6 method does.

Fix pattern for (1)/(2) mirrors the 10.6 probe-and-fallback: resolve with
`GetProcAddress`, fall back to the `*A`/9x path when NULL or when the call
fails with `ERROR_CALL_NOT_IMPLEMENTED`.
