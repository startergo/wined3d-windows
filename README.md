# Wine D3D DLLs for qemu-3dfx

> **Status: Alpha** — builds are functional but not yet tested end-to-end
> with qemu-3dfx passthrough. API stubs and compatibility shims are still
> being validated on target platforms (Win98 SE).

Cross-builds Wine's DirectDraw, Direct3D 8, Direct3D 9, and wined3d DLLs as
standalone 32-bit Windows binaries using MinGW-w64. Designed for use with
[qemu-3dfx](https://github.com/kjliew/qemu-3dfx) to provide hardware-accelerated
3dfx OpenGL passthrough for Windows guests running inside QEMU.

## Built DLLs

Each Wine version produces four D3D DLLs, all linked against `msvcrt.dll` (not
`ucrtbase.dll`) with statically linked `libwine` and no `libwine.dll` runtime
dependency:

| DLL | Description |
|-----|-------------|
| `wined3d.dll` | Wine's Direct3D translation layer + qemu-3dfx passthrough hooks |
| `d3d9.dll` | Direct3D 9 |
| `d3d8.dll` | Direct3D 8 |
| `ddraw.dll` | DirectDraw + VidMem HAL stubs + passthrough bridge |
| `msvcrt.dll` | C runtime (Wine 6.0.4 only) |

All DLLs target Windows 98 SE compatibility: Vista+ kernel32 APIs
(GetModuleHandleExW, Condition Variables, etc.), UCRT functions
(__stdio_common_*), and CRT startup functions (_initterm_e) are stubbed
out with Win98-compatible fallbacks.

## Supported Wine Versions

| Version | Build Mode | Source |
|---------|-----------|--------|
| 1.8.7 | legacy | tar.bz2 |
| 1.9.7 | legacy | tar.bz2 |
| 2.0.5 | legacy | tar.xz |
| 3.0.5 | legacy | tar.xz |
| 4.12.1 | legacy | tar.xz |
| 5.0.5 | legacy | tar.xz |
| 6.0.4 | legacy (+ msvcrt) | tar.xz |
| 7.0.2 | legacy | tar.xz |
| 8.0.2 | modern | tar.xz |

**Legacy mode** (Wine 1.x–7.x) uses the winegcc cross-compile toolchain.
The build manually drives Wine's tools (winebuild, widl, wrc, winegcc),
applies source patches for MinGW compatibility, and links against a stub
`libwine.a` to avoid runtime dependencies.

**Modern mode** (Wine 8.x+) uses Wine's native PE build system, which
directly targets `i386-windows/` DLL output via MinGW-w64.

## qemu-3dfx Passthrough Hooks

Custom code injected into the DLL builds to match the original qemu-3dfx
Wine patches. Full documentation in [`qemu-3dx-hooks.md`](qemu-3dx-hooks.md).

### wined3d.dll — 9 custom exports

Injected via `qemu3dfx_hooks.c`:

| Export | Purpose |
|--------|---------|
| `wined3d_hal_3dfx` | DirectDraw HAL enumeration — probes `\\.\QEMUchs` for 3dfx passthrough |
| `wined3d_enum_hal_last` | Returns HAL enumeration complete flag |
| `wined3d_surface_ddheap` | Returns DirectDraw surface heap active flag |
| `wined3d_passthru` | Set/get passthrough mode |
| `wined3d_override_cooplevel` | XORs `DDSCL_EXCLUSIVE` into cooperative level |
| `wined3d_override_rendertarget_view` | Sets bit 0x20 in `resource->access_flags` for passthrough RTV |
| `wined3d_blit_fpslimit` | Blit frame rate limiter |
| `wined3d_flip_fpslimit` | Flip frame rate limiter |
| `wined3d_get/set_gamma_ramp_3dfx` | WGL 3DFX gamma ramp wrappers |
| `wined3d_set_cursor_3dfx` | WGL 3DFX cursor wrapper |

Embedded strings: `QEMU` debug channel, registry keys `D3D1Hal3Dfx` /
`D3D1EnumHalLast`, WGL extension strings.

### ddraw.dll — 20 HAL stubs + standard exports + passthrough bridge

**HAL stubs and standard exports** via `qemu3dfx_ddraw_hooks.c`. No-op
stubs — the passthrough wrapper handles actual video memory management.
Signatures verified against NT 4.0 and XP SP1 DDK source code.

Wine's `@ stub` entries are not exported by winebuild, so the build
patches them to `@ stdcall`. Standard Windows ddraw.dll exports not in
Wine's spec are appended during the build.

| Export | Source |
|--------|--------|
| `VidMemAlloc` | dmemmgr.h |
| `VidMemFree` | dmemmgr.h |
| `VidMemInit` | dmemmgr.h |
| `VidMemFini` | dmemmgr.h |
| `VidMemAmountFree` | dmemmgr.h |
| `VidMemLargestFree` | dmemmgr.h |
| `DDHAL32_VidMemAlloc` | ddrawi.h |
| `DDHAL32_VidMemFree` | ddrawi.h |
| `HeapVidMemAllocAligned` | dmemmgr.h |
| `InternalLock` | ddrawpr.h |
| `InternalUnlock` | ddrawpr.h |
| `DDInternalLock` | ddrawpr.h (DD-prefixed name) |
| `DDInternalUnlock` | ddrawpr.h (DD-prefixed name) |
| `GetNextMipMap` | ddrawi.h |
| `LateAllocateSurfaceMem` | ddrawi.h |
| `DSoundHelp` | dddefwp.c (NT5) |
| `AcquireDDThreadLock` | Standard ddraw export |
| `ReleaseDDThreadLock` | Standard ddraw export |
| `CompleteCreateSysmemSurface` | Standard ddraw export |
| `D3DParseUnknownCommand` | Standard ddraw export |

**Passthrough bridge** via `qemu3dfx_ddraw_passthrough.c`. Bridges ddraw
to wined3d passthrough functions at key lifecycle points:

| Hook | Injection Point | Purpose |
|------|----------------|---------|
| Init | DllMain, after DisableThreadLibraryCalls | Detect qemu-3dfx, enable passthrough, mark HAL enum complete |
| Cooplevel | SetCooperativeLevel, after DDRAW_dump_cooperativelevel | Override cooperative level for passthrough fullscreen |
| Blit FPS | ddraw_surface_blt, before texture/device_context blit | Frame rate limiting on blit |
| Flip FPS | ddraw_surface_Flip, at DDSCAPS_FLIP init | Frame rate limiting on flip |
| RTV | Flip, after ddraw_surface_get_rendertarget_view | Mark render target for passthrough rendering |

## Architecture

```
Guest Application
    |
    v
ddraw.dll ──── passthrough bridge (qemu3dfx_ddraw_passthrough.c)
    |           ├── DllMain → detect qemu-3dfx, enable passthrough
    |           ├── SetCooperativeLevel → override coop level
    |           ├── Blit/Flip → FPS limiters
    |           └── RTV setup → mark for passthrough
    |
    |        ──── VidMem HAL stubs (qemu3dfx_ddraw_hooks.c)
    |           DDHAL32_VidMemAlloc, VidMemFree, etc.
    |
    v
wined3d.dll ─── probes \\.\QEMUchs, manages passthrough state
    |             loads WGL 3DFX extensions
    v
opengl32.dll (qemu-3dfx wrapper) → mesapt → Host GPU
```

## Win98 Compatibility

The build injects stubs and strips Vista+ imports so all DLLs load on
Windows 98 SE without missing-export errors:

| Issue | Versions Affected | Fix |
|-------|-------------------|-----|
| `_initterm_e` missing from msvcrt.dll | 4–5 | Local CRT stub + import lib stripping |
| `GetModuleHandleExW` missing from kernel32.dll | 6–8 | Source-level `#define` redirect to `wine_k32compat_GMHEW` |
| `__stdio_common_*` UCRT functions | 6–7 | UCRT compat stubs + import lib stripping |
| ntdll.dll import leaks | 6–7 | CRT stripping from Wine import libs |
| Missing `wined3d_enum_hal_last` call | 1–3 | Passthrough bridge init call |
| Missing standard ddraw exports | 1–8 | `@ stub` → `@ stdcall` + append spec entries |
| Flip sed pattern mismatch (DDSCAPS vs DDSCAPS2) | 6–8 | Regex flexibility: `DDSCAPS2\?` |
| Blit API change (texture_blt → device_context_blt) | 7–8 | Dual sed pattern fallback |

## Quick Start

### GitHub Actions (CI)

Push to `main` or use the **Run workflow** button under Actions. Each version
builds in parallel on `windows-latest` runners. Artifacts are uploaded
per-version and as a combined bundle.

```
gh workflow run build.yml
```

To build specific versions only:
```
gh workflow run build.yml -f versions="8.0.2 6.0.4"
```

### Local Build (Windows / MSYS2)

Open a **MINGW32** shell in MSYS2 and run:

```bash
pacman -S --needed mingw-w64-i686-gcc mingw-w64-i686-binutils \
    mingw-w64-i686-headers mingw-w64-i686-winpthreads mingw-w64-i686-crt \
    make flex bison wget git diffutils

bash build-ci.sh
```

### Local Build (Linux with MinGW cross-compiler)

```bash
bash build-ci.sh
```

The script auto-detects Linux and installs mingw-w64 dependencies via apt.

### Options

```
bash build-ci.sh --force                # rebuild all versions
bash build-ci.sh --versions 8.0.2 6.0.4 # build specific versions
```

Output goes to `./output/<version>/`:

```
output/
  1.8.7/
    wined3d.dll  d3d9.dll  d3d8.dll  ddraw.dll  build-timestamp
  8.0.2/
    wined3d.dll  d3d9.dll  d3d8.dll  ddraw.dll  build-timestamp
```

## Build Patches Applied

The legacy build path applies several patches to make Wine's source compile
cleanly with MinGW-w64:

- **aclocal.m4** — Fixes broken relative symlink path in import lib rules
  (`$ac_name/` → `dlls/$ac_name/`)
- **d3d8/d3d8_main.c** — Renames `bool` parameter to `bool_val` to avoid
  keyword conflict in C mode
- **winecrt0/debug.c** — Replaces `fwrite(stderr)` with `WriteFile()` for
  native Windows console output
- **Makefile sweep** — Strips `-fPIC` and `-fstack-protector` flags not
  applicable to Windows targets
- **libwine.a stub** — Provides stub implementations for `wine_dbg_*`,
  `wine_get_version`, and case-mapping functions so the DLLs have no
  runtime dependency on `libwine.dll`
- **msvcrt (Wine 6.x only)** — Backports `__stdio_common_*` printf stubs
  and patches `wcstok` signature for MinGW compatibility

## Files

```
build-ci.sh                  Standalone build script (MSYS2 / Linux)
qemu3dfx_hooks.c             Passthrough hooks for wined3d (9 exports)
qemu3dfx_ddraw_hooks.c       VidMem HAL stubs for ddraw (14 exports)
qemu3dfx_ddraw_passthrough.c  ddraw → wined3d passthrough bridge
qemu-3dx-hooks.md            Complete hooks reference documentation
PKGBUILD                     MSYS2/MinGW package build definition
.github/workflows/build.yml  GitHub Actions CI
```

## Credits

- [kjliew/qemu-3dfx](https://github.com/kjliew/qemu-3dfx) — QEMU fork with
  3dfx Voodoo passthrough, original Wine DLL hooks that this build replicates
- [Wine](https://www.winehq.org/) — upstream source for all D3D/DirectDraw DLLs
- [MinGW-w64](https://www.mingw-w64.org/) — Windows cross-compilation toolchain

## License

Wine is licensed under the GNU Lesser General Public License (LGPL).
See https://www.winehq.org/ for details.
