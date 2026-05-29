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

    # Patch _mingw.h: __LONG32 long → int (matches Dockerfile line 34).
    # MinGW-w64 defines DWORD as unsigned __LONG32, so this makes DWORD = unsigned int,
    # matching Wine's definition. Without this, DWORD = unsigned long and Wine 6.0.4/7.0.2
    # fail with conflicting types (declarations use DWORD, definitions use unsigned int).
    local _mingw_h=""
    local _gcc_inc
    _gcc_inc="$(gcc -print-file-name=include 2>/dev/null)"
    for candidate in \
        "$_gcc_inc/_mingw.h" \
        "$_gcc_inc/../include/_mingw.h" \
        "$(dirname "$(gcc -print-file-name=libmingw32.a 2>/dev/null)")/../include/_mingw.h"; do
        if [ -f "$candidate" ]; then
            _mingw_h="$candidate"
            break
        fi
    done
    if [ -n "$_mingw_h" ] && grep -q '#define __LONG32 long' "$_mingw_h"; then
        sed -i 's/#define __LONG32 long/#define __LONG32 int/' "$_mingw_h"
        echo "  Patched _mingw.h: __LONG32 long → int"
    fi

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

# ── Build pthread9x minimal (only CRT/allocator, no threading) ────
# Wine wined3d does NOT use pthread functions — only needs the custom
# allocator (malloc/free/calloc/realloc), crtfix (IsProcessorFeaturePresent,
# TLS stubs), lockex (crt_lock/crt_unlock), and TryEnterCriticalSection.
# The full libpthread.a pulls in 12 extra KERNEL32 imports (CreateEventA,
# SetEvent, etc.) that crash the DLL on Win98 during CRT init.
build_pthread9x() {
    echo "=== Building pthread9x (minimal) ==="
    local pt_dir="$WINE9X/pthread9x"
    if [ ! -d "$pt_dir/src" ]; then
        echo "ERROR: pthread9x submodule not initialized"
        echo "  Run: cd wine9x-support && git submodule update --init --recursive"
        exit 1
    fi

    mkdir -p "$pt_dir/build"
    cd "$pt_dir/build"

    local CFLAGS="-std=gnu99 -O3 -fno-exceptions -march=pentium2 -mtune=core2"
    CFLAGS+=" -I../include -I. -DNDEBUG -DHAVE_CONFIG_H"
    CFLAGS+=" -Wall -DWIN32_LEAN_AND_MEAN -DNEW_ALLOC -DDEFAULT_HEAP"

    # Patch crtfix.c: no-op __chk_fail (removes GetCurrentProcess+TerminateProcess imports)
    sed -i '/^void __cdecl.*__chk_fail/,/^}/c\void __cdecl __attribute__((__noreturn__)) __chk_fail(void) { for(;;); }' ../extra/crtfix.c

    # Fix Interlocked casts: long* → LONG* (match __LONG32=int from MinGW-w64)
    find ../src -name '*.c' -exec sed -i 's/(long\*)/(LONG*)/g' {} +
    find ../src \( -name '*.c' -o -name '*.h' \) -exec sed -i 's/volatile long /volatile LONG /g' {} +
    find ../src -name '*.c' -exec sed -i 's/(DWORD \*) &info/(ULONG_PTR *) \&info/g' {} +

    # Only compile the minimal set — no thread/mutex/cond/barrier/etc.
    echo "  CC crtfix.c"
    $CC $CFLAGS -c -o crtfix.o ../extra/crtfix.c

    echo "  CC memory.c"
    $CC $CFLAGS -c -o memory.o ../extra/memory.c

    echo "  CC lockex.c"
    $CC $CFLAGS -c -o lockex.o ../extra/lockex.c

    echo "  CC tryentercriticalsection.c"
    $CC $CFLAGS -c -o tryentercriticalsection.o ../src/tryentercriticalsection.c

    cd "$SCRIPT_DIR"
    echo "=== pthread9x minimal built ==="
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

    # Parse Wine .spec: @ stdcall/cdecl func_name(params)
    # Note: @ stub entries are NOT parsed — many are unimplemented COM methods.
    # HAL stubs and custom exports are added explicitly below.
    grep -E '^\s*@\s+(stdcall|cdecl)' "$spec_file" | \
        grep -v '\-private' | \
        sed -E 's/^\s*@\s+(stdcall|cdecl)(\s+-(noname|ordinal|stub|ignore))*\s+([A-Za-z_][A-Za-z0-9_]*).*/\4/' | \
        grep -v '^$' >> "$def_file"

    # wined3d: no special filtering (vkd3d stubs are in wine_spec_stubs.c)
    if [ "$dll_name" = "wined3d" ]; then
        true
    fi

    # Add wine9x custom exports for wined3d
    if [ "$dll_name" = "wined3d" ]; then
        for sym in wined3d_hal_3dfx wined3d_enum_hal_last \
                   wined3d_passthru wined3d_override_cooplevel \
                   wined3d_override_rendertarget_view \
                   wined3d_blit_fpslimit wined3d_flip_fpslimit \
                   wined3d_surface_ddheap \
                   wined3d_streaming_buffer_map \
                   wined3d_streaming_buffer_unmap \
                   wined3d_streaming_buffer_upload; do
            grep -q "^${sym}$" "$def_file" || echo "$sym" >> "$def_file"
        done
        for sym in malloc free realloc calloc strdup _strdup _expand _msize \
                   _msize_int strtoull strtoll \
                   crt_locks_init crt_sse2_is_safe crt_enable_sse2; do
            echo "$sym" >> "$def_file"
        done
    fi

    # ddraw: add HAL stubs (from qemu3dfx_ddraw_hooks.c) and COM exports
    # (from Wine main.c, filtered as -private above)
    if [ "$dll_name" = "ddraw" ]; then
        for sym in AcquireDDThreadLock ReleaseDDThreadLock \
                   D3DParseUnknownCommand DDInternalLock DDInternalUnlock \
                   CompleteCreateSysmemSurface \
                   DDHAL32_VidMemAlloc DDHAL32_VidMemFree \
                   DSoundHelp GetNextMipMap HeapVidMemAllocAligned \
                   InternalLock InternalUnlock LateAllocateSurfaceMem \
                   VidMemAlloc VidMemAmountFree VidMemFini VidMemFree \
                   VidMemInit VidMemLargestFree \
                   DllCanUnloadNow DllGetClassObject \
                   DllRegisterServer DllUnregisterServer; do
            grep -q "^${sym}$" "$def_file" || echo "$sym" >> "$def_file"
        done
    fi

    # d3d9: add stub exports (@ stub in Wine spec, no implementation)
    if [ "$dll_name" = "d3d9" ]; then
        for sym in DebugSetLevel PSGPError PSGPSampleTexture; do
            grep -q "^${sym}$" "$def_file" || echo "$sym" >> "$def_file"
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
    for h in wined3d.h wgl_driver.h wgl.h; do
        if [ -f "$WINE9X/include/wine/$h" ]; then
            mv "$WINE9X/include/wine/$h" "$WINE9X/include/wine/$h.wine9x"
        fi
    done
    # Patch wine9x's wglext.h: MinGW-w64's wingdi.h defines overlapping types.
    # Replace DECLARE_HANDLE (struct body + typedef) with typedef-only forward decls.
    # Also remove the _GPU_DEVICE struct body (already in wingdi.h).
    local _wglext="$WINE9X/include/wine/wglext.h"
    if [ -f "$_wglext" ]; then
        # DECLARE_HANDLE replacements (struct body + typedef → typedef only)
        sed -i 's/^DECLARE_HANDLE(HPBUFFERARB);$/typedef struct HPBUFFERARB__ *HPBUFFERARB;/' "$_wglext"
        sed -i 's/^DECLARE_HANDLE(HPBUFFEREXT);$/typedef struct HPBUFFEREXT__ *HPBUFFEREXT;/' "$_wglext"
        sed -i 's/^DECLARE_HANDLE(HVIDEOOUTPUTDEVICENV);$/typedef struct HVIDEOOUTPUTDEVICENV__ *HVIDEOOUTPUTDEVICENV;/' "$_wglext"
        sed -i 's/^DECLARE_HANDLE(HVIDEOINPUTDEVICENV);$/typedef struct HVIDEOINPUTDEVICENV__ *HVIDEOINPUTDEVICENV;/' "$_wglext"
        sed -i 's/^DECLARE_HANDLE(HPVIDEODEV);$/typedef struct HPVIDEODEV__ *HPVIDEODEV;/' "$_wglext"
        sed -i 's/^DECLARE_HANDLE(HPGPUNV);$/typedef struct HPGPUNV__ *HPGPUNV;/' "$_wglext"
        sed -i 's/^DECLARE_HANDLE(HGPUNV);$/typedef struct HGPUNV__ *HGPUNV;/' "$_wglext"
        # _GPU_DEVICE struct: replace full body with forward declaration
        perl -0777 -pi -e 's/typedef struct _GPU_DEVICE \{[^}]+\} GPU_DEVICE, \*PGPU_DEVICE;/typedef struct _GPU_DEVICE GPU_DEVICE, *PGPU_DEVICE;/' "$_wglext"
    fi


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

    # Remove vkd3d (Wine 8.0+ Vulkan D3D, not needed for Win98)
    if [ -f "$wine_src/dlls/wined3d/wined3d_main.c" ]; then
        sed -i '/#include <vkd3d.h>/d' "$wine_src/dlls/wined3d/wined3d_main.c" 2>/dev/null || true
        sed -i '/WINE_DECLARE_DEBUG_CHANNEL(vkd3d)/d' "$wine_src/dlls/wined3d/wined3d_main.c" 2>/dev/null || true
        perl -0777 -pi -e 's/static void vkd3d_log_callback\(.*?\n\}/static void vkd3d_log_callback(void) { }/s' "$wine_src/dlls/wined3d/wined3d_main.c" 2>/dev/null || true
        sed -i '/vkd3d_set_log_callback/d' "$wine_src/dlls/wined3d/wined3d_main.c" 2>/dev/null || true
        sed -i '/VKD3D_DEBUG/d; /VKD3D_SHADER_DEBUG/d; /TRACE_ON(vkd3d)/d; /WARN_ON(vkd3d)/d; /FIXME_ON(vkd3d)/d; /ERR_ON(vkd3d)/d' "$wine_src/dlls/wined3d/wined3d_main.c" 2>/dev/null || true
    fi

    # CS_OWNDC: required for Wine's window class to work correctly on Win98
    if [ -f "$wine_src/dlls/wined3d/wined3d_main.c" ]; then
        sed -i 's/CS_HREDRAW | CS_VREDRAW/CS_HREDRAW | CS_VREDRAW | CS_OWNDC/' "$wine_src/dlls/wined3d/wined3d_main.c"
    fi

    # Win9x: replace static CRITICAL_SECTION initializers with runtime InitializeCriticalSection().
    # Statically initialized CS (with DebugInfo pointer) crashes EnterCriticalSection on Win98.
    # Wine9x commit: "windows 9x require to inicialize critical section"
    if [ -f "$wine_src/dlls/wined3d/wined3d_main.c" ]; then
        perl -pi -e 's/^static CRITICAL_SECTION wined3d_cs = \{.*\};/\/\* runtime initialized for Win9x \*\//' "$wine_src/dlls/wined3d/wined3d_main.c"
        perl -pi -e 's/^static CRITICAL_SECTION wined3d_wndproc_cs = \{.*\};/\/\* runtime initialized for Win9x \*\//' "$wine_src/dlls/wined3d/wined3d_main.c"
        perl -pi -e 'if (/DisableThreadLibraryCalls/) { $_ .= "    InitializeCriticalSection(&wined3d_cs);\n    InitializeCriticalSection(&wined3d_wndproc_cs);\n" }' "$wine_src/dlls/wined3d/wined3d_main.c"
    fi

    # Win9x: AllocateLocallyUniqueId fails on Win98 (NT-only API, returns FALSE).
    # Stock Wine treats this as fatal and returns FALSE from adapter init, killing all D3D detection.
    # wine9x fix: comment out "return FALSE" and fabricate a LUID from system time.
    if [ -f "$wine_src/dlls/wined3d/directx.c" ]; then
        perl -pi -0777 -e 's/(if \(!AllocateLocallyUniqueId\(&adapter->luid\)\)\s*\{\s*)(ERR|WARN)\("[^"]*"[^;]*;\s*return FALSE;/${1}FILETIME _ftm_luid;\n        WARN("LUID alloc failed, using time fallback.\\n");\n        GetSystemTimeAsFileTime(\&_ftm_luid);\n        adapter->luid.HighPart = _ftm_luid.dwLowDateTime;\n        adapter->luid.LowPart = _ftm_luid.dwHighDateTime;/s' "$wine_src/dlls/wined3d/directx.c"
        echo "  Patched AllocateLocallyUniqueId fallback for Win9x"
    fi

    # Win9x: Load ALL WGL functions from opengl32.dll.
    # Stock Wine only loads SwapBuffers + GetPixelFormat, leaving
    # p_wglMakeCurrent etc. as garbage pointers → crash at 8B1CEC83.
    # wine9x fix: load all core WGL functions explicitly.
    for _wglfile in "$wine_src/dlls/wined3d/directx.c" "$wine_src/dlls/wined3d/adapter_gl.c"; do
        [ -f "$_wglfile" ] || continue
        perl -pi -e 'if (/p_wglSwapBuffers\s*=.*GetProcAddress\(mod_gl/) { $_ .= "        gl_info->gl_ops.wgl.p_wglCopyContext         = (void *)GetProcAddress(mod_gl, \"wglCopyContext\");\n" . "        gl_info->gl_ops.wgl.p_wglDescribePixelFormat = (void *)GetProcAddress(mod_gl, \"wglDescribePixelFormat\");\n" . "        gl_info->gl_ops.wgl.p_wglGetProcAddress      = (void *)GetProcAddress(mod_gl, \"wglGetProcAddress\");\n" . "        gl_info->gl_ops.wgl.p_wglMakeCurrent         = (void *)GetProcAddress(mod_gl, \"wglMakeCurrent\");\n" . "        gl_info->gl_ops.wgl.p_wglSetPixelFormat      = (void *)GetProcAddress(mod_gl, \"wglSetPixelFormat\");\n" . "        gl_info->gl_ops.wgl.p_wglShareLists          = (void *)GetProcAddress(mod_gl, \"wglShareLists\");\n" }' "$_wglfile"
        echo "  Patched WGL function loading in $(basename "$_wglfile")"
    done

    # ── Remove WGL query renderer extensions (not in wine9x headers) ──
    if [ -f "$wine_src/dlls/wined3d/directx.c" ]; then
        sed -i '/USE_GL_FUNC(wglQuery.*Renderer.*WINE)/d' "$wine_src/dlls/wined3d/directx.c" 2>/dev/null || true
        sed -i '/wglQueryCurrentRendererIntegerWINE/d' "$wine_src/dlls/wined3d/directx.c" 2>/dev/null || true
        sed -i '/wglQueryRendererIntegerWINE/d' "$wine_src/dlls/wined3d/directx.c" 2>/dev/null || true
        sed -i '/WGL_RENDERER_VENDOR_ID_WINE/d; /WGL_RENDERER_DEVICE_ID_WINE/d; /WGL_RENDERER_VIDEO_MEMORY_WINE/d' "$wine_src/dlls/wined3d/directx.c" 2>/dev/null || true
        sed -i '/WGL_WINE_query_renderer/d' "$wine_src/dlls/wined3d/directx.c" 2>/dev/null || true
    fi
    if [ -f "$wine_src/dlls/wined3d/adapter_gl.c" ]; then
        sed -i '/USE_GL_FUNC(wglQueryCurrentRendererIntegerWINE)/d' "$wine_src/dlls/wined3d/adapter_gl.c" 2>/dev/null || true
        sed -i '/USE_GL_FUNC(wglQueryCurrentRendererStringWINE)/d' "$wine_src/dlls/wined3d/adapter_gl.c" 2>/dev/null || true
        sed -i '/USE_GL_FUNC(wglQueryRendererIntegerWINE)/d' "$wine_src/dlls/wined3d/adapter_gl.c" 2>/dev/null || true
        sed -i '/USE_GL_FUNC(wglQueryRendererStringWINE)/d' "$wine_src/dlls/wined3d/adapter_gl.c" 2>/dev/null || true
        sed -i '/WGL_WINE_query_renderer/d' "$wine_src/dlls/wined3d/adapter_gl.c" 2>/dev/null || true
        perl -0777 -pi -e 's/if \(gl_info->supported\[WGL_WINE_QUERY_RENDERER\]\)\s*\{(?:[^{}]+|\{(?:[^{}]+|\{[^{}]*\})*\})*\}/if (0) { }/g' "$wine_src/dlls/wined3d/adapter_gl.c" 2>/dev/null || true
        # Remove GL memory object extensions (not in wine9x)
        sed -i '/USE_GL_FUNC(glGetUnsignedByte/d' "$wine_src/dlls/wined3d/adapter_gl.c" 2>/dev/null || true
        perl -0777 -pi -e 's/if \(gl_info->supported\[EXT_MEMORY_OBJECT\]\)\s*\{(?:[^{}]+|\{(?:[^{}]+|\{[^{}]*\})*\})*\}/if (0) { }/g' "$wine_src/dlls/wined3d/adapter_gl.c" 2>/dev/null || true
    fi

    # ── Fix GL extension naming: wine9x uses EXT suffix ──
    find "$wine_src/dlls/wined3d" -name '*.c' -exec sed -i 's/p_glPolygonOffsetClamp(/p_glPolygonOffsetClampEXT(/g; s/GL_TEXTURE_MAX_ANISOTROPY)/GL_TEXTURE_MAX_ANISOTROPY_EXT)/g; s/GL_TEXTURE_MAX_ANISOTROPY,/GL_TEXTURE_MAX_ANISOTROPY_EXT,/g; s/GL_MAX_TEXTURE_MAX_ANISOTROPY\b/GL_MAX_TEXTURE_MAX_ANISOTROPY_EXT/g' {} + 2>/dev/null || true
    if [ -f "$wine_src/dlls/wined3d/adapter_gl.c" ]; then
        sed -i 's/USE_GL_FUNC(glPolygonOffsetClamp)/USE_GL_FUNC(glPolygonOffsetClampEXT)/g' "$wine_src/dlls/wined3d/adapter_gl.c" 2>/dev/null || true
        sed -i '/MAP_GL_FUNCTION(glPolygonOffsetClamp,/d' "$wine_src/dlls/wined3d/adapter_gl.c" 2>/dev/null || true
    fi

    # ── Add wglext.h to all wined3d .c files after wined3d_private.h ──
    find "$wine_src/dlls/wined3d" -name '*.c' -exec grep -l 'wined3d_private\.h' {} \; | \
        xargs -I{} sed -i '/#include "wined3d_private.h"/a\#include "wine/wglext.h"' {} 2>/dev/null || true

    CFLAGS_LIST=(
        -std=c99
        -O3
        -fomit-frame-pointer
        -Wno-discarded-qualifiers
        -Wno-write-strings
        -Wno-cast-qual
        -Wno-incompatible-pointer-types
        -Wno-implicit-function-declaration

        # Wine defines
        -D_WIN32 -DWIN32 -D__WINESRC__
        -D_USE_MATH_DEFINES
        -DInterlockedExchangeAddSizeT=InterlockedExchangeAdd
        -DUSE_WIN32_OPENGL
        -DWINE_NOWINSOCK
        -DNDEBUG
        -D__USE_MINGW_ANSI_STDIO=0
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

    # Verify critical files compiled successfully
    if [ "$dll_name" = "wined3d" ]; then
        for critical in directx.o adapter_gl.o wined3d_main.o context.o; do
            if [ ! -f "$obj_dir/$critical" ]; then
                echo "  WARNING: $dll_name/$critical is MISSING — DLL will be broken!"
            fi
        done
    fi
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

    # Compile static copysign replacement (avoids importing _copysign from msvcrt,
    # which doesn't exist in Win98's VC6-era MSVCRT.DLL)
    echo "  CC copysign.c"
    $CC "${CFLAGS_LIST[@]}" -c -o "$obj_dir/_copysign.o" "$SCRIPT_DIR/docker/copysign.c" 2>&1 || true

    # Compile custom CRT entry point. With -nodefaultlibs, MinGW's standard CRT
    # (libmingw32/libmingwex) is not linked, so we must provide our own DllMainCRTStartup.
    # This avoids pulling in MinGW's threading support (CreateEventA, WaitForSingleObject,
    # etc.) that crashes on Win98.
    echo "  CC nocrt_entry.c"
    $CC "${CFLAGS_LIST[@]}" -c -o "$obj_dir/_nocrt_entry.o" "$SCRIPT_DIR/docker/nocrt_entry.c" 2>&1 || true

    # Compile pre-built Vulkan stubs (Win98 doesn't use Vulkan)
    echo "  CC vk_stubs.c"
    $CC "${CFLAGS_LIST[@]}" -c -o "$obj_dir/_vk_stubs.o" "$SCRIPT_DIR/docker/vk_stubs.c" 2>/dev/null || true

    # Compile libwine_stubs (Wine debug/log stubs, wine_get_version, atexit)
    echo "  CC libwine_stubs.c"
    $CC "${CFLAGS_LIST[@]}" -c -o "$obj_dir/_libwine_stubs.o" "$SCRIPT_DIR/docker/libwine_stubs.c" 2>/dev/null || true

    # Compile Wine spec stubs (d3d9 @ stub exports, streaming_buffer, vkd3d)
    echo "  CC wine_spec_stubs.c"
    $CC "${CFLAGS_LIST[@]}" -c -o "$obj_dir/_wine_spec_stubs.o" "$SCRIPT_DIR/docker/wine_spec_stubs.c" 2>/dev/null || true

    # Compile heap_compat: CRT functions via kernel32 HeapAlloc/HeapFree (no msvcrt)
    echo "  CC heap_compat.c"
    $CC "${CFLAGS_LIST[@]}" -c -o "$obj_dir/_heap_compat.o" "$SCRIPT_DIR/docker/heap_compat.c" 2>/dev/null || true

    # Compile mingw_matherr_stubs: no-op stubs for MinGW internal math symbols
    echo "  CC mingw_matherr_stubs.c"
    $CC "${CFLAGS_LIST[@]}" -c -o "$obj_dir/_mingw_matherr_stubs.o" "$SCRIPT_DIR/docker/mingw_matherr_stubs.c" 2>/dev/null || true
}

# ── Link wined3d.dll ───────────────────────────────────────────────
link_wined3d() {
    local obj_dir="$1" output="$2" def_file="$3"
    local pt_build="$WINE9X/pthread9x/build"

    echo "  LD wined3d.dll"
    $CC -shared -nostdlib -nodefaultlibs -static-libgcc \
        -o "$output" \
        "$obj_dir"/*.o \
        "$pt_build/crtfix.o" \
        "$pt_build/memory.o" \
        "$pt_build/lockex.o" \
        "$pt_build/tryentercriticalsection.o" \
        "$obj_dir/_nocrt_entry.o" \
        "$obj_dir/_mingw_matherr_stubs.o" \
        -lkernel32 -luser32 -lgdi32 -ladvapi32 -lopengl32 -lmsvcrt -lmingwex -lgcc \
        -Wl,--allow-multiple-definition \
        -Wl,--file-alignment,0x1000 \
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

    local extra_libs="-lkernel32 -lgcc"
    if [ "$dll_name" = "d3d9" ]; then
        extra_libs="-lkernel32 -luser32 -lgcc"
    fi

    echo "  LD $dll_name.dll"
    $CC -shared -nostdlib -nodefaultlibs -static-libgcc \
        -o "$output" \
        "$obj_dir"/*.o \
        "$pt_build/crtfix.o" \
        "$pt_build/memory.o" \
        "$pt_build/lockex.o" \
        "$pt_build/tryentercriticalsection.o" \
        "$obj_dir/_heap_compat.o" \
        "$obj_dir/_nocrt_entry.o" \
        -L"$wined3d_dir" -lwined3d -lgdi32 \
        $extra_libs \
        -Wl,--allow-multiple-definition \
        -Wl,--file-alignment,0x1000 \
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
    $CC -shared -nostdlib -nodefaultlibs -static-libgcc \
        -o "$output" \
        "$obj_dir"/*.o \
        "$pt_build/crtfix.o" \
        "$pt_build/memory.o" \
        "$pt_build/lockex.o" \
        "$pt_build/tryentercriticalsection.o" \
        "$obj_dir/_heap_compat.o" \
        "$obj_dir/_nocrt_entry.o" \
        -L"$wined3d_dir" -lwined3d -lgdi32 \
        -lkernel32 -luser32 -ladvapi32 -lgcc \
        -Wl,--allow-multiple-definition \
        -Wl,--file-alignment,0x1000 \
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

    # Add ddraw flip behavior define based on Wine version:
    # ≤3.x: DDRAW_FLIP_CALL_FPSLIMIT (reference imports flip_fpslimit from ddraw)
    # 4.x-5.x: no define (reference imports neither flip_fpslimit nor surface_ddheap)
    # ≥6.x: DDRAW_FLIP_CALL_SURFACE_DDHEAP (reference imports surface_ddheap instead)
    local vmaj=$(echo "$version" | cut -d. -f1)
    if [ "$vmaj" -lt 4 ]; then
        CFLAGS_LIST+=("-DDDRAW_FLIP_CALL_FPSLIMIT")
    elif [ "$vmaj" -ge 6 ]; then
        CFLAGS_LIST+=("-DDDRAW_FLIP_CALL_SURFACE_DDHEAP")
    fi

    # ── Patch wined3d_gl.h: add wglext.h include + WINE GL externs ──
    if [ -f "$wine_src/dlls/wined3d/wined3d_gl.h" ]; then
        perl -pi -e 's|#include "wine/wgl\.h"|#include "wine/wgl.h"\n#include "wine/wglext.h"\n\nextern void (WINE_GLAPI *glDisableWINE)(GLenum cap) DECLSPEC_HIDDEN;\nextern void (WINE_GLAPI *glEnableWINE)(GLenum cap) DECLSPEC_HIDDEN;\n|' "$wine_src/dlls/wined3d/wined3d_gl.h" 2>/dev/null || true
    fi

    # ── Copy extra source files into Wine tree ──
    cp "$SCRIPT_DIR/docker/d3dkmt_stubs.c" "$wine_src/dlls/wined3d/d3dkmt_stubs.c" 2>/dev/null || true
    cp "$SCRIPT_DIR/qemu3dfx_hooks.c" "$wine_src/dlls/wined3d/qemu3dfx_hooks.c" 2>/dev/null || true
    cp "$SCRIPT_DIR/qemu3dfx_ddraw_hooks.c" "$wine_src/dlls/ddraw/qemu3dfx_ddraw_hooks.c" 2>/dev/null || true
    cp "$SCRIPT_DIR/qemu3dfx_ddraw_passthrough.c" "$wine_src/dlls/ddraw/qemu3dfx_ddraw_passthrough.c" 2>/dev/null || true

    # ── W→A display/version/monitor API patches (W versions not on Win98) ──
    # Apply to ALL wined3d .c files, not just directx.c
    find "$wine_src/dlls/wined3d" -name "*.c" -exec sed -i \
        's/GetVersionExW/GetVersionExA/g; s/OSVERSIONINFOW/OSVERSIONINFOA/g; s/ChangeDisplaySettingsExW/ChangeDisplaySettingsExA/g; s/EnumDisplayDevicesW/EnumDisplayDevicesA/g; s/DISPLAY_DEVICEW/DISPLAY_DEVICEA/g; s/EnumDisplaySettingsExW/EnumDisplaySettingsExA/g; s/EnumDisplaySettingsW/EnumDisplaySettingsA/g; s/\bDEVMODEW\b/DEVMODEA/g; s/GetMonitorInfoW/GetMonitorInfoA/g; s/MONITORINFOEXW/MONITORINFOEXA/g; s/\bCreateDCW\b/CreateDCA/g' {} +

    # W→A string/event API patches (Win98 has no lstrcmpiW/lstrcpyW/CreateEventW)
    find "$wine_src/dlls/wined3d" -name "*.c" -exec sed -i \
        's/\blstrcmpiW\b/lstrcmpiA/g; s/\blstrcpyW\b/lstrcpyA/g; s/\bCreateEventW\b/CreateEventA/g' {} +

    # ── RtlIsCriticalSectionLockedByThread redirect (3.0.5+) ──
    if [ -f "$wine_src/dlls/wined3d/cs.c" ]; then
        sed -i 's/!RtlIsCriticalSectionLockedByThread(NtCurrentTeb()->Peb->LoaderLock)/1/' "$wine_src/dlls/wined3d/cs.c"
    fi

    # ── Patch ddraw source for qemu-3dfx hooks ──
    if [ -f "$wine_src/dlls/ddraw/main.c" ]; then
        sed -i 's/^BOOL WINAPI DllMain/extern void qemu3dfx_ddraw_passthrough_init(void);\n\nBOOL WINAPI DllMain/' "$wine_src/dlls/ddraw/main.c"
        sed -i 's/DisableThreadLibraryCalls(inst);/DisableThreadLibraryCalls(inst);\n        qemu3dfx_ddraw_passthrough_init();/' "$wine_src/dlls/ddraw/main.c"
        # Copy Wine's exception.h and fix Prev→prev (MinGW-w64 uses Next, Wine uses Prev)
        if [ -f "$wine_src/include/wine/exception.h" ]; then
            cp "$wine_src/include/wine/exception.h" "$WINE9X/include/wine/exception.h"
            sed -i 's/frame->Prev/frame->prev/g; s/(frame->Prev)/(frame->prev)/g' "$WINE9X/include/wine/exception.h"
        fi
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

    patch_pe_win98 "$outdir"

    # Strip @N stdcall import decorations (Win98 PE loader needs undecorated names)
    echo "  Stripping import decorations"
    python3 "$SCRIPT_DIR/docker/strip_import_decorations.py" "$outdir" 2>/dev/null || true

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

    # Build pthread9x minimal if needed
    if [ ! -f "$WINE9X/pthread9x/build/crtfix.o" ]; then
        build_pthread9x
    fi

    # Patch debug.c: remove GetCurrentThreadId from debug output
    sed -i 's/debug_classes\[cls\], GetCurrentThreadId(), channel->name, func/debug_classes[cls], 0, channel->name, func/' "$WINE9X/compact/debug.c"
    # Patch debug.c: exit(1) → ExitProcess(1) to avoid importing exit from msvcrt
    sed -i 's/\bexit(1)/ExitProcess(1)/g' "$WINE9X/compact/debug.c"

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
