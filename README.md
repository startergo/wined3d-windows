# Wine D3D DLLs for qemu-3dfx

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
| `ddraw.dll` | DirectDraw + VidMem HAL stubs |
| `msvcrt.dll` | C runtime (Wine 6.0.4 only) |

All DLLs target Windows 98 SE compatibility (D3DKMT Vista+ imports and
`GetModuleHandleExW` are stubbed out with Win98-compatible fallbacks).

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
Wine patches.

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
| `wined3d_get_gamma_ramp_3dfx` | Wraps `wglGetDeviceGammaRamp3DFX` from wrapper opengl32.dll |
| `wined3d_set_gamma_ramp_3dfx` | Wraps `wglSetDeviceGammaRamp3DFX` |
| `wined3d_set_cursor_3dfx` | Wraps `wglSetDeviceCursor3DFX` |

Embedded strings: `QEMU` debug channel, registry keys `D3D1Hal3Dfx` /
`D3D1EnumHalLast`, WGL extension strings.

### ddraw.dll — 14 custom exports

Injected via `qemu3dfx_ddraw_hooks.c`. No-op stubs — the passthrough
wrapper handles actual video memory management. Signatures verified against
NT 4.0 and XP SP1 DDK source code:

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
| `GetNextMipMap` | ddrawi.h |
| `LateAllocateSurfaceMem` | ddrawi.h |
| `DSoundHelp` | dddefwp.c (NT5) |

## Architecture

```
Guest Application
    |
    v
ddraw.dll ---- imports wined3d_hal_3dfx, wined3d_passthru, etc.
    |                 |
    |                 v
    |           wined3d.dll --- probes \\.\QEMUchs
    |                 |          sets passthrough globals
    |                 |          overrides RTV access_flags
    |                 |          loads WGL 3DFX extensions
    |                 v
    |           opengl32.dll (qemu-3dfx wrapper: WRAPGL32.DLL)
    |                 |
    v                 v
VidMem HAL stubs   mesapt shared memory
(return 0/NULL)         |
                        v
                   Host GPU (3dfx OpenGL passthrough)
```

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
