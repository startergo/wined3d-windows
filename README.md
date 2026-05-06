# Wine D3D DLLs for qemu-3dfx

Builds Wine's DirectDraw, Direct3D 8, Direct3D 9, and wined3d DLLs as
standalone 32-bit Windows binaries using MinGW-w64. These DLLs are used with
[qemu-3dfx](https://github.com/kjliew/qemu-3dfx) to provide hardware-accelerated
graphics passthrough for Windows guests.

## Built DLLs

Each Wine version produces:

| DLL | Description |
|-----|-------------|
| `wined3d.dll` | Wine's OpenGL-based Direct3D translation layer |
| `d3d9.dll` | Direct3D 9 |
| `d3d8.dll` | Direct3D 8 |
| `ddraw.dll` | DirectDraw |
| `msvcrt.dll` | C runtime (Wine 6.x only) |

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
The build manually drives Wine's build tools (winebuild, widl, wrc, winegcc),
applies source patches for MinGW compatibility, and links against a stub
`libwine.a` to avoid runtime dependencies.

**Modern mode** (Wine 8.x+) uses Wine's native PE build system, which directly
targets `i386-windows/` DLL output via MinGW-w64.

## Quick Start

### GitHub Actions (CI)

Push to `main` or use the **Run workflow** button under Actions. Each version
builds in parallel on `windows-latest` runners. Artifacts are uploaded per-version
and as a combined bundle.

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
build-ci.sh        Standalone build script (MSYS2 / Linux)
PKGBUILD           MSYS2/MinGW package build definition
.github/workflows/build.yml   GitHub Actions CI
```

## License

Wine is licensed under the GNU Lesser General Public License (LGPL).
See https://www.winehq.org/ for details.
