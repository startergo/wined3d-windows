# PKGBUILD: Wine D3D DLLs for qemu-3dfx (MSYS2/MinGW-w64)
# Builds wined3d.dll, d3d9.dll, d3d8.dll, ddraw.dll (and optionally msvcrt.dll)
# from Wine source using MinGW-w64 natively on Windows via MSYS2.
#
# Usage (from an MSYS2 mingw32 shell):
#   makepkg-mingw -sf
#
# To also build msvcrt.dll for Wine 6.x, set _build_msvcrt=1.

_pkgname=wine-d3d-dlls
pkgver=8.0.2
pkgrel=1
pkgdesc='Wine D3D DLLs built with mingw-w64 for qemu-3dfx'
arch=('i686')
url='https://www.winehq.org/'
license=('LGPL')
depends=()
makedepends=(
    'mingw-w64-i686-gcc'
    'mingw-w64-i686-binutils'
    'mingw-w64-i686-headers'
    'mingw-w64-i686-winpthreads'
    'mingw-w64-i686-crt'
    'git' 'wget' 'flex' 'bison'
)
source=("https://dl.winehq.org/wine/source/${pkgver%.*}/wine-${pkgver}.tar.xz")
sha256sums=('SKIP')

# ── Configurable parameters ────────────────────────────────────────
_build_msvcrt=0

# ── Detect build mode from version ─────────────────────────────────
_detect_mode() {
    local major=${1%%.*}
    if [ "$major" -ge 7 ]; then
        echo "modern"
    else
        echo "legacy"
    fi
}

build() {
    local mode
    mode=$(_detect_mode "$pkgver")
    msg2 "Wine $pkgver — build mode: $mode, build msvcrt.dll: $_build_msvcrt"

    cd "$srcdir/wine-${pkgver}"

    if [ "$mode" = "modern" ]; then
        _build_modern
    else
        _build_legacy
    fi
}

# ── Modern mode (Wine 7.x+) ───────────────────────────────────────
_build_modern() {
    msg "Building Wine $pkgver (modern PE mode)"
    ./configure \
        --without-x \
        --without-alsa --without-capi --without-cups --without-dbus \
        --without-fontconfig --without-freetype --without-gphoto \
        --without-gstreamer --without-opencl \
        --without-pcap --without-pulse --without-sane \
        --without-sdl --without-udev --without-usb \
        --without-v4l2 --without-vulkan --without-oss

    local targets=(
        dlls/wined3d/i386-windows/wined3d.dll
        dlls/d3d9/i386-windows/d3d9.dll
        dlls/d3d8/i386-windows/d3d8.dll
        dlls/ddraw/i386-windows/ddraw.dll
    )
    if [ "$_build_msvcrt" = "1" ]; then
        targets+=(dlls/msvcrt/i386-windows/msvcrt.dll)
    fi
    make -j"$(nproc)" "${targets[@]}"
}

# ── Legacy mode (Wine 1.x–6.x) ────────────────────────────────────
_build_legacy() {
    msg "Building Wine $pkgver (legacy winegcc mode)"

    ./configure \
        --without-x \
        --without-alsa --without-capi --without-cups --without-dbus \
        --without-fontconfig --without-freetype --without-gphoto \
        --without-gstreamer --without-opencl \
        --without-pcap --without-pulse --without-sane --without-oss \
        CFLAGS="-O3 -march=i686 -msse4.2 -mtune=generic -fcommon -DWINE_NOWINSOCK -DUSE_WIN32_OPENGL -DUSE_WIN32_VULKAN -DNDEBUG" \
        LDFLAGS="-static-libgcc"

    make -j"$(nproc)" tools/makedep
    make \
        libs/port/Makefile libs/wine/Makefile libs/wpp/Makefile \
        tools/winebuild/Makefile tools/wrc/Makefile \
        tools/widl/Makefile tools/winegcc/Makefile \
        include/Makefile
    make -j"$(nproc)" libs/port 2>/dev/null || :
    make -j"$(nproc)" -C libs/wine 2>/dev/null || :
    make -C libs/wpp libwpp.a 2>/dev/null || :
    for tool in winebuild wrc widl winegcc; do
        make -j"$(nproc)" -C "tools/$tool"
    done
    make -C include 2>/dev/null || :
    make tools/make_xftmpl 2>/dev/null || :

    make \
        dlls/wined3d/Makefile dlls/d3d9/Makefile \
        dlls/d3d8/Makefile dlls/ddraw/Makefile \
        dlls/winecrt0/Makefile \
        dlls/uuid/Makefile dlls/dxguid/Makefile
    if [ "$_build_msvcrt" = "1" ]; then
        make dlls/msvcrt/Makefile
    fi

    # Fix d3d8_main.c: 'bool' is a keyword in MinGW C mode
    if [ -f dlls/d3d8/d3d8_main.c ]; then
        sed -i \
            -e 's/BOOL bool,/BOOL bool_val,/g' \
            -e 's/, bool,/, bool_val,/g' \
            -e 's/, bool)/, bool_val)/g' \
            dlls/d3d8/d3d8_main.c
    fi

    # Strip flags not needed on Windows
    find . -name Makefile | xargs sed -i \
        -e 's/-fPIC//g' \
        -e 's/-fstack-protector[^ ]*//g'

    if [ -d libs/wpp ] && [ -f libs/wpp/libwpp.a ]; then
        printf 'all:\nlibwpp.a:\ninstall clean distclean:\n' > libs/wpp/Makefile
    fi

    find . -name 'Makefile.in' | xargs touch -t 200001010000
    touch -t 200001010000 config.status

    # Patch winecrt0/debug.c: fwrite(stderr) → WriteFile
    if [ -f dlls/winecrt0/debug.c ]; then
        sed -i \
            -e 's|return fwrite( str, 1, len, stderr );|{ DWORD _nw=0; WriteFile(GetStdHandle(STD_ERROR_HANDLE),str,len,\&_nw,NULL); return _nw; }|' \
            -e 's|return fwrite( buffer, 1, strlen(buffer), stderr );|{ DWORD _nw=0; WriteFile(GetStdHandle(STD_ERROR_HANDLE),buffer,strlen(buffer),\&_nw,NULL); return _nw; }|' \
            dlls/winecrt0/debug.c
    fi

    # Create stub libwine.a (avoids libwine.dll runtime dependency)
    _create_stub_libwine

    make -j"$(nproc)" -C dlls/winecrt0
    make -C dlls/uuid
    make -C dlls/dxguid 2>/dev/null || :

    make -j"$(nproc)" -C dlls/wined3d
    tools/winebuild/winebuild \
        -w --implib \
        -o dlls/wined3d/libwined3d.a \
        --export dlls/wined3d/wined3d.spec

    for dll in d3d9 d3d8 ddraw; do
        make -j"$(nproc)" -C "dlls/$dll" "$dll.dll"
    done

    if [ "$_build_msvcrt" = "1" ]; then
        _patch_msvcrt_6x
        make -j"$(nproc)" -C dlls/msvcrt msvcrt.dll
    fi
}

_create_stub_libwine() {
    msg2 "Creating stub libwine.a"
    cat > /tmp/libwine_stubs.c << 'STUBEOF'
#include <stdarg.h>
#include <stddef.h>
struct __wine_debug_channel{unsigned char flags;unsigned char name[15];};
enum __wine_debug_class{__WINE_DBCL_FIXME,__WINE_DBCL_ERR,__WINE_DBCL_WARN,__WINE_DBCL_TRACE};
unsigned char __wine_dbg_get_channel_flags(struct __wine_debug_channel *ch){return 0;}
int __wine_dbg_header(enum __wine_debug_class c,struct __wine_debug_channel *ch,const char *fn){return -1;}
int wine_dbg_log(enum __wine_debug_class c,struct __wine_debug_channel *ch,const char *fn,const char *fmt,...){return 0;}
int wine_dbg_vlog(enum __wine_debug_class c,struct __wine_debug_channel *ch,const char *fn,const char *fmt,va_list ap){return 0;}
int wine_dbg_printf(const char *fmt,...){return 0;}
const char *wine_dbg_sprintf(const char *fmt,...){return "";}
int wine_dbg_vsprintf(char *buf,size_t sz,const char *fmt,va_list ap){if(buf&&sz)buf[0]=0;return 0;}
int wine_dbg_vprintf(const char *fmt,va_list ap){return 0;}
const char *wine_get_version(void){return "wine-stubs";}
const char *wine_get_config_dir(void){return "";}
const char *wine_get_data_dir(void){return "";}
static unsigned short _cmap[128];
unsigned short *wine_casemap_ascii=_cmap;
unsigned short wine_tolower(unsigned short c){return(c>=65&&c<=90)?c+32:c;}
unsigned short wine_toupper(unsigned short c){return(c>=97&&c<=122)?c-32:c;}
STUBEOF
    gcc -c -O2 -o /tmp/libwine_stubs.o /tmp/libwine_stubs.c
    ar cr libs/wine/libwine.a /tmp/libwine_stubs.o
}

_patch_msvcrt_6x() {
    if [ -f include/msvcrt/corecrt_wstring.h ]; then
        sed -i \
            -e 's/wcstok(wchar_t\*,const wchar_t\*,wchar_t\*\*)/wcstok(wchar_t*,const wchar_t*)/' \
            -e 's/return wcstok(str, delim, NULL)/return wcstok(str, delim)/' \
            include/msvcrt/corecrt_wstring.h
    fi
    cat >> dlls/msvcrt/wcs.c << 'MSEOF'

/* __stdio_common_* stubs for Wine 6.x */
int CDECL __stdio_common_vsprintf(unsigned __int64 o,
    char *s, size_t n, const char *f, _locale_t l, __ms_va_list a)
{ return _vsnprintf(s, n==(size_t)-1?0x7fffffff:n, f, a); }
int CDECL __stdio_common_vsprintf_s(unsigned __int64 o,
    char *s, size_t n, const char *f, _locale_t l, __ms_va_list a)
{ return _vsnprintf(s, n, f, a); }
int CDECL __stdio_common_vsprintf_p(unsigned __int64 o,
    char *s, size_t n, const char *f, _locale_t l, __ms_va_list a)
{ return _vsnprintf(s, n, f, a); }
int CDECL __stdio_common_vsnprintf_s(unsigned __int64 o,
    char *s, size_t n, size_t c, const char *f, _locale_t l, __ms_va_list a)
{ return _vsnprintf(s, c<n?c:n, f, a); }
int CDECL __stdio_common_vfprintf(unsigned __int64 o,
    FILE *fp, const char *f, _locale_t l, __ms_va_list a)
{ return _vsnprintf(NULL,0,f,a); }
int CDECL __stdio_common_vfprintf_s(unsigned __int64 o,
    FILE *fp, const char *f, _locale_t l, __ms_va_list a)
{ return _vsnprintf(NULL,0,f,a); }
int CDECL __stdio_common_vswprintf(unsigned __int64 o,
    wchar_t *s, size_t n, const wchar_t *f, _locale_t l, __ms_va_list a)
{ return _vsnwprintf(s, n==(size_t)-1?0x7fffffff:n, f, a); }
int CDECL __stdio_common_vswprintf_s(unsigned __int64 o,
    wchar_t *s, size_t n, const wchar_t *f, _locale_t l, __ms_va_list a)
{ return _vsnwprintf(s, n, f, a); }
int CDECL __stdio_common_vswprintf_p(unsigned __int64 o,
    wchar_t *s, size_t n, const wchar_t *f, _locale_t l, __ms_va_list a)
{ return _vsnwprintf(s, n, f, a); }
int CDECL __stdio_common_vsnwprintf_s(unsigned __int64 o,
    wchar_t *s, size_t n, size_t c, const wchar_t *f, _locale_t l, __ms_va_list a)
{ return _vsnwprintf(s, c<n?c:n, f, a); }
int CDECL __stdio_common_vfwprintf(unsigned __int64 o,
    FILE *fp, const wchar_t *f, _locale_t l, __ms_va_list a)
{ return _vsnwprintf(NULL,0,f,a); }
int CDECL __stdio_common_vfwprintf_s(unsigned __int64 o,
    FILE *fp, const wchar_t *f, _locale_t l, __ms_va_list a)
{ return _vsnwprintf(NULL,0,f,a); }
MSEOF
}

package() {
    local outdir="$pkgdir/usr/share/$_pkgname/$pkgver"
    install -d "$outdir"

    cd "$srcdir/wine-${pkgver}"

    local mode
    mode=$(_detect_mode "$pkgver")

    if [ "$mode" = "modern" ]; then
        install -m644 \
            dlls/wined3d/i386-windows/wined3d.dll \
            dlls/d3d9/i386-windows/d3d9.dll \
            dlls/d3d8/i386-windows/d3d8.dll \
            dlls/ddraw/i386-windows/ddraw.dll \
            "$outdir/"
        if [ "$_build_msvcrt" = "1" ]; then
            install -m644 dlls/msvcrt/i386-windows/msvcrt.dll "$outdir/"
        fi
    else
        install -m644 \
            dlls/wined3d/wined3d.dll \
            dlls/d3d9/d3d9.dll \
            dlls/d3d8/d3d8.dll \
            dlls/ddraw/ddraw.dll \
            "$outdir/"
        if [ "$_build_msvcrt" = "1" ]; then
            install -m644 dlls/msvcrt/msvcrt.dll "$outdir/"
        fi
    fi

    printf "Built on %s\n" "$(date '+%T %b %-e %Y')" > "$outdir/build-timestamp"
}
