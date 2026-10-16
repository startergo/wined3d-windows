#!/bin/bash
# Build Wine's bundled vkd3d-shader for Windows 98 plus the vkd3dtest program,
# with the MSVCRT MinGW toolchain of the Docker image (Homebrew's MinGW targets
# the UCRT, which Win98 lacks).
#   tools/vkd3dtest/build.sh <wine-source-dir> <out-dir> [docker-image]
# Needs bison and flex on the host (for the HLSL parser and preprocessor).
set -e
WINE=$(cd "$1" && pwd); OUT=$(mkdir -p "$2" && cd "$2" && pwd); IMG=${3:-wine-dll-builder:9.0.1}
T=$(cd "$(dirname "$0")" && pwd); V=$WINE/libs/vkd3d
for g in hlsl preproc; do
  bison -d -o "$OUT/$g.tab.c" "$V/libs/vkd3d-shader/$g.y"
  flex -o "$OUT/$g.yy.c" "$V/libs/vkd3d-shader/$g.l"
done
echo 'const char *const vkd3d_dbg_env_name = "VKD3D_SHADER_DEBUG";' > "$OUT/envname.c"
cat > "$OUT/inner.sh" <<'INNER'
set -e
V=/wine/libs/vkd3d; B=/b
cd $B && rm -f *.o
# __USE_MINGW_ANSI_STDIO: C99 vsnprintf/formats (vkd3d's string buffers need
#   the C99 return value; Win98's msvcrt returns -1 on truncation)
# _USE_32BIT_TIME_T: fstat -> _fstat (Win98's msvcrt has no _fstat64)
# NONAMELESSUNION on the command line: vkd3d defines it after MinGW's headers
#   have already chosen anonymous unions
F="-std=gnu11 -O2 -D__USE_MINGW_ANSI_STDIO=1 -D_USE_32BIT_TIME_T -DNONAMELESSUNION -DNONAMELESSSTRUCT -DWINE_NO_NAMELESS_EXTENSION -DLIBVKD3D_SHADER_SOURCE -I$B -I$V -I$V/include -I$V/include/private -I$V/libs/vkd3d-shader -idirafter /wine/include -march=pentium2"
for f in $V/libs/vkd3d-common/*.c $V/libs/vkd3d-shader/*.c $B/hlsl.tab.c $B/hlsl.yy.c $B/preproc.tab.c $B/preproc.yy.c $B/envname.c; do
  i686-w64-mingw32-gcc $F -c -o $B/$(basename $f .c).o $f
done
i686-w64-mingw32-gcc -O2 -c -o initonce_compat.o /t/initonce_compat.c
i686-w64-mingw32-gcc -shared -static-libgcc -o vkd3d_shader_test.dll *.o -Wl,--export-all-symbols -luuid -ldxguid
i686-w64-mingw32-gcc -O2 -std=gnu11 -static-libgcc -I$V/include -o vkd3dtest.exe /t/vkd3dtest.c
INNER
docker run --rm --entrypoint bash -v "$OUT:/b" -v "$WINE:/wine:ro" -v "$T:/t:ro" "$IMG" /b/inner.sh
echo "built $OUT/vkd3d_shader_test.dll and $OUT/vkd3dtest.exe"
