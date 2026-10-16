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
| `ddraw.dll` | DirectDraw + qemu-3dfx call sites + ddthru routing to the system DirectDraw (`ddrawwq.dll`) |
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

The Vulkan sources (`adapter_vk.c`, `context_vk.c`, `shader_spirv.c`) are
never linked — Win98 has no Vulkan; `docker/vk_stubs.c` provides their entry
points.

All versions download the Wine source tarball, extract wined3d/ddraw/d3d8/d3d9
.c/.h files, and apply compatibility patches before building with the
wine9x-support Makefile and direct MinGW gcc compilation. The wine9x-support
directory provides the build infrastructure (Makefile, headers, compat layers) —
the actual DLL source comes from the Wine tarball.

## qemu-3dfx Passthrough Hooks

The qemu-3dfx project ships prebuilt Wine DLLs but has not published its
modified Wine source, so these additions are reconstructed from the reference
qemu-3dfx binaries (Wine 1.8.7 … 8.0.2) and verified against
their machine code with the emulator tests in [`tests/emu/`](tests/emu/README.md).
Each function in the sources cites the reference address it came from.

### wined3d.dll — qemu-3dfx module (`qemu3dfx_hooks.c`)

Configuration is read from `HKCU\Software\Wine\Direct3D`, with
`HKCU\Software\Wine\AppDefaults\<exe>\Direct3D` taking priority:

| Value | Type | Effect | Default |
|-------|------|--------|---------|
| `D3D1Hal3Dfx` | `"enabled"` | enable the 3dfx HAL (`wined3d_hal_3dfx`) | off (on for `ds9dw.exe`) |
| `D3D1EnumHalLast` | `"disabled"` | enumerate the HAL device first | HAL last |
| `DDSurfaceHeap` | `"disabled"` | `wined3d_surface_ddheap` (6.0+) | on |
| `UseLastContextTid` | `"enabled"`/`"disabled"` | context thread selection | off (≤7.0), on (8.0) |
| `BlitFpsLimit` / `FlipFpsLimit` | DWORD | frame cap for Blt (low byte) / Flip (low 7 bits) | 0 = off |
| `ScaleWindow` | DWORD | scaled window, `(width << 16) \| height`; sign bit = mode 2 | unset |
| `DisplayROI` | DWORD | crop presentation by `(x << 16) \| y` margins | unset |
| `OverrideCoopFullscreen` | DWORD | toggle `DDSCL_FULLSCREEN`/`NOWINDOWCHANGES` | unset |
| `OverrideModeWidth` | DWORD | force display mode width or `w:h`; sign bit = 16 bpp | unset |
| `SwapInterval` | DWORD | override the swap interval | unset |

Exports called by ddraw.dll:

| Export | Behaviour |
|--------|-----------|
| `wined3d_hal_3dfx` | `D3D1Hal3Dfx`, else exe basename is `ds9dw.exe` (case-insensitive) |
| `wined3d_enum_hal_last` | `D3D1EnumHalLast` |
| `wined3d_surface_ddheap` | `DDSurfaceHeap` (reference exports it from 6.0) |
| `wined3d_passthru(BOOL *)` | set (non-NULL) / query the passthrough flag |
| `wined3d_override_cooplevel(DWORD *)` | cooperative-level override from `OverrideCoopFullscreen`/`ScaleWindow` |
| `wined3d_override_rendertarget_view(view)` | make the view's resource a render target: `usage \|= 0x1` (≤3.0) or `bind_flags \|= 0x20` (4.x+), offset per version |
| `wined3d_blit_fpslimit` / `wined3d_flip_fpslimit` | frame limiter (`GetTickCount`/`Sleep(0)`) |

Internal API, called from Wine's own code (`docker/qemu3dfx_callsites.py`
inserts the calls at the places the reference DLLs make them, see
[`tools/re/CALLSITES.md`](tools/re/CALLSITES.md)): `qemu3dfx_display_roi`,
`qemu3dfx_override_mode`, `qemu3dfx_swap_interval`, `qemu3dfx_scale_window`,
the host-cursor channel (`qemu3dfx_cursor_sync`, `qemu3dfx_set_host_cursor`
via the wrapper's `wglSetDeviceCursor3DFX` and a magic
`glDebugMessageInsertARB` message), `qemu3dfx_is_qemu_bochs`, the Silent
Hill 4 video fix (`qemu3dfx_sysmem_count_quirk`), three latches (DLL
instance, last texture presented to a drawable, last texture read back from
one) and config accessors.

What the call sites do, by setting:

| Setting | Where it acts |
|---|---|
| `ScaleWindow` | display-mode set/get keep the desktop mode and report the requested one; presented frames are stretched to the screen (viewport in the quad blitters, FBO blit rectangle); restore always restores |
| `DisplayROI` | blit source rectangles (`texture2d_get_blt_info`, FBO blit) |
| `OverrideModeWidth` | the `DEVMODE` used for mode changes |
| `SwapInterval` | the GL swap interval after Wine's clamp |
| `UseLastContextTid` | GL context selection (no per-thread contexts) |
| `D3D1Hal3Dfx` | Direct3D device enumeration (HAL advertises POW2 textures), 16-bit RGB display modes only |
| `D3D1EnumHalLast` | emulation devices (Ramp, RGB) enumerated before the HAL |
| `OverrideCoopFullscreen` | `SetCooperativeLevel` flags |
| `BlitFpsLimit` / `FlipFpsLimit` | frame limiter in `Unlock` / `Flip` (Flip: Wine ≤ 3.x) |
| `DDSurfaceHeap` | released surfaces keep a zeroed stub instead of being freed (6.0+) |

Call sites are in place in wined3d and ddraw for every version, 1.8.7–8.0.2.

Two additions act regardless of settings:

- **Host announcement**: wined3d sends `Wine-<version> Direct3D build …`
  through `glDebugMessageInsertARB` while probing GL (in
  `test_pbo_functionality`). qemu-3dfx only treats the guest as Wine
  Direct3D after this message; without it, games report no 3D accelerator.
- **`DDCAPS.dwZBufferBitDepths`**: ddraw's `GetCaps` reports the Z-buffer
  depths, which stock Wine leaves at 0 and older games read: a constant
  `DDBD_16 | DDBD_24` for 1.8.7–2.0.5, and from 3.0.5 the depths of the HAL
  device's Z formats (`IDirect3D7::EnumZBufferFormats`), as in the reference.

### ddraw.dll — ddthru routing, call sites, ddrawwq.dll forwarders

**ddthru** (`qemu3dfx_ddthru.c`): `DirectDrawCreate`, `DirectDrawCreateEx`,
`DirectDrawCreateClipper`, `DirectDrawEnumerateA/ExA` and `GetSurfaceFromDC`
decide per call whether to run Wine or the system DirectDraw
(`ddrawwq.dll`, the original `ddraw.dll` renamed by qemu-3dfx's installer):
calls from inside `ddraw.dll` and calls without a `wined3d.mod` file in the
current directory go to Wine; with the file, calls go to the system
DirectDraw unless the caller lies in a range listed in it, one
`module,size[,offset]` (hex) per line. Each decision is logged to the host
as `[ ddthru <module> <name> ] at <caller> passthru|winecall`.

**Exports** (`qemu3dfx_ddraw_hooks.c`): `DDInternalLock`/`Unlock`,
`D3DParseUnknownCommand`, `CompleteCreateSysmemSurface`,
`Acquire`/`ReleaseDDThreadLock` forward to `ddrawwq.dll` (`E_NOTIMPL`, or
the wined3d mutex for the thread lock, when it is absent). The `VidMem*`,
`DDHAL32_*` and related HAL exports are unimplemented in Wine and in the
reference; they exist for the export table and return 0.

## Architecture

```
Guest application
    |
    v
ddraw.dll ── ddthru: per-call choice between Wine and ddrawwq.dll (wined3d.mod)
    |     ── call sites: device enumeration, display modes, cooperative level,
    |        Unlock/Flip frame limiters, render-target view, surface heap
    v
wined3d.dll ── qemu-3dfx module: registry config, HAL detection, host cursor,
    |          ScaleWindow / DisplayROI / OverrideModeWidth / SwapInterval
    v
opengl32.dll (qemu-3dfx wrapper) → host GPU
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

### CI / MSYS2 (`build-ci.sh`)

`build-ci.sh` is the build used by GitHub Actions
(`.github/workflows/build.yml`): on `windows-latest` with MSYS2's i686 GCC it
builds each version in its own matrix job, checks the imports
(`docker/verify_imports.py`) and bundles all versions into one `wine-dlls-all`
artifact. It applies the same Wine patches as the Dockerfile, including the
call-site patcher. Locally it runs from an MSYS2 MINGW32 shell:

```
bash build-ci.sh                        # all versions
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
| Vulkan backend not needed on Win98 | Vulkan sources never linked; vk_stubs.c provides their entry points |
| C runtime | All four DLLs link against Win98's own `msvcrt.dll`, like the reference DLLs (no bundled msvcrt.dll — 6.0.4 used to ship one that imports symbols 98 lacks). The hand-written CRT replacement used before (`heap_compat.c`) is gone: it caused self-recursive `memset`/`strlen` and a `printf` without widths or precision |
| `vsnprintf` family | `mingw_matherr_stubs.c` forwards `_vsnprintf`/`__ms_vsnprintf` to msvcrt's (resolved at runtime) and implements `_vscprintf` (missing in Win98's msvcrt 6). These used to be stubs returning an empty string, so every GLSL shader was generated empty and 3D rendered black |
| `FreeLibraryAndExitThread` | Win98's own (an earlier busy-loop stub made wined3d's worker thread spin forever); the command-stream worker thread stays disabled, as in the reference |
| Version resources | `gen_version_rc.py` gives each DLL the reference's version info (e.g. ddraw 4.09.00.0904); games check it ("needs DirectX 6.1") |
| Stale wine9x headers (`rbtree.h`, `wgl.h`, `wgl_driver.h`, `list.h`) | Each Wine version's own headers are used. wine9x's old `rbtree.h` API made every device creation crash on Wine ≥ 2.0 |
| Hidden windows use a DLL-registered class (found on Win9x only with the registering instance) | wined3d and ddraw pass their DLL instance as `CreateWindowA`'s `hInstance`, as the reference does (without it every ddraw swapchain failed and nothing was presented) |
| vkd3d library (Wine 8.0+) not needed | Remove includes, callbacks, and debug channels from wined3d_main.c |
| WGL query renderer extensions missing | Remove USE_GL_FUNC entries, null out supported[] blocks |
| GL extension naming mismatch | Add EXT suffix (glPolygonOffsetClamp→EXT, GL_TEXTURE_MAX_ANISOTROPY→_EXT) |
| Wine debug/log symbols in ddraw | Stub via libwine_stubs.c (atexit, wine_get_version, __wine_dbg_*) |
| AllocateLocallyUniqueId fails on Win98 | Time-based LUID fallback (the pattern also covers 5.0's `wined3d_output_cleanup()` call, without which 5.0.5 could not create an adapter) |
| Wine ≤ 3.0 defines globals in headers (`glEnableWINE`/`glDisableWINE` in `wined3d_gl.h`) | Built with `-fcommon` (GCC ≥ 10 defaults to `-fno-common`, giving each file a private, never-set copy: 3DMark2000 crashed in `context_apply_blit_state`'s `glDisableWINE(GL_FOG)`) |
| Wine 1.8 uses `GL_APPLE_client_storage`, which the passthrough reports from the macOS host | Disabled for 1.8 (backport of Wine 1.9.1's removal): the host read texture data from guest memory, garbling surfaces rewritten every frame (3DMark2000's helicopter HUD, also with the reference DLLs) |
| Wine 1.9 never loads `p_wglGetPixelFormat` in its `USE_WIN32_OPENGL` mode | Loaded next to `wglSwapBuffers`, as in 1.8 and 2.0+ (crashed every context creation) |
| D3DKMT (Vista+ gdi32) needed by Wine ≥1.9 | `d3dkmt_stubs.c`: surface/texture `GetDC` via `CreateCompatibleDC` + `CreateDIBSection` (copy-in/copy-back, as the reference); adapter/device calls succeed, `QueryVideoMemoryInfo` → `STATUS_NOT_IMPLEMENTED` (fake memory info) |
| PE header incompatibility | patch_pe_win98.py post-processing |
| Import name decorations | strip_import_decorations.py post-processing |

## Files

```
Dockerfile                    Docker build (all versions via WINE_VERSION arg)
build-ci.sh                   Build script used by CI (MSYS2 on Windows)
qemu3dfx_hooks.c              qemu-3dfx module for wined3d (8 exports + internal API, per-version)
qemu3dfx_ddraw_hooks.c        ddraw exports: ddrawwq.dll forwarders + HAL export stubs
qemu3dfx_ddthru.c             ddthru: per-call routing of the DirectDraw entry points
docker/
  qemu3dfx_callsites.py       Inserts the qemu-3dfx call sites into Wine source (all versions)
  qemu3dfx.h, qemu3dfx_ddraw.h  Prototypes for the patched Wine sources
  qemu3dfx_streaming_buffer.c Wine 8.0 streaming buffers backported to 7.x
  kernel32_compat.c           Win98-compatible stubs (security cookie, GetSystemTimeAsFileTime, etc.)
  copysign.c                  _copysign implementation
  nocrt_entry.c               Minimal DLL entry point (DllMainCRTStartup bypass)
  vk_stubs.c                  Vulkan stub functions (never called on Win98)
  libwine_stubs.c             Wine debug/log stubs for ddraw (atexit, wine_get_version, __wine_dbg_*)
  d3dkmt_stubs.c              D3DKMT for Win9x: GDI-based DCs from memory, adapter/device stubs
  mingw_matherr_stubs.c       MinGW internals for the -nostdlib link: real _vsnprintf/_vscprintf, math stubs
  gen_version_rc.py           Version resources matching the reference DLLs
  debug_serial.py             DEBUG_LOG=1 builds: ERR/WARN/FIXME to the guest's COM1
  patch_pe_win98.py           PE header patching for Win98
  strip_import_decorations.py Strip @N from PE import names
tests/                        Host unit tests (make test) with Win32 mocks
tests/emu/                    Emulator differential tests vs the qemu-3dfx reference DLLs (make test-emu)
tools/
  win98-universe.py           Win98 export universe + import checker
  win98-calldiff.py           Disassemble two PEs and diff their calls / runtime lookups
  build-verify.sh             Build one Wine version into output-verify/ without touching output/
  re/                         Reverse-engineering helpers and CALLSITES.md (call-site map)
  capsdump/                   Guest tool: dumps DDCAPS, D3D devices and Z formats to COM1
  glprof/                     Guest opengl32 proxy: per-frame GL call counts to COM1
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

## Testing

```sh
make test        # host unit tests (no Windows/Wine needed; any C compiler)
make test-emu    # differential tests vs the qemu-3dfx reference DLLs
```

`make test-emu` needs Python 3 with Unicorn, `i686-w64-mingw32-gcc`, and the
reference DLLs extracted once with `tests/emu/extract-reference.sh` — see
[`tests/emu/README.md`](tests/emu/README.md). For built DLLs,
`tools/win98-universe.py check output/<ver>/*.dll` verifies every import
against a stock Win98 SE system and `tools/win98-calldiff.py` compares calls
with the reference build.

### In a Win98 SE VM (qemu-3dfx)

Built DLLs are also checked in a Windows 98 SE guest against the reference
DLLs:

- `tools/capsdump` runs DirectDraw/Direct3D enumeration with each DLL pair
  and writes the result to COM1. All nine versions (1.8.7–8.0.2) report
  output identical to their reference and exit cleanly.
- 3DMark 99 Max completes with the 6.0.4 build (2726; reference 2612), and
  3DMark2000 with 2.0.5, 4.12.1, 6.0.4 and 8.0.2 (3902, 4656, 4357, 4090;
  references 4195 for 2.0.5 and 3899 for 6.0.4, all in the same VM).
- `tools/glprof` (an `opengl32.dll` proxy in front of the qemu-3dfx wrapper)
  counts GL calls per frame; diffing the reference's and ours located the
  empty-`vsnprintf` bug.
- A debug build (`DEBUG_LOG=1` build argument) sends Wine's ERR/WARN/FIXME
  messages to the guest's COM1.

## Credits

- [kjliew/qemu-3dfx](https://github.com/kjliew/qemu-3dfx) — QEMU fork with
  3dfx Voodoo passthrough, original Wine DLL hooks that this build replicates
- [Wine](https://www.winehq.org/) — upstream source for all D3D/DirectDraw DLLs
- [MinGW-w64](https://www.mingw-w64.org/) — Windows cross-compilation toolchain
- wine9x-support — Win9x-compatible Wine build infrastructure

## License

Wine is licensed under the GNU Lesser General Public License (LGPL).
See https://www.winehq.org/ for details.
