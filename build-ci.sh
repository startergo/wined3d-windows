#!/bin/bash
# Wine D3D DLL Builder — wine9x direct compilation approach
# Compiles Wine source files directly with MinGW, matching the wine9x build method.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WINE9X="$SCRIPT_DIR/wine9x-support"
OUTPUT_BASE="$SCRIPT_DIR/output"

# Compiler — gcc on MSYS2 CI
CC="${CC:-gcc}"

# version:branch:ext
VERSIONS=(
    "1.8.7:1.8:tar.bz2"
    "1.9.7:1.9:tar.bz2"
    "2.0.5:2.0:tar.xz"
    "3.0.5:3.0:tar.xz"
    "4.12.1:4.x:tar.xz"
    "5.0.5:5.0:tar.xz"
    "6.0.4:6.0:tar.xz"
    "7.0.2:7.0:tar.xz"
    "8.0.2:8.0:tar.xz"
)

FORCE=0
NO_CACHE=""
FILTER_VERSIONS=()
for arg in "$@"; do
    [ "$arg" = "--force" ] && FORCE=1
    [ "$arg" = "--no-cache" ] && NO_CACHE="--no-cache"
    if [ "$_prev" = "--versions" ]; then
        FILTER_VERSIONS+=("$arg")
    fi
    _prev="$arg"
done

# ── Version comparison ─────────────────────────────────────────────
version_ge() {
    # Returns 0 (true) if $1 >= $2
    local v1="$1" v2="$2"
    [ "$v1" = "$v2" ] && return 0
    local IFS=.
    local a=($v1) b=($v2)
    local i
    for ((i=0; i<${#a[@]} || i<${#b[@]}; i++)); do
        local x=${a[i]:-0} y=${b[i]:-0}
        (( x > y )) && return 0
        (( x < y )) && return 1
    done
    return 0
}

# ── Toolchain setup (matches Dockerfile) ────────────────────────────
setup_toolchain() {
    echo "=== Setting up toolchain ==="

    local lib_dir
    lib_dir=$(dirname "$(gcc -print-file-name=libmsvcrt.a)")
    echo "  CRT lib dir: $lib_dir"

    # ── Rename __acrt_iob_func → __iob_func in CRT archives ──────
    for archive in "$lib_dir/libmingwex.a" "$lib_dir/libmsvcrt.a" "$lib_dir/libmingw32.a"; do
        [ -f "$archive" ] || continue
        echo "  Patching $(basename "$archive"): __acrt_iob_func → __iob_func"
        objcopy --redefine-sym ___acrt_iob_func=___iob_func "$archive" 2>/dev/null || true
    done

    # ── ucrtcompat stubs into libmsvcrt.a ─────────────────────────
    cat > /tmp/ucrtcompat.c << 'UCEOF'
/* No includes - avoid header conflicts */
typedef unsigned long long _u64;
typedef unsigned int _uint;
typedef unsigned int _size;
typedef void *_locale;
typedef char _va_list[4];
typedef void FILE;
typedef unsigned short wchar_t;
FILE * __cdecl __iob_func(void);
int __cdecl _vsnprintf(char*,_size,const char*,...);
int __cdecl _vsnwprintf(wchar_t*,_size,const wchar_t*,...);
FILE * __cdecl __acrt_iob_func(_uint i){ return (char*)__iob_func()+i*32; }
int __cdecl __stdio_common_vsprintf(_u64 o,char *b,_size n,const char *f,_locale l,_va_list a){ return _vsnprintf(b,n==((_size)-1)?0x7fffffff:n,f,*(void**)a); }
int __cdecl __stdio_common_vsprintf_s(_u64 o,char *b,_size n,const char *f,_locale l,_va_list a){ return _vsnprintf(b,n,f,*(void**)a); }
int __cdecl __stdio_common_vsprintf_p(_u64 o,char *b,_size n,const char *f,_locale l,_va_list a){ return _vsnprintf(b,n,f,*(void**)a); }
int __cdecl __stdio_common_vsnprintf_s(_u64 o,char *b,_size n,_size c,const char *f,_locale l,_va_list a){ return _vsnprintf(b,c<n?c:n,f,*(void**)a); }
int __cdecl __stdio_common_vfprintf(_u64 o,FILE *p,const char *f,_locale l,_va_list a){ return 0; }
int __cdecl __stdio_common_vfprintf_s(_u64 o,FILE *p,const char *f,_locale l,_va_list a){ return 0; }
int __cdecl __stdio_common_vfscanf(_u64 o,FILE *p,const char *f,_locale l,_va_list a){ return -1; }
int __cdecl __stdio_common_vsscanf(_u64 o,const char *s,_size n,const char *f,_locale l,_va_list a){ return -1; }
int __cdecl __stdio_common_vswprintf(_u64 o,wchar_t *b,_size n,const wchar_t *f,_locale l,_va_list a){ return _vsnwprintf(b,n==((_size)-1)?0x7fffffff:n,f,*(void**)a); }
int __cdecl __stdio_common_vswprintf_s(_u64 o,wchar_t *b,_size n,const wchar_t *f,_locale l,_va_list a){ return _vsnwprintf(b,n,f,*(void**)a); }
int __cdecl __stdio_common_vswprintf_p(_u64 o,wchar_t *b,_size n,const wchar_t *f,_locale l,_va_list a){ return _vsnwprintf(b,n,f,*(void**)a); }
int __cdecl __stdio_common_vsnwprintf_s(_u64 o,wchar_t *b,_size n,_size c,const wchar_t *f,_locale l,_va_list a){ return _vsnwprintf(b,c<n?c:n,f,*(void**)a); }
int __cdecl __stdio_common_vfwprintf(_u64 o,FILE *p,const wchar_t *f,_locale l,_va_list a){ return 0; }
int __cdecl __stdio_common_vfwprintf_s(_u64 o,FILE *p,const wchar_t *f,_locale l,_va_list a){ return 0; }
__asm__(".globl __imp____stdio_common_vsprintf\n.section .rdata,\"dr\"\n.align 4\n__imp____stdio_common_vsprintf:\n    .long ___stdio_common_vsprintf\n.globl __imp____stdio_common_vfprintf\n.align 4\n__imp____stdio_common_vfprintf:\n    .long ___stdio_common_vfprintf\n.globl __imp____stdio_common_vsscanf\n.align 4\n__imp____stdio_common_vsscanf:\n    .long ___stdio_common_vsscanf\n.text\n");
UCEOF
    gcc -nostdinc -c /tmp/ucrtcompat.c -o /tmp/ucrtcompat.o && \
    ar rs "$lib_dir/libmsvcrt.a" /tmp/ucrtcompat.o && \
    echo "  Injected ucrtcompat stubs into libmsvcrt.a"

    # ── gcc wrapper: force -mcrtdll=msvcrt ─────────────────────────
    printf '#!/bin/sh\nexec gcc -mcrtdll=msvcrt -D__MSVCRT__ -U_UCRT "$@"\n' \
        > /tmp/wine-gcc
    chmod +x /tmp/wine-gcc
    CC=/tmp/wine-gcc
    echo "  Created gcc wrapper at /tmp/wine-gcc"

    echo "=== Toolchain ready ==="
}

# ── Build pthread9x library ───────────────────────────────────────
build_pthread9x() {
    echo "=== Building pthread9x ==="
    local pt_dir="$WINE9X/pthread9x"
    if [ ! -d "$pt_dir/src" ]; then
        echo "ERROR: pthread9x submodule not initialized"
        echo "  Run: cd wine9x-support && git submodule update --init --recursive"
        exit 1
    fi

    # Build with NEW_ALLOC (HeapAlloc-based malloc), SPEED=1
    mkdir -p "$pt_dir/build"
    cd "$pt_dir/build"

    local CFLAGS="-std=gnu99 -O3 -fno-exceptions -march=pentium2 -mtune=core2"
    CFLAGS+=" -I../include -I. -DNDEBUG -DHAVE_CONFIG_H -DIN_WINPTHREAD"
    CFLAGS+=" -Wall -DWIN32_LEAN_AND_MEAN -DNEW_ALLOC"

    local SRCS="src/barrier.c src/cond.c src/misc.c src/mutex.c src/rwlock.c"
    SRCS+=" src/spinlock.c src/thread.c src/ref.c src/sem.c src/sched.c"
    SRCS+=" src/clock.c src/nanosleep.c src/tryentercriticalsection.c"
    SRCS+=" extra/memory.c extra/int64.c extra/lockex.c"

    for src in $SRCS; do
        local obj="$(basename "${src%.c}").o"
        echo "  CC pthread9x/$src"
        $CC $CFLAGS -c -o "$obj" "../$src"
    done

    echo "  AR libpthread.a"
    ar rcs -o libpthread.a barrier.o cond.o misc.o mutex.o rwlock.o \
        spinlock.o thread.o ref.o sem.o sched.o clock.o nanosleep.o \
        tryentercriticalsection.o memory.o int64.o lockex.o

    echo "  CC crtfix.o"
    $CC $CFLAGS -c -o crtfix.o ../extra/crtfix.c

    cd "$SCRIPT_DIR"
    echo "=== pthread9x built ==="
}

# ── Download Wine source ───────────────────────────────────────────
download_wine() {
    local version="$1" branch="$2" ext="$3"
    local wine_dir="$SCRIPT_DIR/wine-${version}"

    if [ -d "$wine_dir" ] && [ "$FORCE" = "0" ]; then
        return 0
    fi

    local url="https://dl.winehq.org/wine/source/${branch}/wine-${version}.${ext}"
    local archive="$SCRIPT_DIR/wine-${version}.${ext}"

    if [ ! -f "$archive" ]; then
        echo "  Downloading Wine $version..."
        if command -v wget &>/dev/null; then
            wget --tries=3 -O "$archive" "$url" || { rm -f "$archive"; return 1; }
        fi
        if [ ! -f "$archive" ]; then
            curl -fSL -o "$archive" "$url" || { rm -f "$archive"; return 1; }
        fi
    fi

    # Validate the archive is a real tarball (not an HTML error page)
    local fsize
    fsize=$(stat -c%s "$archive" 2>/dev/null || stat -f%z "$archive" 2>/dev/null || echo 0)
    if [ "$fsize" -lt 1000 ]; then
        echo "ERROR: Downloaded archive is only $fsize bytes — likely an error page"
        head -c 500 "$archive" 2>/dev/null
        rm -f "$archive"
        return 1
    fi

    rm -rf "$wine_dir"
    echo "  Extracting..."
    tar xf "$archive" -C "$SCRIPT_DIR"
}

# ── Generate .def from Wine .spec ─────────────────────────────────
generate_def() {
    local spec_file="$1" def_file="$2" dll_name="$3"

    echo "EXPORTS" > "$def_file"

    # Parse Wine .spec: @ stdcall func_name(params) or @ cdecl func_name(params)
    # Also handle: @ stdcall -private func_name(params)
    grep -E '^\s*@\s+(stdcall|cdecl)' "$spec_file" | \
        grep -v '\-private' | \
        sed -E 's/^\s*@\s+(stdcall|cdecl)(\s+-(noname|ordinal|stub|ignore))*\s+([A-Za-z_][A-Za-z0-9_]*).*/\4/' | \
        grep -v '^$' >> "$def_file"

    # Add wine9x custom exports for wined3d
    if [ "$dll_name" = "wined3d" ]; then
        # qemu-3dfx custom exports
        for sym in wined3d_hal_3dfx wined3d_enum_hal_last wined3d_surface_ddheap \
                   wined3d_passthru wined3d_override_cooplevel \
                   wined3d_override_rendertarget_view \
                   wined3d_blit_fpslimit wined3d_flip_fpslimit; do
            grep -q "^${sym}$" "$def_file" || echo "$sym" >> "$def_file"
        done
        # CRT exports (as in wine9x's wined3d.def)
        for sym in malloc free realloc calloc strdup _strdup _expand _msize \
                   _msize_int strtoull strtoll \
                   crt_locks_init crt_sse2_is_safe crt_enable_sse2; do
            echo "$sym" >> "$def_file"
        done
    fi

    local count=$(($(wc -l < "$def_file") - 1))
    echo "  Generated $def_file ($count exports)"
}

# ── Detect source files ────────────────────────────────────────────
detect_sources() {
    local src_dir="$1"
    find "$src_dir" -maxdepth 1 -name '*.c' -exec basename {} \; | grep -v '_vk\.c' | grep -v 'shader_spirv\.c' | sort -u
}

# ── Common CFLAGS ──────────────────────────────────────────────────
setup_cflags() {
    local wine_src="$1"
    local version="$2"

    # Create ARRAY_SIZE header (avoids shell quoting issues with -D macro)
    echo '#define ARRAY_SIZE(x) (sizeof(x)/sizeof((x)[0]))' > /tmp/array_size.h
    echo '#define __WINE_ALLOC_SIZE(...)' > /tmp/wine_alloc_size.h
    echo '#define __WINE_MALLOC' >> /tmp/wine_alloc_size.h

    # Remove wine9x's outdated headers — Wine's own are newer
    for h in wined3d.h wgl_driver.h wgl.h wglext.h; do
        if [ -f "$WINE9X/include/wine/$h" ]; then
            mv "$WINE9X/include/wine/$h" "$WINE9X/include/wine/$h.wine9x"
        fi
    done

    # Fix DWORD vs unsigned int mismatches (Wine 5.x-7.x only)
    if grep -q 'context_invalidate_state.*DWORD' "$wine_src/dlls/wined3d/wined3d_private.h" 2>/dev/null; then
        for f in "$wine_src/dlls/wined3d/context.c"; do
            [ -f "$f" ] && sed -i 's/void context_invalidate_state(struct wined3d_context \*context, unsigned int state_id)/void context_invalidate_state(struct wined3d_context *context, DWORD state_id)/' "$f"
        done
        for f in "$wine_src/dlls/wined3d/device.c"; do
            [ -f "$f" ] && sed -i 's/void device_invalidate_state(const struct wined3d_device \*device, unsigned int state_id)/void device_invalidate_state(const struct wined3d_device *device, DWORD state_id)/' "$f"
        done
        for f in "$wine_src/dlls/wined3d/texture.c"; do
            [ -f "$f" ] && sed -i 's/struct wined3d_context \*context, unsigned int location)/struct wined3d_context *context, DWORD location)/' "$f"
        done
    fi

    # qemu-3dfx optimization: skip expensive GL context re-setup in needs_set branch
    for f in "$wine_src/dlls/wined3d/context.c"; do
        [ -f "$f" ] || continue
        if grep -q 'else if (context->needs_set)' "$f"; then
            sed -i '/else if (context->needs_set)/,/}/ s/context_set_gl_context(context);/context_enter(context);/' "$f"
            echo "  Patched context.c: qemu-3dfx needs_set optimization"
        elif grep -q 'else if (context_gl->needs_set)' "$f"; then
            sed -i '/else if (context_gl->needs_set)/,/}/ s/wined3d_context_gl_set_gl_context(context_gl);/wined3d_context_gl_enter(context_gl);/' "$f"
            echo "  Patched context.c: qemu-3dfx needs_set optimization (GL context)"
        fi
    done

    # Strip DUMMYUNIONNAME access (.u., .u1., .u2., .u1.s2.) from wined3d sources
    for f in "$wine_src/dlls/wined3d"/*.c; do
        [ -f "$f" ] && sed -i 's/\.u[0-9][0-9]*\.s[0-9][0-9]*\./\./g; s/\.u[0-9][0-9]*\./\./g; s#->u[0-9][0-9]*\.s[0-9][0-9]*\.#->#g; s#->u[0-9][0-9]*\.#->#g' "$f"
    done
    # Also strip DUMMYUNIONNAME without digit (.u.) from directx.c only
    # (LARGE_INTEGER .u.HighPart, D3DKMT_CREATEDEVICE .u.hAdapter)
    # Other files use .u. for Wine's internal named union (wined3d_rendertarget_view_desc etc.)
    [ -f "$wine_src/dlls/wined3d/directx.c" ] && \
        sed -i 's/\.u\./\./g; s#->u\.#->#g' "$wine_src/dlls/wined3d/directx.c"

    # Fix RTL_CRITICAL_SECTION_DEBUG Spare field (removed in newer MinGW-w64)
    for f in "$wine_src/dlls/wined3d/wined3d_private.h"; do
        [ -f "$f" ] && sed -i 's/->Spare\[0\] *=.*;/;/' "$f"
    done

    # Wine 8.0.2 vkd3d/d3d12 stub headers
    if [ ! -f "$wine_src/include/vkd3d.h" ]; then
        printf '#ifndef VKD3D_STUB_H\n#define VKD3D_STUB_H\n#include <stdarg.h>\ntypedef void (*PFN_vkd3d_log_callback)(const char *, va_list);\nstatic inline void vkd3d_set_log_callback(PFN_vkd3d_log_callback cb) { (void)cb; }\n#endif\n' > "$wine_src/include/vkd3d.h"
    fi
    if [ ! -f "$wine_src/include/d3d12.h" ]; then
        printf '#ifndef D3D12_STUB_H\n#define D3D12_STUB_H\n#endif\n' > "$wine_src/include/d3d12.h"
    fi

    # Hollow out vkd3d_log_callback (uses undeclared vsnprintf/__wine_dbg_output)
    if [ -f "$wine_src/dlls/wined3d/wined3d_main.c" ] && \
       grep -q 'vkd3d_log_callback' "$wine_src/dlls/wined3d/wined3d_main.c" 2>/dev/null; then
        sed -i '/^static void vkd3d_log_callback/,/^}/c\static void vkd3d_log_callback(const char *fmt, va_list args) {}' "$wine_src/dlls/wined3d/wined3d_main.c"
    fi

    # Remove spirv_shader_backend_cleanup call (shader_spirv.c excluded, Wine 6.0+)
    [ -f "$wine_src/dlls/wined3d/wined3d_main.c" ] && \
        sed -i '/wined3d_spirv_shader_backend_cleanup/d' "$wine_src/dlls/wined3d/wined3d_main.c"

    CFLAGS_LIST=(
        -std=c99
        -O3
        -fomit-frame-pointer
        -Wno-discarded-qualifiers
        -Wno-write-strings
        -Wno-cast-qual
        -Wno-incompatible-pointer-types

        # Wine defines
        -D_WIN32 -DWIN32 -D__WINESRC__
        -D_USE_MATH_DEFINES
        -DInterlockedExchangeAddSizeT=InterlockedExchangeAdd
        -DUSE_WIN32_OPENGL
        -DWINE_NOWINSOCK
        -DNDEBUG
        -DWINE_UNICODE_API=""
        -DWINE_SILENT
        -DWINE_NO_TRACE_MSGS
        -DWINE_NO_DEBUG_MSGS
        -DDECLSPEC_HIDDEN= -D__GNU_EXTENSION=
        -DDECLSPEC_HOTPATCH=
        -DDCX_USESTYLE=0x00010000
        -include /tmp/array_size.h
        -include /tmp/wine_alloc_size.h
        -DDLLDIR=\"\" -DBINDIR=\"\" -DLIB_TO_BINDIR=\"\"
        -DLIB_TO_DLLDIR=\"\" -DBIN_TO_DLLDIR=\"\"
        -DLIB_TO_DATADIR=\"\" -DBIN_TO_DATADIR=\"\"
        -DWINVER=0x0400

        # CPU targeting (Win98 compatible)
        -march=pentium2 -mtune=core2
        -fdata-sections -ffunction-sections
        -include stdint.h

        # Include paths — wine9x core, then wine9x wine/ and Wine stock as last resort
        -I"$WINE9X/mingw"
        -I"$WINE9X/include/wine"
        -I"$WINE9X/compact"
        -I"$WINE9X/pthread9x/include"
        -I"$WINE9X/pthread9x/build"
        -idirafter "$WINE9X/include"
        -idirafter "$wine_src/include"
    )

    # VBOX patches
    CFLAGS_LIST+=(
        -DVBOX_WITH_WINE_FIX_IBMTMR
        -DVBOX_WITH_WINE_FIX_QUIRKS
        -DVBOX_WITH_WINE_FIX_PBOPSM
        -DVBOX_WITH_WINE_FIX_INITCLEAR
        -DVBOX_WITH_WINE_FIX_BUFOFFSET
        -DVBOX_WITH_WINE_FIX_STRINFOBUF
        -DVBOX_WITH_WINE_FIX_CURVBO
        -DVBOX_WITH_WINE_FIX_FTOA
        -DVBOX_WITH_WINE_FIX_SURFUPDATA
        -DVBOX_WITH_WINE_FIX_TEXCLEAR
        -DVBOX_WITH_WINE_FIX_SHADERCLEANUP
        -DVBOX_WITH_WINE_FIX_SHADER_DECL
        -DVBOX_WITH_WINE_FIXES
        -DVBOX_WITH_WINE_FIX_POLYOFFSET_SCALE
        -DVBOX_WITH_WINE_FIX_ZEROVERTATTR
        -DVBOX_WITH_WINE_FIX_MUTE_ERRORS
        -DVBOX_WITH_WINE_FIX_BLIT_ALPHATEST
        -DUSE_HOOKS
    )
}

# ── Compile .c files for a DLL ─────────────────────────────────────
compile_dll() {
    local dll_name="$1" wine_src="$2" obj_dir="$3"

    local src_dir="$wine_src/dlls/$dll_name"
    if [ ! -d "$src_dir" ]; then
        echo "  WARNING: $src_dir not found, skipping $dll_name"
        return 1
    fi

    # Detect source files (all .c files in the directory)
    local sources
    sources=$(detect_sources "$src_dir")

    if [ -z "$sources" ]; then
        echo "  WARNING: no source files found for $dll_name"
        return 1
    fi

    mkdir -p "$obj_dir"

    # Add DLL-specific include path (for private headers)
    local dll_cflags=("${CFLAGS_LIST[@]}" -I"$src_dir")

    # For ddraw: use wine9x's mingw/ headers with anonymous unions
    # Add DUMMYUNIONNAME= overrides for anonymous union access
    if [ "$dll_name" = "ddraw" ]; then
        dll_cflags=("${CFLAGS_LIST[@]}")
        dll_cflags+=(
            -DDUMMYUNIONNAME= -DDUMMYUNIONNAME1= -DDUMMYUNIONNAME2=
            -DDUMMYUNIONNAME3= -DDUMMYUNIONNAME4= -DDUMMYUNIONNAME5=
            -DDUMMYUNIONNAME6= -DDUMMYUNIONNAME7= -DDUMMYUNIONNAME8=
            "-I$src_dir"
            '-DDECL_WINELIB_TYPE_AW(type)='
            '-DWINELIB_NAME_AW(func)=func##A'
            '-D__MSABI_LONG(x)=x##l'
            '-DINITGUID'
            '-D__TRY=if(1)'
            '-D__EXCEPT_PAGE_FAULT=else'
            '-D__ENDTRY='
        )
    fi

    # Compile each source file
    local count=0
    for src in $sources; do
        local c_file="$src_dir/$src"
        [ -f "$c_file" ] || continue
        local obj="$obj_dir/${src%.c}.o"
        echo "  CC $dll_name/$src"
        $CC "${dll_cflags[@]}" -c -o "$obj" "$c_file" 2>&1 | while read line; do
            # Only show errors, not warnings during normal build
            if [[ "$line" == *error* ]]; then
                echo "    ERROR: $line"
            fi
        done || true
        if [ -f "$obj" ]; then
            count=$((count + 1))
        fi
    done

    # Compile compact/debug.c
    echo "  CC $dll_name/debug.c"
    $CC "${dll_cflags[@]}" -c -o "$obj_dir/_debug.o" "$WINE9X/compact/debug.c" 2>&1 || true

    # For ddraw, compile exception.asm
    if [ "$dll_name" = "ddraw" ]; then
        if command -v nasm &>/dev/null; then
            echo "  ASM $dll_name/exception.asm"
            nasm -I"$WINE9X/compact/" -f win32 -o "$obj_dir/_exception.o" \
                "$WINE9X/compact/exception.asm" 2>&1 || true
        fi
    fi

    echo "  Compiled $count source files for $dll_name"
    return 0
}

# ── Compile Win98 compat stubs ─────────────────────────────────────
compile_compat() {
    local obj_dir="$1"
    local compat_file="$SCRIPT_DIR/docker/kernel32_compat.c"

    if [ ! -f "$compat_file" ]; then
        return
    fi

    echo "  CC kernel32_compat.c"
    $CC "${CFLAGS_LIST[@]}" -DK32COMPAT_DISPLAY_WRAPPERS -c -o "$obj_dir/_kernel32_compat.o" "$compat_file" 2>&1 || true

    # Compile nocrt entry point (bypasses full CRT startup — matches reference DLLs)
    echo "  CC nocrt_entry.c"
    $CC "${CFLAGS_LIST[@]}" -c -o "$obj_dir/_nocrt_entry.o" "$SCRIPT_DIR/docker/nocrt_entry.c" 2>&1 || true

    # Generate Vulkan stubs from undefined symbols in object files
    echo "  Generating Vulkan stubs"
    nm "$obj_dir"/*.o 2>/dev/null | grep ' U ' | grep 'vk' | \
        awk '{gsub(/^_/,"",$2); print $2}' | sort -u | \
        awk '{print "int " $1 "() { return 0; }"}' > /tmp/vk_stubs.c
    $CC "${CFLAGS_LIST[@]}" -c -o "$obj_dir/_vk_stubs.o" /tmp/vk_stubs.c 2>/dev/null || true

    # Compile vkd3d stubs (Wine 8.0.2+ exports vkd3d functions)
    local vkd3d_stubs="$(dirname "$obj_dir")/vkd3d_stubs.c"
    if [ -f "$vkd3d_stubs" ]; then
        echo "  CC vkd3d_stubs.c"
        $CC "${CFLAGS_LIST[@]}" -c -o "$obj_dir/_vkd3d_stubs.o" "$vkd3d_stubs" 2>/dev/null || true
    fi
}

# ── Link wined3d.dll ───────────────────────────────────────────────
link_wined3d() {
    local obj_dir="$1" output="$2" def_file="$3"
    local pt_build="$WINE9X/pthread9x/build"

    echo "  LD wined3d.dll"
    $CC -shared -static-libgcc \
        -o "$output" \
        "$obj_dir"/*.o \
        "$pt_build/crtfix.o" \
        -L"$pt_build" -lpthread \
        -lgdi32 -lopengl32 \
        -Wl,--allow-multiple-definition \
        -Wl,--out-implib,"$(dirname "$output")/lib$(basename "${output%.dll}").a" \
        -Wl,--enable-stdcall-fixup \
        -Wl,--image-base,0x10000000 \
        "$def_file" 2>&1
}

# ── Link d3d9/d3d8.dll ─────────────────────────────────────────────
link_d3d() {
    local dll_name="$1" obj_dir="$2" output="$3" def_file="$4"
    local pt_build="$WINE9X/pthread9x/build"
    local wined3d_dir="$5"

    echo "  LD $dll_name.dll"
    $CC -shared -static-libgcc \
        -o "$output" \
        "$obj_dir"/*.o \
        "$pt_build/crtfix.o" \
        -L"$wined3d_dir" -lwined3d \
        -lgdi32 \
        -Wl,--allow-multiple-definition \
        -Wl,--out-implib,"$(dirname "$output")/lib$(basename "${output%.dll}").a" \
        -Wl,--enable-stdcall-fixup \
        -Wl,--image-base,0x10000000 \
        "$def_file" 2>&1
}

# ── Link ddraw.dll ─────────────────────────────────────────────────
link_ddraw() {
    local obj_dir="$1" output="$2" def_file="$3"
    local pt_build="$WINE9X/pthread9x/build"
    local wined3d_dir="$4"

    echo "  LD ddraw.dll"
    $CC -shared -static-libgcc \
        -o "$output" \
        "$obj_dir"/*.o \
        "$pt_build/crtfix.o" \
        -L"$wined3d_dir" -lwined3d \
        -luser32 -lgdi32 -ladvapi32 \
        -Wl,--allow-multiple-definition \
        -Wl,--out-implib,"$(dirname "$output")/lib$(basename "${output%.dll}").a" \
        -Wl,--enable-stdcall-fixup \
        -Wl,--image-base,0x10000000 \
        "$def_file" 2>&1
}

# ── Patch ucrtbase imports ─────────────────────────────────────────
patch_ucrt_imports() {
    local outdir="$1"
    python3 -c "
import sys, os, glob
for path in glob.glob(os.path.join(sys.argv[1], '*.dll')):
    with open(path, 'rb') as f: data = f.read()
    p = data.replace(b'ucrtbase.dll\x00', b'msvcrt.dll\x00\x00\x00')
    if p != data:
        with open(path, 'wb') as f: f.write(p)
        print('  [fix] ucrtbase->msvcrt:', os.path.basename(path))
" "$outdir"
}

# ── Patch PE headers for Win98 ─────────────────────────────────────
patch_pe_win98() {
    local py
    for cmd in python3 python; do
        if command -v "$cmd" &>/dev/null; then py="$cmd"; break; fi
    done
    if [ -z "$py" ]; then
        echo "    WARNING: no python found — skipping PE patching"
        return 0
    fi
    "$py" "$SCRIPT_DIR/docker/patch_pe_win98.py" "$1"
}

# ── Build one version ──────────────────────────────────────────────
build_version() {
    local version="$1" branch="$2" ext="$3"

    if [ ${#FILTER_VERSIONS[@]} -gt 0 ]; then
        local skip=1
        for fv in "${FILTER_VERSIONS[@]}"; do
            [ "$fv" = "$version" ] && skip=0
        done
        [ "$skip" = "1" ] && return 0
    fi

    local outdir="$OUTPUT_BASE/$version"
    if [ "$FORCE" = "0" ] && [ -f "$outdir/wined3d.dll" ]; then
        echo "=== Skipping Wine $version (already built — use --force to rebuild) ==="
        return 0
    fi

    echo "=== Building Wine $version ==="

    # Download and extract Wine source
    download_wine "$version" "$branch" "$ext" || return 1
    local wine_src="$SCRIPT_DIR/wine-${version}"

    # Setup build directory
    local build_dir="$SCRIPT_DIR/build/$version"
    rm -rf "$build_dir"
    mkdir -p "$build_dir" "$outdir"

    # Setup CFLAGS
    setup_cflags "$wine_src" "$version"

    # ── Copy extra source files into Wine tree ──
    cp "$SCRIPT_DIR/docker/d3dkmt_stubs.c" "$wine_src/dlls/wined3d/d3dkmt_stubs.c" 2>/dev/null || true
    cp "$SCRIPT_DIR/qemu3dfx_hooks.c" "$wine_src/dlls/wined3d/qemu3dfx_hooks.c" 2>/dev/null || true
    cp "$SCRIPT_DIR/qemu3dfx_ddraw_hooks.c" "$wine_src/dlls/ddraw/qemu3dfx_ddraw_hooks.c" 2>/dev/null || true
    cp "$SCRIPT_DIR/qemu3dfx_ddraw_passthrough.c" "$wine_src/dlls/ddraw/qemu3dfx_ddraw_passthrough.c" 2>/dev/null || true

    # ── ddraw spec modifications (stubs → stdcall) ──
    if [ -f "$wine_src/dlls/ddraw/ddraw.spec" ]; then
        sed -i \
            -e 's/^@ stub DDHAL32_VidMemAlloc$/@ stdcall DDHAL32_VidMemAlloc(ptr long long long)/' \
            -e 's/^@ stub DDHAL32_VidMemFree$/@ stdcall DDHAL32_VidMemFree(ptr long long)/' \
            -e 's/^@ stub DDInternalLock$/@ stdcall DDInternalLock(ptr ptr ptr long)/' \
            -e 's/^@ stub DDInternalUnlock$/@ stdcall DDInternalUnlock(ptr ptr long)/' \
            -e 's/^@ stub DSoundHelp$/@ stdcall DSoundHelp(ptr ptr long)/' \
            -e 's/^@ stub GetNextMipMap$/@ stdcall GetNextMipMap(ptr)/' \
            -e 's/^@ stub HeapVidMemAllocAligned$/@ stdcall HeapVidMemAllocAligned(ptr long long ptr ptr)/' \
            -e 's/^@ stub InternalLock$/@ stdcall InternalLock(ptr ptr ptr long)/' \
            -e 's/^@ stub InternalUnlock$/@ stdcall InternalUnlock(ptr ptr long)/' \
            -e 's/^@ stub LateAllocateSurfaceMem$/@ stdcall LateAllocateSurfaceMem(ptr long long long)/' \
            -e 's/^@ stub VidMemAlloc$/@ stdcall VidMemAlloc(long long ptr)/' \
            -e 's/^@ stub VidMemAmountFree$/@ stdcall VidMemAmountFree(ptr)/' \
            -e 's/^@ stub VidMemFini$/@ stdcall VidMemFini(ptr)/' \
            -e 's/^@ stub VidMemFree$/@ stdcall VidMemFree(ptr long)/' \
            -e 's/^@ stub VidMemInit$/@ stdcall VidMemInit(long long long long long)/' \
            -e 's/^@ stub VidMemLargestFree$/@ stdcall VidMemLargestFree(ptr)/' \
            "$wine_src/dlls/ddraw/ddraw.spec"
        grep -q 'AcquireDDThreadLock' "$wine_src/dlls/ddraw/ddraw.spec" || \
            printf '@ stdcall AcquireDDThreadLock()\n@ stdcall ReleaseDDThreadLock()\n@ stdcall CompleteCreateSysmemSurface(ptr)\n@ stdcall D3DParseUnknownCommand(ptr ptr)\n' \
                >> "$wine_src/dlls/ddraw/ddraw.spec"
    fi

    # ── d3d8_main.c bool fix ──
    if [ -f "$wine_src/dlls/d3d8/d3d8_main.c" ]; then
        sed -i \
            -e 's/BOOL bool,/BOOL bool_val,/g' \
            -e 's/, bool,/, bool_val,/g' \
            -e 's/, bool)/, bool_val)/g' \
            "$wine_src/dlls/d3d8/d3d8_main.c"
    fi

    # ── W-version API redirects → kernel32_compat wrappers ──
    for f in "$wine_src/dlls/wined3d"/*.c; do
        [ -f "$f" ] || continue
        case "$f" in */kernel32_compat.c|*/d3dkmt_stubs.c|*/qemu3dfx_hooks.c) continue ;; esac
        for _func in EnumDisplayDevicesW EnumDisplaySettingsW EnumDisplaySettingsExW \
                    GetMonitorInfoW EnumDisplayMonitors MonitorFromWindow MonitorFromPoint \
                    ChangeDisplaySettingsExW IsBadStringPtrW FreeLibraryAndExitThread \
                    GetModuleHandleExW \
                    GetVersionExW; do
            grep -q "$_func" "$f" 2>/dev/null || continue
            case "$_func" in
                EnumDisplayDevicesW) _compat=wine_k32compat_EDD_W ;;
                EnumDisplaySettingsW) _compat=wine_k32compat_EDS_W ;;
                EnumDisplaySettingsExW) _compat=wine_k32compat_EDSE_W ;;
                GetMonitorInfoW) _compat=wine_k32compat_GMI_W ;;
                EnumDisplayMonitors) _compat=wine_k32compat_EDM ;;
                MonitorFromWindow) _compat=wine_k32compat_MFW ;;
                MonitorFromPoint) _compat=wine_k32compat_MFP ;;
                ChangeDisplaySettingsExW) _compat=wine_k32compat_CDSE_W ;;
                IsBadStringPtrW) _compat=wine_k32compat_IBSP_W ;;
                FreeLibraryAndExitThread) _compat=wine_k32compat_FLAET ;;
                GetModuleHandleExW) _compat=wine_k32compat_GMHEW ;;
                GetVersionExW) _compat=wine_k32compat_GVXW ;;
            esac
            sed -i "1i #define $_func $_compat" "$f"
        done
    done
    for f in "$wine_src/dlls/ddraw"/*.c; do
        [ -f "$f" ] || continue
        case "$f" in */kernel32_compat.c|*/qemu3dfx_ddraw*) continue ;; esac
        grep -q 'GetModuleHandleExW' "$f" 2>/dev/null || continue
        sed -i '1i #define GetModuleHandleExW wine_k32compat_GMHEW' "$f"
    done

    # ── RtlIsCriticalSectionLockedByThread redirect (3.0.5+) ──
    if [ -f "$wine_src/dlls/wined3d/cs.c" ]; then
        sed -i 's/!RtlIsCriticalSectionLockedByThread(NtCurrentTeb()->Peb->LoaderLock)/1/' "$wine_src/dlls/wined3d/cs.c"
    fi

    # ── Patch ddraw source for qemu-3dfx hooks ──
    if [ -f "$wine_src/dlls/ddraw/main.c" ]; then
        sed -i 's/^BOOL WINAPI DllMain/extern void qemu3dfx_ddraw_passthrough_init(void);\n\nBOOL WINAPI DllMain/' "$wine_src/dlls/ddraw/main.c"
        sed -i 's/DisableThreadLibraryCalls(inst);/DisableThreadLibraryCalls(inst);\n        qemu3dfx_ddraw_passthrough_init();/' "$wine_src/dlls/ddraw/main.c"
        # Remove wine/exception.h include — uses Prev but MinGW-w64 has Next in EXCEPTION_REGISTRATION_RECORD
        find "$wine_src/dlls/ddraw" -name '*.c' -exec sed -i '/#include "wine\/exception.h"/d' {} +
        # Stub __wine_register_resources (Wine build-system generated, not available)
        sed -i 's/return __wine_register_resources( instance );/return S_OK;/' "$wine_src/dlls/ddraw/main.c"
        sed -i 's/return __wine_unregister_resources( instance );/return S_OK;/' "$wine_src/dlls/ddraw/main.c"
    fi
    if [ -f "$wine_src/dlls/ddraw/ddraw.c" ]; then
        sed -i 's/#include "ddraw_private.h"/#include "ddraw_private.h"\nextern void qemu3dfx_ddraw_cooplevel(DWORD *);/' "$wine_src/dlls/ddraw/ddraw.c"
        sed -i 's/DDRAW_dump_cooperativelevel(cooplevel);/DDRAW_dump_cooperativelevel(cooplevel);\n    qemu3dfx_ddraw_cooplevel(\&cooplevel);/' "$wine_src/dlls/ddraw/ddraw.c"
    fi
    if [ -f "$wine_src/dlls/ddraw/surface.c" ]; then
        sed -i 's/#include "ddraw_private.h"/#include "ddraw_private.h"\nextern void qemu3dfx_ddraw_blit(void);\nextern void qemu3dfx_ddraw_flip(void);\nextern void qemu3dfx_ddraw_rtv(void *);/' "$wine_src/dlls/ddraw/surface.c"
        sed -i 's/return wined3d_texture_blt(dst_surface/qemu3dfx_ddraw_blit();\n    return wined3d_texture_blt(dst_surface/' "$wine_src/dlls/ddraw/surface.c"
        sed -i 's/return wined3d_device_context_blt(ddraw/qemu3dfx_ddraw_blit();\n    return wined3d_device_context_blt(ddraw/' "$wine_src/dlls/ddraw/surface.c"
        sed -i 's/\(DDSCAPS2\? caps = {DDSCAPS_FLIP.*\)/\1\n    qemu3dfx_ddraw_flip();/' "$wine_src/dlls/ddraw/surface.c"
        sed -i 's/\(tmp_rtv = ddraw_surface_get_rendertarget_view(dst_impl);\)/\1\n    qemu3dfx_ddraw_rtv(tmp_rtv);/' "$wine_src/dlls/ddraw/surface.c"
    fi

    # ── Generate .def files ──
    for dll_name in wined3d d3d9 d3d8 ddraw; do
        local spec="$wine_src/dlls/$dll_name/$dll_name.spec"
        if [ -f "$spec" ]; then
            generate_def "$spec" "$build_dir/$dll_name.def" "$dll_name"
        fi
    done

    # ── Generate vkd3d stubs (Wine 8.0.2+ exports vkd3d functions) ──
    local wined3d_spec="$wine_src/dlls/wined3d/wined3d.spec"
    if [ -f "$wined3d_spec" ] && grep -q 'vkd3d' "$wined3d_spec" 2>/dev/null; then
        grep -E '^\s*@\s+(stdcall|cdecl)\s+vkd3d' "$wined3d_spec" | \
            sed -E 's/^\s*@\s+(stdcall|cdecl)\s+([A-Za-z_][A-Za-z0-9_]*).*/int \2() { return 0; }/' \
            > "$build_dir/vkd3d_stubs.c"
        echo "  Generated vkd3d stubs ($(grep -c 'return 0' "$build_dir/vkd3d_stubs.c") functions)"
    fi

    # ── Compile wined3d ──
    echo "--- wined3d ---"
    local wined3d_objs="$build_dir/wined3d"
    if compile_dll wined3d "$wine_src" "$wined3d_objs"; then
        compile_compat "$wined3d_objs"
        link_wined3d "$wined3d_objs" "$build_dir/wined3d.dll" "$build_dir/wined3d.def"
        cp "$build_dir/wined3d.dll" "$outdir/"
        echo "  Built wined3d.dll ($(stat -f%z "$outdir/wined3d.dll" 2>/dev/null || stat -c%s "$outdir/wined3d.dll") bytes)"
    else
        echo "  FAILED: wined3d compilation"
        return 1
    fi

    # ── Compile d3d9, d3d8, ddraw ──
    for dll_name in d3d9 d3d8 ddraw; do
        echo "--- $dll_name ---"
        local dll_objs="$build_dir/$dll_name"
        local def_file="$build_dir/$dll_name.def"
        if [ ! -f "$def_file" ]; then
            echo "  WARNING: no .def file for $dll_name, skipping"
            continue
        fi
        if compile_dll "$dll_name" "$wine_src" "$dll_objs"; then
            compile_compat "$dll_objs"
            if [ "$dll_name" = "ddraw" ]; then
                link_ddraw "$dll_objs" "$build_dir/$dll_name.dll" "$def_file" "$build_dir"
            else
                link_d3d "$dll_name" "$dll_objs" "$build_dir/$dll_name.dll" "$def_file" "$build_dir"
            fi
            cp "$build_dir/$dll_name.dll" "$outdir/"
            echo "  Built $dll_name.dll"
        else
            echo "  WARNING: $dll_name compilation skipped"
        fi
    done

    # ── Post-processing ──
    patch_ucrt_imports "$outdir"

    # Strip COFF symbols
    for dll in "$outdir"/*.dll; do
        [ -f "$dll" ] || continue
        strip "$dll" 2>/dev/null && echo "  Stripped $(basename "$dll")"
    done

    patch_pe_win98 "$outdir"

    printf "Built on %s\n" "$(date '+%T %b %-e %Y')" > "$outdir/build-timestamp"
    chmod +x "$outdir/build-timestamp"

    echo "Done: $(ls "$outdir/")"
}

# ── Main ────────────────────────────────────────────────────────────
main() {
    echo "=== Wine D3D DLL Builder (wine9x direct compilation) ==="

    # Verify wine9x-support exists
    if [ ! -d "$WINE9X" ]; then
        echo "ERROR: wine9x-support/ not found."
        echo "  Run: git submodule add https://github.com/crag-hack/wine9x.git wine9x-support"
        echo "  Then: cd wine9x-support && git submodule update --init --recursive"
        exit 1
    fi

    # Verify pthread9x submodule
    if [ ! -d "$WINE9X/pthread9x/src" ]; then
        echo "Initializing wine9x submodules..."
        cd "$WINE9X" && git submodule update --init --recursive
        cd "$SCRIPT_DIR"
    fi

    # Setup toolchain (symbol rename, ucrtcompat, gcc wrapper)
    setup_toolchain

    # Build pthread9x if needed
    if [ ! -f "$WINE9X/pthread9x/build/libpthread.a" ]; then
        build_pthread9x
    fi

    # Build each version
    for entry in "${VERSIONS[@]}"; do
        IFS=: read WINE_VERSION WINE_BRANCH WINE_EXT <<< "$entry"
        build_version "$WINE_VERSION" "$WINE_BRANCH" "$WINE_EXT"
    done

    # Summary
    echo ""
    echo "=== Summary ==="
    for entry in "${VERSIONS[@]}"; do
        IFS=: read WINE_VERSION _ <<< "$entry"
        if [ -f "$OUTPUT_BASE/$WINE_VERSION/wined3d.dll" ]; then
            echo "  ✓ $WINE_VERSION"
        else
            echo "  ✗ $WINE_VERSION (missing)"
        fi
    done
}

main "$@"
