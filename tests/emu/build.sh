#!/bin/bash
# tests/emu/build.sh — build the test DLLs the emulator tests load.
#
#   hooks-<maj>.<min>.dll   qemu3dfx_hooks.c for every Wine version the
#                           Docker build supports (also a compile check)
#   d3dkmt-ref.dll          docker/d3dkmt_stubs.c with the reference palette
#                           behaviour (bit-exact differential test)
#   d3dkmt.dll              docker/d3dkmt_stubs.c as shipped
#   ddraw-hooks.dll         qemu3dfx_ddraw_hooks.c + qemu3dfx_ddthru.c (ddrawwq.dll
#                           forwarders, ddthru routing)
#
# Each DLL is linked at 0x20000000 (the reference wined3d sits at 0x10000000,
# so both can be mapped side by side) with undecorated exports.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${QEMU3DFX_EMU_BUILD:-$HERE/build}"
CC="${CC:-i686-w64-mingw32-gcc}"
command -v "$CC" >/dev/null || { echo "need $CC (brew install mingw-w64 / apt install gcc-mingw-w64-i686)" >&2; exit 1; }
mkdir -p "$OUT"

CFLAGS="-std=c99 -O3 -fomit-frame-pointer -D_WIN32 -DWIN32 -DNDEBUG -DWINVER=0x0400 \
        -D__USE_MINGW_ANSI_STDIO=0 -Wall -Wextra -Wno-unused-parameter -Werror"
LDFLAGS="-shared -Wl,--image-base,0x20000000 -Wl,--kill-at -Wl,--export-all-symbols"

# version list mirrors build-docker.sh (major.minor of each Wine release)
for mv in 1.8 1.9 2.0 3.0 4.12 5.0 6.0 7.0 8.0; do
    "$CC" $CFLAGS -DQEMU3DFX_WINE_MAJOR=${mv%.*} -DQEMU3DFX_WINE_MINOR=${mv#*.} \
        $LDFLAGS -o "$OUT/hooks-$mv.dll" "$ROOT/qemu3dfx_hooks.c" \
        -lopengl32 -luser32 -ladvapi32 -lkernel32
done

"$CC" $CFLAGS -DQEMU3DFX_D3DKMT_REFERENCE_PALETTE $LDFLAGS \
    -o "$OUT/d3dkmt-ref.dll" "$ROOT/docker/d3dkmt_stubs.c" -lgdi32 -lkernel32
"$CC" $CFLAGS $LDFLAGS \
    -o "$OUT/d3dkmt.dll" "$ROOT/docker/d3dkmt_stubs.c" -lgdi32 -lkernel32

# ddraw-hooks.dll: qemu3dfx_ddraw_hooks.c, importing wined3d_mutex_lock/unlock
# from "wined3d.dll" through a generated import library
DLLTOOL="${DLLTOOL:-${CC%gcc}dlltool}"
printf 'LIBRARY wined3d.dll\nEXPORTS\nwined3d_mutex_lock@0\nwined3d_mutex_unlock@0\nwined3d_passthru@4\n' > "$OUT/wined3d-mutex.def"
"$DLLTOOL" --kill-at -d "$OUT/wined3d-mutex.def" -l "$OUT/libwined3d-mutex.a"
"$CC" $CFLAGS $LDFLAGS \
    -o "$OUT/ddraw-hooks.dll" "$ROOT/qemu3dfx_ddraw_hooks.c" "$ROOT/qemu3dfx_ddthru.c" \
    "$OUT/libwined3d-mutex.a" -luser32 -lkernel32

echo "built: $(cd "$OUT" && ls *.dll | tr '\n' ' ')"
