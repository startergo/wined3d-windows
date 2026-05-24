# Wine D3D DLLs for qemu-3dfx

Cross-builds Wine's DirectDraw, Direct3D 8, Direct3D 9, and wined3d DLLs as
standalone 32-bit Windows binaries using MinGW-w64 + the wine9x-support
build system. Designed for use with
[qemu-3dfx](https://github.com/kjliew/qemu-3dfx) to provide hardware-accelerated
3dfx OpenGL passthrough for Windows 98 guests running inside QEMU.

## Built DLLs

Each Wine version produces four D3D DLLs:

| DLL | Description |
|-----|-------------|
| `wined3d.dll` | Wine's Direct3D translation layer + qemu-3dfx passthrough hooks |
| `ddraw.dll` | DirectDraw + VidMem HAL stubs + ddrawwq.dll passthrough bridge |
| `d3d8.dll` | Direct3D 8 |
| `d3d9.dll` | Direct3D 9 |

All DLLs target Windows 98 SE compatibility with PE headers patched for
Win98 loading.

## Supported Wine Versions

| Version | Group | wined3d .c count | Notes |
|---------|-------|-------------------|-------|
| 1.8.7 | A | 26 | Same generation as wine9x-support (1.7.55) |
| 1.9.7 | A | 26 | Same structure as 1.8.7 |
| 2.0.5 | A | 26 | Same structure as 1.8.7 |
| 3.0.5 | B | 26 | Same as Group A |
| 4.12.1 | C | 27 | +adapter_gl.c, adapter_vk.c |
| 5.0.5 | C | 27 | +adapter_gl.c, adapter_vk.c |
| 6.0.4 | D | 30 | +context_gl.c, context_vk.c, shader_spirv.c |
| 7.0.2 | D | 30 | +context_gl.c, context_vk.c, shader_spirv.c |
| 8.0.2 | D | 30 | +context_gl.c, context_vk.c, shader_spirv.c |

All versions download the Wine source tarball, extract wined3d/ddraw/d3d8/d3d9
.c/.h files, and apply compatibility patches before building with the
wine9x-support Makefile and direct MinGW gcc compilation. The wine9x-support
directory provides the build infrastructure (Makefile, headers, compat layers) —
the actual DLL source comes from the Wine tarball.

## qemu-3dfx Passthrough Hooks

Custom code injected into the DLL builds, reverse-engineered from the
reference qemu-3dfx Wine 1.8.7 DLLs. Full documentation in
[`qemu-3dx-hooks.md`](qemu-3dx-hooks.md).

### wined3d.dll — 7 custom exports

| Export | Purpose |
|--------|---------|
| `wined3d_hal_3dfx` | HAL detection: checks exe name (ds9dw.exe) via GetModuleFileNameA, then probes display adapter for "QEMU Bochs" via EnumDisplayDevicesA |
| `wined3d_enum_hal_last` | Returns HAL enumeration complete flag (default TRUE) |
| `wined3d_passthru` | Set/get passthrough mode |
| `wined3d_override_cooplevel` | XORs flags into cooperative level for passthrough |
| `wined3d_override_rendertarget_view` | Sets bit 0x01 at offset 0x28 in resource access_flags |
| `wined3d_blit_fpslimit` | Blit frame rate limiter (GetTickCount + Sleep) |
| `wined3d_flip_fpslimit` | Flip frame rate limiter (GetTickCount + Sleep) |

### ddraw.dll — 20 HAL stubs + 6 COM helpers + ddrawwq.dll switcher

**HAL stubs** via `qemu3dfx_ddraw_hooks.c`: No-op stubs for VidMem
management, surface locking, DSound, and standard ddraw exports. Also
provides `AcquireDDThreadLock`/`ReleaseDDThreadLock` (forwarding to
wined3d mutex), `D3DParseUnknownCommand`, `DDInternalLock`/`DDInternalUnlock`,
and `CompleteCreateSysmemSurface`. The passthrough wrapper handles actual
video memory.

**ddrawwq.dll switcher** via `qemu3dfx_ddraw_passthrough.c`: At DllMain,
loads `ddrawwq.dll` (the system's original ddraw renamed by ddthru) and
forwards DirectDraw calls when qemu-3dfx HAL is active.

## Architecture

```
Guest Application
    |
    v
ddraw.dll ──── passthrough bridge (qemu3dfx_ddraw_passthrough.c)
    |           ├── DllMain → detect qemu-3dfx, load ddrawwq.dll, enable passthrough
    |           ├── DirectDrawCreate → forwards to ddrawwq.dll
    |           ├── SetCooperativeLevel → override coop level
    |           ├── Blit/Flip → FPS limiters
    |           └── RTV setup → mark for passthrough
    |
    |        ──── VidMem HAL stubs (qemu3dfx_ddraw_hooks.c)
    |           DDHAL32_VidMemAlloc, VidMemFree, etc.
    |
    v
wined3d.dll ─── HAL detection (exe name + "QEMU Bochs" adapter), manages passthrough state
    v
opengl32.dll (qemu-3dfx wrapper) → mesapt → Host GPU
```

## Build

### Docker (recommended)

```bash
# Clone with submodules (or init after clone)
git clone --recurse-submodules https://github.com/startergo/wined3d-windows.git
# If already cloned:
git submodule update --init --recursive

# Build Wine 1.8.7
bash build-docker.sh --version 1.8.7

# Build Wine 6.0.4
bash build-docker.sh --version 6.0.4

# Or use docker build directly:
bash build-docker.sh --progress=plain
```

Extract output DLLs from the image:
```bash
docker create --name extract wined3d-1.8.7
docker cp extract:/output/1.8.7 ./output/1.8.7
docker rm extract
```

### Build Groups

| Group | Versions | WINE_BRANCH | WINE_EXT |
|-------|----------|-------------|----------|
| A | 1.8.7, 1.9.7, 2.0.5 | 1.8, 1.9, 2.0 | tar.bz2, tar.xz |
| B | 3.0.5 | 3.0 | tar.xz |
| C | 4.12.1, 5.0.5 | 4.12, 5.0 | tar.xz |
| D | 6.0.4, 7.0.2, 8.0.2 | 6.0, 7.0, 8.0 | tar.xz |

### Local Build (Linux with MinGW cross-compiler)

```bash
bash build-ci.sh
```

### Options

```
bash build-ci.sh --force                # rebuild all versions
bash build-ci.sh --versions 1.8.7 6.0.4 # build specific versions
```

Output goes to `./output/<version>/`:

```
output/
  1.8.7/
    wined3d.dll  d3d9.dll  d3d8.dll  ddraw.dll  build-timestamp
```

## Win98 Compatibility Patches

| Issue | Fix |
|-------|-----|
| W-version display APIs not on Win98 | Patch GetVersionExW→A, ChangeDisplaySettingsExW→A, EnumDisplayDevicesW→A, EnumDisplaySettingsW→A, EnumDisplaySettingsExW→A in Wine source |
| CRT security cookie imports (GetCurrentProcessId, GetTickCount, TerminateProcess) | asm no-op overrides in kernel32_compat.c |
| GetSystemTimeAsFileTime not on Win98 | Wrapper using GetSystemTime + SystemTimeToFileTime in kernel32_compat.c |
| GetModuleHandleExW not on Win98 | VirtualQuery-based wrapper in kernel32_compat.c |
| HeapCreate not on Win98 | Stub returning GetProcessHeap() in kernel32_compat.c |
| __chk_fail calling TerminateProcess | Patched to no-op in pthread9x/extra/crtfix.c |
| GetCurrentThreadId in debug logging | Patched to 0 in compact/debug.c |
| Static CRITICAL_SECTION_DEBUG init | Runtime InitializeCriticalSection in wined3d_main.c |
| Window class needs CS_OWNDC | Added CS_OWNDC flag to wined3d window class registration |
| EXCEPTION_REGISTRATION_RECORD Prev vs Next | Copy Wine's exception.h, patch frame->Prev→frame->prev |
| Vulkan backend not needed on Win98 | Stub all VK functions via vk_stubs.c |
| vkd3d library (Wine 8.0+) not needed | Remove includes, callbacks, and debug channels from wined3d_main.c |
| WGL query renderer extensions missing | Remove USE_GL_FUNC entries, null out supported[] blocks |
| GL extension naming mismatch | Add EXT suffix (glPolygonOffsetClamp→EXT, GL_TEXTURE_MAX_ANISOTROPY→_EXT) |
| Wine debug/log symbols in ddraw | Stub via libwine_stubs.c (atexit, wine_get_version, __wine_dbg_*) |
| AllocateLocallyUniqueId fails on Win98 | Time-based LUID fallback |
| PE header incompatibility | patch_pe_win98.py post-processing |
| Import name decorations | strip_import_decorations.py post-processing |

## Files

```
Dockerfile                    Docker build (all versions via WINE_VERSION arg)
build-ci.sh                   Standalone build script (Linux)
qemu3dfx_hooks.c              Passthrough hooks for wined3d (7 exports)
qemu3dfx_ddraw_hooks.c        VidMem HAL stubs + COM helpers for ddraw (26 exports)
qemu3dfx_ddraw_passthrough.c  ddraw → wined3d passthrough bridge + ddrawwq.dll switcher
docker/
  kernel32_compat.c           Win98-compatible stubs (security cookie, GetSystemTimeAsFileTime, etc.)
  copysign.c                  _copysign implementation
  nocrt_entry.c               Minimal DLL entry point (DllMainCRTStartup bypass)
  vk_stubs.c                  Vulkan stub functions (never called on Win98)
  libwine_stubs.c             Wine debug/log stubs for ddraw (atexit, wine_get_version, __wine_dbg_*)
  d3dkmt_stubs.c              D3DKMT adapter enumeration stubs
  mingwex_stubs.c             MinGW math stubs
  patch_pe_win98.py           PE header patching for Win98
  strip_import_decorations.py Strip @N from PE import names
wine9x-support/               Wine 1.7.55 build infrastructure
  Makefile                    Build system template (compiles all four DLLs)
  compact/                    Compatibility helpers (debug.c, exception.asm)
  pthread9x/                  Threading library for Win9x
  include/                    Patched Wine headers
  mingw/                      MinGW-specific headers
  wined3d/                    Wine 1.7.55 wined3d reference source
  ddraw/                      ddraw reference source
  d3d8/                       d3d8 reference source
  d3d9/                       d3d9 reference source
```

## Credits

- [kjliew/qemu-3dfx](https://github.com/kjliew/qemu-3dfx) — QEMU fork with
  3dfx Voodoo passthrough, original Wine DLL hooks that this build replicates
- [Wine](https://www.winehq.org/) — upstream source for all D3D/DirectDraw DLLs
- [MinGW-w64](https://www.mingw-w64.org/) — Windows cross-compilation toolchain
- wine9x-support — Win9x-compatible Wine build infrastructure

## License

Wine is licensed under the GNU Lesser General Public License (LGPL).
See https://www.winehq.org/ for details.
