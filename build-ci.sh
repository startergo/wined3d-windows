#!/bin/bash
# Build Wine D3D DLLs natively on Windows (MSYS2/MinGW-w64).
# Suitable for GitHub Actions CI and local builds.
#
# Usage (MSYS2 mingw32 shell):
#   bash build-ci.sh
#   bash build-ci.sh --force            # rebuild all versions
#   bash build-ci.sh --versions 8.0.2   # build specific versions only
#
# Output goes to ./output/<version>/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_BASE="$SCRIPT_DIR/output"

# version:branch:ext:msvcrt:mode
# Wine 1.x–7.x use the legacy winegcc build path on MSYS2.
# Wine 8.x uses the modern PE build system (full configure + make).
VERSIONS=(
    "1.8.7:1.8:tar.bz2:0:legacy"
    "1.9.7:1.9:tar.bz2:0:legacy"
    "2.0.5:2.0:tar.xz:0:legacy"
    "3.0.5:3.0:tar.xz:0:legacy"
    "4.12.1:4.x:tar.xz:0:legacy"
    "5.0.5:5.0:tar.xz:0:legacy"
    "6.0.4:6.0:tar.xz:1:legacy"
    "7.0.2:7.0:tar.xz:0:legacy"
    "8.0.2:8.0:tar.xz:0:modern"
)

# ── Parse arguments ─────────────────────────────────────────────────
FORCE=0
FILTER_VERSIONS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)   FORCE=1; shift ;;
        --versions)
            shift
            while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
                FILTER_VERSIONS+=("$1")
                shift
            done
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

NPROC="$(nproc 2>/dev/null || echo 2)"

# ── Download Wine source ────────────────────────────────────────────
download_wine() {
    local version=$1 branch=$2 ext=$3 srcdir=$4
    local url="https://dl.winehq.org/wine/source/${branch}/wine-${version}.${ext}"
    local tarball="$srcdir/wine-${version}.${ext}"

    if [[ -f "$tarball" ]]; then
        echo "    Using cached tarball"
        return
    fi

    echo "    Downloading Wine $version..."
    mkdir -p "$srcdir"
    curl -fSL -o "$tarball" "$url"
}

extract_wine() {
    local version=$1 ext=$2 srcdir=$3
    local tarball="$srcdir/wine-${version}.${ext}"

    if [[ -d "$srcdir/wine-${version}" ]]; then
        echo "    Using extracted source"
        return
    fi

    echo "    Extracting Wine $version..."
    tar xf "$tarball" -C "$srcdir"
}

# ── Patch MinGW archives to redirect UCRT symbols to msvcrt ─────────
patch_mingw_archives() {
    echo "    Patching MinGW runtime archives for msvcrt compatibility..."
    local curdir="$(pwd)"

    # Symbols to strip from runtime archives (libgcc, libmingwex) so the
    # linker resolves them from libmsvcrt.a (import thunks → msvcrt.dll).
    # The reference DLLs import memcpy/memset/strlen etc. from msvcrt.dll.
    local crt_syms=()
    for sym in \
        memcpy memset memmove memcmp memchr \
        strlen strcpy strcat strcmp strncmp \
        strchr strrchr strstr strcspn strnlen \
        atoi atol abs strtol strtoul \
        copysign copysignf floor floorf ceil fabs fabsf \
        sqrt sin cos tan atan atan2 exp log pow modf ldexp \
        rand srand abort \
        fprintf vfprintf sprintf sscanf; do
        crt_syms+=(--strip-symbol "_${sym}" --strip-symbol "__imp__${sym}")
    done

    # Also strip copysignf/floorf from libmsvcrt.a (float versions not in
    # Win98 msvcrt.dll — our inject stubs wrap the double versions instead).
    local msvcrt_strip=()
    for sym in copysignf floorf; do
        msvcrt_strip+=(--strip-symbol "_${sym}" --strip-symbol "__imp__${sym}")
    done

    # Use ar x / per-object objcopy / ar cr approach — objcopy on whole
    # archives silently fails on MSYS2 for some archive types.
    local all_archives=()
    for a in /mingw32/lib/libmingwex.a \
             /mingw32/lib/gcc/i686-w64-mingw32/*/libgcc.a \
             /mingw32/lib/gcc/i686-w64-mingw32/*/libgcc_eh.a; do
        [ -f "$a" ] && all_archives+=("$a")
    done

    for archive in "${all_archives[@]}"; do
        local tmpdir="${TMPDIR:-/tmp}/objcopy_$$_$(basename "$archive")_$(date +%s)"
        mkdir -p "$tmpdir"
        cd "$tmpdir"
        ar x "$archive" || { cd "$curdir"; rm -rf "$tmpdir"; continue; }
        local count=0
        for obj in *.o; do
            [ -f "$obj" ] || continue
            objcopy "${crt_syms[@]}" "$obj" 2>/dev/null || true
            objcopy --redefine-sym ___acrt_iob_func=___iob_func "$obj" 2>/dev/null || true
            count=$((count + 1))
        done
        rm -f "$archive"
        first=1
        for obj in *.o; do
            [ -f "$obj" ] || continue
            if [ "$first" = 1 ]; then ar cr "$archive" "$obj"; first=0; else ar q "$archive" "$obj"; fi
        done
        echo "    Patched $(basename "$archive") ($count objects)"
        rm -rf "$tmpdir"
        cd "$curdir"
    done

    # Patch libmsvcrt.a: only strip copysignf/floorf, keep other CRT imports.
    # Use direct objcopy on the whole archive (works for this archive, unlike
    # libgcc/libmingwex). Avoids ar x/ar q loop which is too slow with 600+ objects.
    local msvcrt_archive=/mingw32/lib/libmsvcrt.a
    if [ -f "$msvcrt_archive" ]; then
        local tmp="${TMPDIR:-/tmp}/msvcrt_$$_$(date +%s).a"
        if objcopy "${msvcrt_strip[@]}" "$msvcrt_archive" "$tmp" 2>/dev/null && [ -f "$tmp" ]; then
            mv "$tmp" "$msvcrt_archive"
            echo "    Stripped copysignf/floorf from libmsvcrt.a"
        else
            rm -f "$tmp"
            echo "    (libmsvcrt.a copysignf/floorf strip failed)"
        fi
    fi
}

# ── Create ucrtcompat stubs and inject into libmsvcrt.a ─────────────
# libmingw32.a/libmingwex.a reference __acrt_iob_func and __stdio_common_*
# which are UCRT symbols not in msvcrt.dll. Add stub implementations to
# libmsvcrt.a — since __iob_func and _vsnprintf are already archive members
# there, the linker resolves everything from msvcrt.dll with no ucrtbase dep.
# Do NOT inject via wrapper (Wine 8.x builds its own dlls/ucrtbase PE with
# the same symbols → multiple-definition errors if we also inject externally).
create_ucrtcompat() {
    echo "    Creating ucrtcompat stubs..."
    local tmpdir="${TMPDIR:-/tmp}"
    cat > "$tmpdir/ucrtcompat.c" << 'UCRTEOF'
/* No includes - avoid header conflicts */
typedef unsigned long long _u64;
typedef unsigned int _uint;
typedef unsigned int _size;
typedef void *_locale;
typedef char _va_list_tag[4];
typedef void FILE;
typedef unsigned short wchar_t;
FILE * __cdecl __iob_func(void);
int __cdecl _vsnprintf(char*,_size,const char*,...);
int __cdecl _vsnwprintf(wchar_t*,_size,const wchar_t*,...);
int __cdecl __stdio_common_vsprintf(_u64 o,char *b,_size n,const char *f,_locale l,_va_list_tag *a){ return _vsnprintf(b,n==((_size)-1)?0x7fffffff:n,f,*(void**)a); }
int __cdecl __stdio_common_vsprintf_s(_u64 o,char *b,_size n,const char *f,_locale l,_va_list_tag *a){ return _vsnprintf(b,n,f,*(void**)a); }
int __cdecl __stdio_common_vsprintf_p(_u64 o,char *b,_size n,const char *f,_locale l,_va_list_tag *a){ return _vsnprintf(b,n,f,*(void**)a); }
int __cdecl __stdio_common_vsnprintf_s(_u64 o,char *b,_size n,_size c,const char *f,_locale l,_va_list_tag *a){ return _vsnprintf(b,c<n?c:n,f,*(void**)a); }
int __cdecl __stdio_common_vfprintf(_u64 o,FILE *p,const char *f,_locale l,_va_list_tag *a){ return 0; }
int __cdecl __stdio_common_vfprintf_s(_u64 o,FILE *p,const char *f,_locale l,_va_list_tag *a){ return 0; }
int __cdecl __stdio_common_vfscanf(_u64 o,FILE *p,const char *f,_locale l,_va_list_tag *a){ return -1; }
int __cdecl __stdio_common_vsscanf(_u64 o,const char *s,_size n,const char *f,_locale l,_va_list_tag *a){ return -1; }
int __cdecl __stdio_common_vswprintf(_u64 o,wchar_t *b,_size n,const wchar_t *f,_locale l,_va_list_tag *a){ return _vsnwprintf(b,n==((_size)-1)?0x7fffffff:n,f,*(void**)a); }
int __cdecl __stdio_common_vswprintf_s(_u64 o,wchar_t *b,_size n,const wchar_t *f,_locale l,_va_list_tag *a){ return _vsnwprintf(b,n,f,*(void**)a); }
int __cdecl __stdio_common_vswprintf_p(_u64 o,wchar_t *b,_size n,const wchar_t *f,_locale l,_va_list_tag *a){ return _vsnwprintf(b,n,f,*(void**)a); }
int __cdecl __stdio_common_vsnwprintf_s(_u64 o,wchar_t *b,_size n,_size c,const wchar_t *f,_locale l,_va_list_tag *a){ return _vsnwprintf(b,c<n?c:n,f,*(void**)a); }
int __cdecl __stdio_common_vfwprintf(_u64 o,FILE *p,const wchar_t *f,_locale l,_va_list_tag *a){ return 0; }
int __cdecl __stdio_common_vfwprintf_s(_u64 o,FILE *p,const wchar_t *f,_locale l,_va_list_tag *a){ return 0; }
/* __imp__ pointers for UCRT stdio functions. debug.c sprintf/snprintf expand to
   __stdio_common_vsprintf via __declspec(dllimport), generating __imp__ references.
   Must live here (with the function bodies) so both resolve from the same .o. */
__asm__("\n"
    ".globl __imp____stdio_common_vsprintf\n"
    ".section .rdata,\"dr\"\n"
    ".align 4\n"
    "__imp____stdio_common_vsprintf:\n"
    "    .long ___stdio_common_vsprintf\n"
    ".globl __imp____stdio_common_vfprintf\n"
    ".align 4\n"
    "__imp____stdio_common_vfprintf:\n"
    "    .long ___stdio_common_vfprintf\n"
    ".globl __imp____stdio_common_vsscanf\n"
    ".align 4\n"
    "__imp____stdio_common_vsscanf:\n"
    "    .long ___stdio_common_vsscanf\n"
    ".text\n"
);
    /* Provide _vsnprintf + __imp___vsnprintf for libwinecrt0.a (debug.c).
       crt-git 12.0 doesn't include _vsnprintf in libmsvcrt.a, so provide both
       the function body and the __imp__ pointer. Using a no-op implementation
       since debug.c only uses it for trace formatting (non-critical). */
    int __cdecl _vsnprintf(char *s, unsigned int n, const char *f, ...) {
        if (s && n > 0) s[0] = 0;
        return 0;
    }
    __asm__("\n"
        ".globl __imp___vsnprintf\n"
        ".section .rdata,\"dr\"\n"
        ".align 4\n"
        "__imp___vsnprintf:\n"
        "    .long __vsnprintf\n"
        ".text\n"
    );
UCRTEOF
    gcc -nostdinc -c -O2 -Wno-attributes -o "$tmpdir/ucrtcompat.o" "$tmpdir/ucrtcompat.c"
    ar rs /mingw32/lib/libmsvcrt.a "$tmpdir/ucrtcompat.o"

    # Separate __imp__IsBadStringPtrW@8 in its own .o so the linker can pull
    # it in specifically when d3d9/d3d8 reference it (without needing other
    # ucrtcompat symbols to trigger archive member selection).
    cat > "$tmpdir/ibspw_compat.c" << 'IBSPEOF'
/* IsBadStringPtrW@8 is a Win2K+ kernel32 function not available on Win98.
   Provide __imp__ alias that redirects to IsBadStringPtrA@8 (which Win98 has).
   The parameter types differ (LPCWSTR vs LPCSTR) but at the ABI level both are
   just pointers, and IsBadStringPtrA will still catch invalid pointers. */
__asm__("\n"
    ".globl __imp__IsBadStringPtrW@8\n"
    ".section .rdata,\"dr\"\n"
    ".align 4\n"
    "__imp__IsBadStringPtrW@8:\n"
    "    .long _IsBadStringPtrA@8\n"
    ".text\n"
);
IBSPEOF
    gcc -nostdinc -c -O2 -Wno-attributes -o "$tmpdir/ibspw_compat.o" "$tmpdir/ibspw_compat.c"
    ar rs /mingw32/lib/libmsvcrt.a "$tmpdir/ibspw_compat.o"
    # Also inject into libkernel32.a so the linker finds __imp__IsBadStringPtrW@8
    # when searching kernel32 imports (IsBadStringPtrW was stripped from the spec).
    for k32lib in /mingw32/lib/libkernel32.a /mingw32/i686-w64-mingw32/lib/libkernel32.a; do
        [ -f "$k32lib" ] && ar rs "$k32lib" "$tmpdir/ibspw_compat.o"
    done

    # Inject CRT compat stubs into libgcc.a for functions not in Win98's msvcrt.dll.
    # _copysignf → wraps _copysign (double, which Win98 has).
    # floor + floorf → local impl prevents ntdll.dll floor import on MSYS2.
    cat > "$tmpdir/crt_compat.c" << 'CRTCEOF'
double __cdecl _copysign(double x, double y);
float __cdecl copysignf(float x, float y){ return (float)_copysign((double)x,(double)y); }
float __cdecl _copysignf(float x, float y){ return (float)_copysign((double)x,(double)y); }
double __cdecl floor(double x){ long long i=(long long)x; double d=(double)i; return d>x?d-1.0:d; }
float __cdecl floorf(float x){ return (float)floor((double)x); }
CRTCEOF
    gcc -nostdinc -c -O2 -Wno-attributes -o "$tmpdir/crt_compat.o" "$tmpdir/crt_compat.c"
    for gcc_lib in /mingw32/lib/gcc/i686-w64-mingw32/*/libgcc.a; do
        [ -f "$gcc_lib" ] && ar rs "$gcc_lib" "$tmpdir/crt_compat.o"
    done
}

# ── D3DKMT stubs (Vista+ API compatibility) ─────────────────────────
# D3DKMT functions (D3DKMTCloseAdapter etc.) are only in Vista+ gdi32.dll.
# Provide stubs that return failure so wined3d doesn't statically import them.
# This allows the DLL to load on XP/2000. wined3d gracefully falls back.
create_d3dkmt_stubs() {
    [ -f dlls/wined3d/Makefile.in ] || return 0
    echo "    Creating D3DKMT stubs for XP/2000 compatibility..."
    cat > dlls/wined3d/d3dkmt_stubs.c << 'D3DKMTEOF'
/* Stub D3DKMT functions — prevent static imports from gdi32.dll.
   These APIs only exist on Vista+. Returning failure causes wined3d
   to fall back to non-D3DKMT code paths (same as running on XP). */
typedef int NTSTATUS;
#define STATUS_UNSUCCESSFUL ((NTSTATUS)0xC0000001L)
#ifndef __stdcall
#define __stdcall __attribute__((stdcall))
#endif
NTSTATUS __stdcall D3DKMTCloseAdapter(const void *a){return STATUS_UNSUCCESSFUL;}
NTSTATUS __stdcall D3DKMTCreateDCFromMemory(void *a){return STATUS_UNSUCCESSFUL;}
NTSTATUS __stdcall D3DKMTCreateDevice(void *a){return STATUS_UNSUCCESSFUL;}
NTSTATUS __stdcall D3DKMTDestroyDCFromMemory(void *a){return STATUS_UNSUCCESSFUL;}
NTSTATUS __stdcall D3DKMTDestroyDevice(void *a){return STATUS_UNSUCCESSFUL;}
NTSTATUS __stdcall D3DKMTOpenAdapterFromGdiDisplayName(void *a){return STATUS_UNSUCCESSFUL;}
NTSTATUS __stdcall D3DKMTOpenAdapterFromLuid(void *a){return STATUS_UNSUCCESSFUL;}
NTSTATUS __stdcall D3DKMTQueryVideoMemoryInfo(void *a){return STATUS_UNSUCCESSFUL;}
NTSTATUS __stdcall D3DKMTSetVidPnSourceOwner(const void *a){return STATUS_UNSUCCESSFUL;}
D3DKMTEOF
    grep -q 'd3dkmt_stubs.c' dlls/wined3d/Makefile.in || \
        sed -i 's/^C_SRCS\s*=/C_SRCS = d3dkmt_stubs.c /' dlls/wined3d/Makefile.in

    # qemu-3dfx passthrough hooks — inject into wined3d for HAL enumeration
    # and passthrough device detection (\\.\QEMUchs).
    if [ -f "$SCRIPT_DIR/qemu3dfx_hooks.c" ]; then
        echo "    Injecting qemu-3dfx passthrough hooks..."
        cp "$SCRIPT_DIR/qemu3dfx_hooks.c" dlls/wined3d/qemu3dfx_hooks.c
        grep -q 'qemu3dfx_hooks.c' dlls/wined3d/Makefile.in || \
            sed -i 's/^C_SRCS\s*=/C_SRCS = qemu3dfx_hooks.c /' dlls/wined3d/Makefile.in
        # Add exports to spec file (idempotent — skip if already present)
        if [ -f dlls/wined3d/wined3d.spec ] && \
           ! grep -q 'wined3d_hal_3dfx' dlls/wined3d/wined3d.spec; then
            cat >> dlls/wined3d/wined3d.spec << 'SPECEOF'

# qemu-3dfx passthrough hooks
@ stdcall wined3d_hal_3dfx()
@ stdcall wined3d_enum_hal_last()
@ stdcall wined3d_surface_ddheap()
@ stdcall wined3d_passthru(ptr)
@ stdcall wined3d_override_cooplevel(ptr)
@ stdcall wined3d_override_rendertarget_view(ptr)
@ stdcall wined3d_blit_fpslimit()
@ stdcall wined3d_flip_fpslimit()
@ stdcall wined3d_get_gamma_ramp_3dfx(ptr ptr)
@ stdcall wined3d_set_gamma_ramp_3dfx(ptr ptr)
@ stdcall wined3d_set_cursor_3dfx(ptr ptr)
SPECEOF
        fi
    fi
}

# ── qemu-3dfx ddraw HAL stubs ────────────────────────────────────────
# ── Strip GetModuleHandleExW from kernel32 ──────────────────────────
# GetModuleHandleExW is Vista+ only. wined3d uses it via __declspec(dllimport).
# Our d3dkmt_stubs.c provides a Win98-compatible stub. The --exclude-symbols
# linker flag prevents the stub from being exported. We also strip from
# kernel32.spec so Wine never generates import thunks for it.
strip_kernel32_vista_imports() {
    # Remove Vista+/Win2000+ APIs from spec files so Wine never generates
    # import thunks for them. Our kernel32_compat.c provides local stubs.
    for spec in dlls/kernel32/kernel32.spec dlls/ntdll/ntdll.spec; do
        [ -f "$spec" ] || continue
        sed -i -e '/GetModuleHandleExW/d' \
               -e '/GlobalMemoryStatusEx/d' \
               -e '/RtlIsCriticalSectionLockedByThread/d' \
               -e '/InitOnceBeginInitialize/d' \
               -e '/InitOnceComplete/d' \
               -e '/InitOnceExecuteOnce/d' \
               -e '/InitOnceInitialize/d' \
               -e '/InitializeSRWLock/d' \
               -e '/AcquireSRWLockExclusive/d' \
               -e '/AcquireSRWLockShared/d' \
               -e '/ReleaseSRWLockExclusive/d' \
               -e '/ReleaseSRWLockShared/d' \
               -e '/TryAcquireSRWLockExclusive/d' \
               -e '/TryAcquireSRWLockShared/d' \
               -e '/InitializeConditionVariable/d' \
               -e '/WakeConditionVariable/d' \
               -e '/WakeAllConditionVariable/d' \
               -e '/SleepConditionVariableCS/d' \
               -e '/SleepConditionVariableSRW/d' \
               -e '/GetTickCount64/d' \
               -e '/IsBadStringPtrW/d' \
               -e '/FreeLibraryAndExitThread/d' \
               -e '/_snprintf/d' \
               -e '/_strnicmp/d' \
               -e '/_vsnprintf/d' \
	               "$spec"
    done
    # Also strip ntdll CRT functions (available from msvcrt on Win98).
    # ntdll-only strip — kernel32 doesn't have these.
    for spec in dlls/ntdll/ntdll.spec; do
        [ -f "$spec" ] || continue
        sed -i -e '/_stricmp/d' \
               -e '/^@.*\bsprintf\b/d' \
               -e '/^@.*\bvsprintf\b/d' \
               -e '/^@.*\bvsnprintf\b/d' \
               -e '/^@.*\bsnprintf\b/d' \
               -e '/^@.*\bsscanf/d' \
               -e '/^@.*\bmemcpy\b/d' \
               -e '/^@.*\bmemset\b/d' \
               -e '/^@.*\bmemmove\b/d' \
               -e '/^@.*\bmemcmp\b/d' \
               -e '/^@.*\bmemchr\b/d' \
               -e '/^@.*\bstrlen\b/d' \
               -e '/^@.*\bstrcpy\b/d' \
               -e '/^@.*\bstrcat\b/d' \
               -e '/^@.*\bstrcmp\b/d' \
               -e '/^@.*\bstrncmp\b/d' \
               -e '/^@.*\bstrchr\b/d' \
               -e '/^@.*\bstrstr\b/d' \
               -e '/^@.*\bstrrchr\b/d' \
               -e '/^@.*\btolower\b/d' \
               -e '/^@.*\btoupper\b/d' \
               -e '/^@.*\batoi\b/d' \
               -e '/^@.*\batol\b/d' \
               -e '/^@.*\bstrtol\b/d' \
               -e '/^@.*\bqsort\b/d' \
               -e '/^@.*\bbsearch\b/d' \
               -e '/^@.*\bisprint\b/d' \
               -e '/^@.*\bisdigit\b/d' \
               -e '/^@.*\bisalpha\b/d' \
               -e '/^@.*\bisalnum\b/d' \
               -e '/^@.*\bisspace\b/d' \
               -e '/^@.*\bisupper\b/d' \
               -e '/^@.*\bislower\b/d' \
               -e '/^@.*\bisxdigit\b/d' \
               -e '/^@.*\biscntrl\b/d' \
               -e '/^@.*\bisgraph\b/d' \
               -e '/^@.*\bispunct\b/d' \
               -e '/^@.*\babs\b/d' \
               -e '/^@.*\bpow\b/d' \
               -e '/^@.*\bexp\b/d' \
               -e '/^@.*\blog\b/d' \
               -e '/^@.*\bvsprintf\b/d' \
               -e '/^@.*\bstrcspn\b/d' \
               -e '/^@.*\bstrnlen\b/d' \
               -e '/^@.*\bstrtoul\b/d' \
               -e '/^@.*\bfprintf\b/d' \
               -e '/^@.*\bgetc\b/d' \
               -e '/^@.*\bungetc\b/d' \
               -e '/^@.*\bsin\b/d' -e '/^@.*\btan\b/d' -e '/^@.*\batan\b/d' \
               -e '/^@.*\bsqrt\b/d' -e '/^@.*\bceil\b/d' -e '/^@.*\bfloor\b/d' \
               "$spec"
    done
    echo "    Stripped Vista+ APIs and CRT from kernel32/ntdll specs"

    # Strip SetThreadDescription from kernel32.spec (Windows 10+)
    for spec in dlls/kernel32/kernel32.spec; do
        [ -f "$spec" ] || continue
        sed -i -e '/SetThreadDescription/d' "$spec"
    done

    # Strip Win2000+ user32 display W-version functions from user32.spec.
    # Win98 only has the A-versions. Our kernel32_compat.c provides W→A wrappers.
    for spec in dlls/user32/user32.spec; do
        [ -f "$spec" ] || continue
        sed -i -e '/EnumDisplayDevicesW/d' \
               -e '/EnumDisplaySettingsExW/d' \
               -e '/EnumDisplaySettingsW/d' \
               -e '/EnumDisplayMonitors/d' \
               -e '/MonitorFromPoint/d' \
               -e '/ChangeDisplaySettingsExW/d' \
               "$spec"
    done
    echo "    Stripped Vista+/Win2000+ APIs and CRT from kernel32/ntdll/user32 specs"

    # Strip from system MinGW import libs (objcopy on archive, no ARG_MAX)
    local strip_syms=()
    for api in \
        GetModuleHandleExW@12 GlobalMemoryStatusEx@4 \
        RtlIsCriticalSectionLockedByThread@4 \
        InitOnceExecuteOnce@16 \
        InitOnceBeginInitialize@16 InitOnceComplete@12 InitOnceInitialize@4 \
        InitializeSRWLock@4 \
        AcquireSRWLockExclusive@4 AcquireSRWLockShared@4 \
        ReleaseSRWLockExclusive@4 ReleaseSRWLockShared@4 \
        TryAcquireSRWLockExclusive@4 TryAcquireSRWLockShared@4 \
        InitializeConditionVariable@4 \
        WakeConditionVariable@4 WakeAllConditionVariable@4 \
        SleepConditionVariableCS@12 SleepConditionVariableSRW@16 \
        GetTickCount64@0 \
        SetThreadDescription@8 \
        IsBadStringPtrW@8 FreeLibraryAndExitThread@8; do
        strip_syms+=(--strip-symbol "_${api}" --strip-symbol "__imp__${api}")
    done
    # Win2000+ user32 display functions (Win98 only has A-versions)
    # Keep MonitorFromWindow@8 and GetMonitorInfoW@8 — ddraw imports them from user32.
    for api in \
        EnumDisplayDevicesW@16 EnumDisplaySettingsExW@16 \
        EnumDisplaySettingsW@12 \
        EnumDisplayMonitors@16 MonitorFromPoint@12 \
        ChangeDisplaySettingsExW@20; do
        strip_syms+=(--strip-symbol "_${api}" --strip-symbol "__imp__${api}")
    done
    # ntdll CRT functions (cdecl, no @N suffix) — resolve from msvcrt instead.
    # Must match Docker's libntdll.a strip list exactly.
    for api in _snprintf _strnicmp _vsnprintf _stricmp \
               sprintf vsprintf snprintf vsnprintf sscanf \
               memcpy memset memmove memcmp memchr \
               strlen strcpy strcat strcmp strncmp strchr strstr strrchr strcspn strnlen \
               tolower toupper strtol strtoul qsort bsearch \
               atoi atol abs \
               isprint isdigit isalpha isalnum isspace isupper islower isxdigit iscntrl isgraph ispunct \
               _vsnprintf_s \
               sin cos tan atan atan2 sqrt ceil floor \
               fprintf vfprintf \
               rand srand abort \
               fopen fclose fgets fputc fread fwrite clearerr feof ferror \
               fabs modf ldexp; do
        strip_syms+=(--strip-symbol "${api}" --strip-symbol "__imp__${api}")
    done

    for lib in /mingw32/lib/libkernel32.a \
               /mingw32/i686-w64-mingw32/lib/libkernel32.a \
               /mingw32/lib/libntdll.a \
               /mingw32/i686-w64-mingw32/lib/libntdll.a \
               /mingw32/lib/libuser32.a \
               /mingw32/i686-w64-mingw32/lib/libuser32.a; do
        [ -f "$lib" ] || continue
        local tmp="${TMPDIR:-/tmp}/strip_$$_$(date +%s).a"
        if objcopy "${strip_syms[@]}" "$lib" "$tmp" 2>/dev/null && [ -f "$tmp" ]; then
            mv "$tmp" "$lib"
            echo "    Stripped Vista+ symbols from $lib"
        else
            rm -f "$tmp"
        fi
    done

    # Strip Win98-incompatible CRT from msvcrt import libs.
    # strnlen: C11, not in Win98 msvcrt.dll.
    # _isctype: internal CRT helper, not in Win98 msvcrt.dll.
    # Our kernel32_compat.c provides local stubs instead.
    # Note: _initterm/_initterm_e are imported from msvcrt.dll (matches reference DLLs).
    local strip_crt=()
    for api in strnlen _isctype; do
        strip_crt+=(--strip-symbol "${api}" --strip-symbol "__imp__${api}")
    done
    for lib in /mingw32/lib/libmsvcrt.a \
               /mingw32/i686-w64-mingw32/lib/libmsvcrt.a; do
        [ -f "$lib" ] || continue
        local tmp="${TMPDIR:-/tmp}/strip_crt_$$_$(date +%s).a"
        if objcopy "${strip_crt[@]}" "$lib" "$tmp" 2>/dev/null && [ -f "$tmp" ]; then
            mv "$tmp" "$lib"
            echo "    Stripped strnlen/_isctype from $lib"
        else
            rm -f "$tmp"
        fi
    done
}

# Strip Vista+ symbols from Wine's OWN import libs (built by make tools).
# Wine 8 modern PE build generates dlls/kernel32/i386-windows/libkernel32.a
# and dlls/ntdll/i386-windows/libntdll.a from the built DLLs. These contain
# Vista+ exports that our kernel32_compat.c stubs. Must strip AFTER make tools
# builds them but BEFORE our DLLs are linked.
strip_kernel32_vista_imports_wine() {
    local strip_all=()
    for api in \
        GetModuleHandleExW@12 GlobalMemoryStatusEx@4 \
        RtlIsCriticalSectionLockedByThread@4 \
        InitOnceExecuteOnce@16 \
        InitOnceBeginInitialize@16 InitOnceComplete@12 InitOnceInitialize@4 \
        InitializeSRWLock@4 \
        AcquireSRWLockExclusive@4 AcquireSRWLockShared@4 \
        ReleaseSRWLockExclusive@4 ReleaseSRWLockShared@4 \
        TryAcquireSRWLockExclusive@4 TryAcquireSRWLockShared@4 \
        InitializeConditionVariable@4 \
        WakeConditionVariable@4 WakeAllConditionVariable@4 \
        SleepConditionVariableCS@12 SleepConditionVariableSRW@16 \
        GetTickCount64@0 \
        SetThreadDescription@8 \
        IsBadStringPtrW@8 FreeLibraryAndExitThread@8; do
        strip_all+=(--strip-symbol "_${api}" --strip-symbol "__imp__${api}")
    done
    # Win2000+ user32 display functions (Win98 only has A-versions)
    # Keep MonitorFromWindow@8 and GetMonitorInfoW@8 — ddraw imports them from user32.
    for api in \
        EnumDisplayDevicesW@16 EnumDisplaySettingsExW@16 \
        EnumDisplaySettingsW@12 \
        EnumDisplayMonitors@16 MonitorFromPoint@12 \
        ChangeDisplaySettingsExW@20; do
        strip_all+=(--strip-symbol "_${api}" --strip-symbol "__imp__${api}")
    done
    # CRT we stub locally — strip from ALL Wine import libs including ntdll.
    # _copysignf: Win98 msvcrt only has _copysign (double), not float version.
    # __acrt_iob_func: UCRT function not in Win98 msvcrt.
    # Note: _initterm/_initterm_e are imported from msvcrt.dll (matches reference DLLs).
    # Note: _snprintf/_strnicmp/floor are in Win98 msvcrt — let them be imported
    # from msvcrt.dll. Strip from ntdll only (ntdll-specific section below).
    # Note: _vsnprintf is a real msvcrt.dll function — strip from kernel32/ntdll
    # only (separate loop below), NOT from msvcrt where it's needed as import.
    for api in _copysignf \
               __acrt_iob_func; do
        strip_all+=(--strip-symbol "${api}" --strip-symbol "__imp__${api}")
    done
    # UCRT stdio helpers (not in Win98 msvcrt.dll) — strip from msvcrt so local
    # kernel32_compat.c definitions take priority over import lib thunks.
    for api in __stdio_common_vsprintf __stdio_common_vsprintf_s \
               __stdio_common_vsprintf_p __stdio_common_vsnprintf_s \
               __stdio_common_vfprintf __stdio_common_vfprintf_s \
               __stdio_common_vfscanf __stdio_common_vsscanf; do
        strip_all+=(--strip-symbol "${api}" --strip-symbol "__imp__${api}")
    done
    # Vista+ APIs + stub CRT: strip from all libs (kernel32, ntdll, ucrtbase, msvcrt)
    for lib in \
        dlls/kernel32/i386-windows/libkernel32.a \
        dlls/kernel32/libkernel32.a \
        dlls/ntdll/i386-windows/libntdll.a \
        dlls/ntdll/libntdll.a \
        dlls/ucrtbase/i386-windows/libucrtbase.a \
        dlls/ucrtbase/libucrtbase.a \
        dlls/msvcrt/i386-windows/libmsvcrt.a \
        dlls/msvcrt/libmsvcrt.a \
        dlls/user32/i386-windows/libuser32.a \
        dlls/user32/libuser32.a; do
        [ -f "$lib" ] || continue
        local tmp="${TMPDIR:-/tmp}/strip_wine_$$_$(date +%s).a"
        if objcopy "${strip_all[@]}" "$lib" "$tmp" 2>/dev/null && [ -f "$tmp" ]; then
            mv "$tmp" "$lib"
            echo "    Stripped Vista+ symbols from Wine $lib"
        else
            rm -f "$tmp"
        fi
    done
    # _vsnprintf: strip from kernel32/ntdll/ucrtbase (not a kernel/ntdll function)
    # but keep in msvcrt (it IS a real msvcrt.dll function needed by libwinecrt0).
    local _vsnprintf_tmp="${TMPDIR:-/tmp}/strip_vsnprintf_$$_$(date +%s).a"
    for lib in \
        dlls/kernel32/i386-windows/libkernel32.a \
        dlls/kernel32/libkernel32.a \
        dlls/ntdll/i386-windows/libntdll.a \
        dlls/ntdll/libntdll.a \
        dlls/ucrtbase/i386-windows/libucrtbase.a \
        dlls/ucrtbase/libucrtbase.a \
        dlls/user32/i386-windows/libuser32.a \
        dlls/user32/libuser32.a; do
        [ -f "$lib" ] || continue
        if objcopy --strip-symbol=_vsnprintf --strip-symbol=__imp___vsnprintf "$lib" "$_vsnprintf_tmp" 2>/dev/null && [ -f "$_vsnprintf_tmp" ]; then
            mv "$_vsnprintf_tmp" "$lib"
        else
            rm -f "$_vsnprintf_tmp"
        fi
    done
    # Basic CRT: strip from ntdll only — these are available from msvcrt.dll
    # on Win98, so ntdll should NOT provide them. Use per-object approach
    # because objcopy on whole Wine archives silently fails on MSYS2.
    local strip_ntdll_crt=()
    for api in _stricmp _strnicmp \
               sprintf vsprintf snprintf vsnprintf sscanf \
               fprintf vfprintf \
               memcpy memset memmove memcmp memchr \
               strlen strcpy strcat strcmp strncmp strchr strstr strrchr strcspn strnlen \
               tolower toupper strtol strtoul qsort bsearch \
               rand srand abort \
               floor ceil fabs sqrt sin cos tan atan atan2 exp log pow modf ldexp \
               fopen fclose fgets fputc fread fwrite clearerr feof ferror; do
        strip_ntdll_crt+=(--strip-symbol "${api}" --strip-symbol "__imp__${api}")
    done
    local _ntdll_curdir="$(pwd)"
    for lib in \
        dlls/ntdll/i386-windows/libntdll.a \
        dlls/ntdll/libntdll.a; do
        [ -f "$lib" ] || continue
        local _ntdll_tmpdir="${TMPDIR:-/tmp}/strip_ntdll_$$_$(date +%s)"
        mkdir -p "$_ntdll_tmpdir"
        cd "$_ntdll_tmpdir"
        if ar x "$_ntdll_curdir/$lib" 2>/dev/null; then
            for obj in *.o; do
                [ -f "$obj" ] || continue
                objcopy "${strip_ntdll_crt[@]}" "$obj" 2>/dev/null || true
            done
            rm -f "$_ntdll_curdir/$lib"
            local _first=1
            for obj in *.o; do
                [ -f "$obj" ] || continue
                if [ "$_first" = 1 ]; then ar cr "$_ntdll_curdir/$lib" "$obj"; _first=0; else ar q "$_ntdll_curdir/$lib" "$obj"; fi
            done
            echo "    Stripped basic CRT from Wine ntdll $lib (per-object)"
        fi
        rm -rf "$_ntdll_tmpdir"
        cd "$_ntdll_curdir"
    done
    # UCRT-specific functions: strip from ucrtbase (not in msvcrt.dll on Win98).
    # kernel32_compat.c provides local no-op stubs.
    local strip_ucrt=()
    for api in __stdio_common_vsprintf __stdio_common_vsprintf_s \
               __stdio_common_vsprintf_p __stdio_common_vsnprintf_s \
               __stdio_common_vfprintf __stdio_common_vfprintf_s \
               __stdio_common_vfscanf __stdio_common_vsscanf \
               __stdio_common_vswprintf __stdio_common_vswprintf_s \
               __stdio_common_vswprintf_p __stdio_common_vsnwprintf_s \
               __stdio_common_vfwprintf __stdio_common_vfwprintf_s \
               _fdclass _dclass _dsign _fdsign \
               _fstat32; do
        strip_ucrt+=(--strip-symbol "${api}" --strip-symbol "__imp__${api}")
    done
    for lib in \
        dlls/ucrtbase/i386-windows/libucrtbase.a \
        dlls/ucrtbase/libucrtbase.a; do
        [ -f "$lib" ] || continue
        local tmp="${TMPDIR:-/tmp}/strip_ucrt_$$_$(date +%s).a"
        if objcopy "${strip_ucrt[@]}" "$lib" "$tmp" 2>/dev/null && [ -f "$tmp" ]; then
            mv "$tmp" "$lib"
            echo "    Stripped UCRT-specific symbols from Wine ucrtbase $lib"
        else
            rm -f "$tmp"
        fi
    done
}

# ── Win98 compat stubs for Vista+/Win2000+ APIs ────────────────────
# Multiple Wine DLLs use Vista+/Win2000+ APIs via __declspec(dllimport).
# Inject local stubs into each DLL so each resolves its own _imp__
# references without importing from system DLLs that lack them on Win98.
create_kernel32_compat() {
    local _build_mode="${1:-legacy}"
    for dll in wined3d ddraw d3d9 d3d8; do
        local mf="dlls/$dll/Makefile.in"
        [ -f "$mf" ] || continue
        cat > "dlls/$dll/kernel32_compat.c" << 'K32EOF'
/* Win98-compatible stubs for Vista+/Win2000+ kernel32/ntdll APIs.
   Each provides the function + __imp__ pointer for __declspec(dllimport). */
#include <string.h>
#include <stddef.h>
typedef unsigned long DWORD;
typedef unsigned long long DWORD64;
typedef unsigned short WCHAR;
typedef const WCHAR *LPCWSTR;

/* winebuild-generated entry points reference _pei386_runtime_relocator
   (MinGW CRT ASLR handler). Not needed for Wine DLLs — provide a no-op. */
void _pei386_runtime_relocator(void) {}
typedef unsigned long ULONG_PTR;
typedef void *HMODULE;
typedef int BOOL;
#ifndef __stdcall
#define __stdcall __attribute__((stdcall))
#endif

/* --- wine_k32compat_GMHEW (GetModuleHandleExW redirect) --- */
#define GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS 0x4
typedef struct { void *BaseAddress; void *AllocationBase; DWORD Partition; DWORD RegionSize; DWORD State; DWORD Protect; DWORD Type; } MBINFO;
DWORD __stdcall VirtualQuery(const void *, MBINFO *, DWORD);
BOOL __stdcall wine_k32compat_GMHEW(DWORD flags, LPCWSTR name, HMODULE *module)
{
    if(!module) return 0;
    if(flags & GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS) {
        MBINFO mbi;
        if(VirtualQuery((const void *)name, &mbi, sizeof(mbi)))
            { *module = (HMODULE)mbi.AllocationBase; return 1; }
        return 0;
    }
    /* No FROM_ADDRESS flag: return default image base.
       Avoids importing GetModuleHandleA from kernel32. */
    *module = (HMODULE)0x400000;
    return 1;
}

/* --- GlobalMemoryStatusEx (Win2000+) --- */
typedef struct { DWORD dwLength; DWORD dwMemoryLoad; DWORD64 ullTotalPhys; DWORD64 ullAvailPhys;
  DWORD64 ullTotalPageFile; DWORD64 ullAvailPageFile; DWORD64 ullTotalVirtual; DWORD64 ullAvailVirtual;
  DWORD64 ullAvailExtendedVirtual; } MEMSTATUSEX;
BOOL __stdcall GlobalMemoryStatusEx(MEMSTATUSEX *lpBuffer)
{
    int i; char *p = (char *)lpBuffer;
    for(i = 0; i < (int)sizeof(*lpBuffer); i++) p[i] = 0;
    lpBuffer->dwLength = sizeof(*lpBuffer);
    return 1;
}

/* --- RtlIsCriticalSectionLockedByThread (Vista+) --- */
typedef struct _RTL_CRITICAL_SECTION { void *DebugInfo; long LockCount; long RecursionCount; void *OwningThread; void *LockSemaphore; DWORD SpinCount; } CRITSEC;
BOOL __stdcall RtlIsCriticalSectionLockedByThread(CRITSEC *cs)
{
    /* Approximate: check RecursionCount only, skip GetCurrentThreadId to avoid
       adding a kernel32 import that reference DLLs don't have. */
    return cs && cs->RecursionCount > 0;
}

/* --- InitOnceExecuteOnce (Vista+) --- */
typedef long BOOL_CALL_ONCE(void *, void **);
BOOL __stdcall InitOnceExecuteOnce(void *init_once, BOOL_CALL_ONCE *init_fn, void *param, void **context)
{
    long *flag = (long *)init_once;
    if(*flag == 0) {
        *flag = 1;
        if(init_fn) init_fn(param, context ? context : (void **)init_once);
    }
    return 1;
}

/* --- ConditionVariable family (Vista+) --- */
/* Pure no-ops. Avoids importing EnterCriticalSection, LeaveCriticalSection, Sleep.
   Wine only uses ConditionVariable for multi-threaded CS wait; on Win98 (single-core)
   this is sufficient. If actual synchronization is needed, callers use their own CS. */
typedef struct _CONDITION_VARIABLE { void *Ptr; } CONDITION_VARIABLE;
void __stdcall InitializeConditionVariable(CONDITION_VARIABLE *cv) { if(cv) cv->Ptr = 0; }
void __stdcall WakeConditionVariable(CONDITION_VARIABLE *cv) { (void)cv; }
void __stdcall WakeAllConditionVariable(CONDITION_VARIABLE *cv) { (void)cv; }
unsigned long __stdcall SleepConditionVariableCS(CONDITION_VARIABLE *cv, void *cs, unsigned long ms)
{
    (void)cv; (void)cs; (void)ms;
    return 0;
}

/* --- SetThreadDescription (Windows 10+) --- */
typedef long HRESULT;
typedef void *HANDLE;
typedef const unsigned short *PCWSTR;
HRESULT __stdcall SetThreadDescription(HANDLE hThread, PCWSTR lpThreadDescription) { return 0; }

/* --- _copysignf (Win98 msvcrt.dll only has _copysign double) --- */
double __cdecl _copysign(double x, double y);
float __cdecl _copysignf(float x, float y) { return (float)_copysign((double)x, (double)y); }

/* --- floor + floorf (local impl prevents ntdll.dll import on MSYS2) --- */
double __cdecl floor(double x) {
    long long i = (long long)x;
    double d = (double)i;
    return d > x ? d - 1.0 : d;
}
float __cdecl floorf(float x) { return (float)floor((double)x); }

/* --- _fstat32 (UCRT, not in Win98 msvcrt.dll) --- */
int __cdecl _fstat32(int fd, void *buf) { (void)fd; (void)buf; return -1; }

/* --- strnlen (C11, not in Win98 msvcrt.dll) --- */
unsigned int __cdecl strnlen(const char *s, unsigned int maxlen) {
    unsigned int i = 0;
    while (i < maxlen && s[i]) i++;
    return i;
}

/* --- _isctype (internal CRT helper, not in Win98 msvcrt.dll) --- */
int __cdecl _isctype(int c, int mask) { (void)c; (void)mask; return 0; }

/* --- UCRT-specific floating-point classification (not in msvcrt.dll) --- */
int __cdecl _fdclass(float x) { (void)x; return 0; }
int __cdecl _dclass(double x) { (void)x; return 0; }
int __cdecl _dsign(double x) { (void)x; return 0; }
int __cdecl _fdsign(float x) { (void)x; return 0; }

/* ── Win98 user32 W-version display function wrappers ────────────────
   EnumDisplayDevicesW, EnumDisplaySettingsW, EnumDisplaySettingsExW,
   GetMonitorInfoW, EnumDisplayMonitors require Windows 2000.
   MonitorFromWindow, MonitorFromPoint also Win2000+ per MSDN.
   Named wine_k32compat_* and redirected via -D preprocessor flags.
   No __imp__ pointers needed — Wine calls these as regular functions,
   not via __declspec(dllimport). Stripping from user32.spec and
   libuser32.a ensures the linker uses our local implementations.
   Only compiled for wined3d — d3d9/d3d8/ddraw don't link user32. */
#ifdef K32COMPAT_DISPLAY_WRAPPERS

typedef struct {
    unsigned char dmDeviceName[32];
    unsigned short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
    unsigned long dmFields;
    unsigned long dmPosition_x, dmPosition_y;
    unsigned long dmDisplayOrientation, dmDisplayFixedOutput;
    unsigned short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    unsigned char dmFormName[32];
    unsigned short dmLogPixels;
    unsigned long dmBitsPerPel, dmPelsWidth, dmPelsHeight;
    unsigned long dmDisplayFlags, dmDisplayFrequency;
    unsigned long dmICMMethod, dmICMIntent, dmMediaType, dmDitherType;
    unsigned long dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
} DEVMODEA_LOCAL;

typedef struct {
    unsigned short dmDeviceName[32];
    unsigned short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
    unsigned long dmFields;
    unsigned long dmPosition_x, dmPosition_y;
    unsigned long dmDisplayOrientation, dmDisplayFixedOutput;
    unsigned short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    unsigned short dmFormName[32];
    unsigned short dmLogPixels;
    unsigned long dmBitsPerPel, dmPelsWidth, dmPelsHeight;
    unsigned long dmDisplayFlags, dmDisplayFrequency;
    unsigned long dmICMMethod, dmICMIntent, dmMediaType, dmDitherType;
    unsigned long dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
} DEVMODEW_LOCAL;

static void devmode_a_to_w(const DEVMODEA_LOCAL *a, DEVMODEW_LOCAL *w) {
    int i;
    memset(w, 0, sizeof(*w));
    for(i = 0; i < 31 && a->dmDeviceName[i]; i++) w->dmDeviceName[i] = (unsigned short)a->dmDeviceName[i];
    w->dmSpecVersion = a->dmSpecVersion; w->dmDriverVersion = a->dmDriverVersion;
    w->dmSize = sizeof(*w); w->dmDriverExtra = a->dmDriverExtra; w->dmFields = a->dmFields;
    w->dmPosition_x = a->dmPosition_x; w->dmPosition_y = a->dmPosition_y;
    w->dmDisplayOrientation = a->dmDisplayOrientation; w->dmDisplayFixedOutput = a->dmDisplayFixedOutput;
    w->dmColor = a->dmColor; w->dmDuplex = a->dmDuplex;
    w->dmYResolution = a->dmYResolution; w->dmTTOption = a->dmTTOption; w->dmCollate = a->dmCollate;
    for(i = 0; i < 31 && a->dmFormName[i]; i++) w->dmFormName[i] = (unsigned short)a->dmFormName[i];
    w->dmLogPixels = a->dmLogPixels;
    w->dmBitsPerPel = a->dmBitsPerPel; w->dmPelsWidth = a->dmPelsWidth; w->dmPelsHeight = a->dmPelsHeight;
    w->dmDisplayFlags = a->dmDisplayFlags; w->dmDisplayFrequency = a->dmDisplayFrequency;
    w->dmICMMethod = a->dmICMMethod; w->dmICMIntent = a->dmICMIntent;
    w->dmMediaType = a->dmMediaType; w->dmDitherType = a->dmDitherType;
    w->dmReserved1 = a->dmReserved1; w->dmReserved2 = a->dmReserved2;
    w->dmPanningWidth = a->dmPanningWidth; w->dmPanningHeight = a->dmPanningHeight;
}

int __stdcall EnumDisplaySettingsA(const char *, unsigned long, void *);
int __stdcall wine_k32compat_EDS_W(const unsigned short *dev, unsigned long mode, void *dm_out)
{
    DEVMODEA_LOCAL dma; int i; char devA[64] = {0};
    if(dev) { for(i=0; i<63 && dev[i]; i++) devA[i]=(char)dev[i]; }
    memset(&dma, 0, sizeof(dma)); dma.dmSize = sizeof(dma);
    if(!EnumDisplaySettingsA(dev?devA:NULL, mode, &dma)) return 0;
    devmode_a_to_w(&dma, (DEVMODEW_LOCAL*)dm_out); return 1;
}

int __stdcall EnumDisplaySettingsExA(const char *, unsigned long, void *, unsigned long);
int __stdcall wine_k32compat_EDSE_W(const unsigned short *dev, unsigned long mode, void *dm_out, unsigned long flags)
{
    DEVMODEA_LOCAL dma; int i; char devA[64] = {0};
    if(dev) { for(i=0; i<63 && dev[i]; i++) devA[i]=(char)dev[i]; }
    memset(&dma, 0, sizeof(dma)); dma.dmSize = sizeof(dma);
    if(!EnumDisplaySettingsExA(dev?devA:NULL, mode, &dma, flags)) return 0;
    devmode_a_to_w(&dma, (DEVMODEW_LOCAL*)dm_out); return 1;
}

int __stdcall EnumDisplayDevicesA(const char *, unsigned long, void *, unsigned long);
int __stdcall wine_k32compat_EDD_W(const unsigned short *dev, unsigned long idx, void *dd_out, unsigned long flags)
{
    struct { unsigned long cb; unsigned char dn[32]; unsigned char ds[128]; unsigned long sf;
             unsigned char did[128]; unsigned char dk[128]; } dda;
    int i; char devA[64] = {0};
    unsigned long sf;
    if(dev) { for(i=0; i<63 && dev[i]; i++) devA[i]=(char)dev[i]; }
    memset(&dda, 0, sizeof(dda)); dda.cb = sizeof(dda);
    if(!EnumDisplayDevicesA(dev?devA:NULL, idx, &dda, flags)) return 0;
    sf = dda.sf;
    memset(dd_out, 0, 840); *(unsigned long*)dd_out = 840;
    for(i=0; i<31 && dda.dn[i]; i++) ((unsigned short*)((char*)dd_out+4))[i] = dda.dn[i];
    for(i=0; i<127 && dda.ds[i]; i++) ((unsigned short*)((char*)dd_out+68))[i] = dda.ds[i];
    *(unsigned long*)((char*)dd_out+324) = sf;
    for(i=0; i<127 && dda.did[i]; i++) ((unsigned short*)((char*)dd_out+328))[i] = dda.did[i];
    for(i=0; i<127 && dda.dk[i]; i++) ((unsigned short*)((char*)dd_out+584))[i] = dda.dk[i];
    return 1;
}

unsigned long __stdcall GetSystemMetrics(int);
int __stdcall wine_k32compat_GMI_W(void *hmon, void *lpmi)
{
    unsigned long *mi = (unsigned long*)lpmi;
    if(!mi) return 0;
    memset(mi, 0, 40);
    mi[0] = 40; mi[3] = GetSystemMetrics(0); mi[4] = GetSystemMetrics(1);
    mi[7] = mi[3]; mi[8] = mi[4]; mi[9] = 1;
    return 1;
}

typedef int (__stdcall *MONITORENUMPROC)(void*, void*, unsigned long*, unsigned long);
int __stdcall wine_k32compat_EDM(void *hdc, const unsigned long *lprc, MONITORENUMPROC cb, unsigned long data)
{
    unsigned long rect[4];
    if(!cb) return 0;
    rect[0] = 0; rect[1] = 0; rect[2] = GetSystemMetrics(0); rect[3] = GetSystemMetrics(1);
    cb((void*)1, (void*)0, rect, data); return 1;
}

void * __stdcall wine_k32compat_MFW(void *hwnd, unsigned long flags) { return (void*)1; }
void * __stdcall wine_k32compat_MFP(unsigned long x, unsigned long y, unsigned long flags) { return (void*)1; }

/* --- ChangeDisplaySettingsExW (Win2000+, Win98 only has A version) --- */
long __stdcall ChangeDisplaySettingsExA(const char *, const void *, void *, unsigned long, void *);
static void devmode_w_to_a(const DEVMODEW_LOCAL *w, DEVMODEA_LOCAL *a) {
    int i;
    memset(a, 0, sizeof(*a));
    for(i = 0; i < 31 && w->dmDeviceName[i]; i++) a->dmDeviceName[i] = (unsigned char)w->dmDeviceName[i];
    a->dmSpecVersion = w->dmSpecVersion; a->dmDriverVersion = w->dmDriverVersion;
    a->dmSize = sizeof(*a); a->dmDriverExtra = w->dmDriverExtra; a->dmFields = w->dmFields;
    a->dmPosition_x = w->dmPosition_x; a->dmPosition_y = w->dmPosition_y;
    a->dmDisplayOrientation = w->dmDisplayOrientation; a->dmDisplayFixedOutput = w->dmDisplayFixedOutput;
    a->dmColor = w->dmColor; a->dmDuplex = w->dmDuplex;
    a->dmYResolution = w->dmYResolution; a->dmTTOption = w->dmTTOption; a->dmCollate = w->dmCollate;
    for(i = 0; i < 31 && w->dmFormName[i]; i++) a->dmFormName[i] = (unsigned char)w->dmFormName[i];
    a->dmLogPixels = w->dmLogPixels;
    a->dmBitsPerPel = w->dmBitsPerPel; a->dmPelsWidth = w->dmPelsWidth; a->dmPelsHeight = w->dmPelsHeight;
    a->dmDisplayFlags = w->dmDisplayFlags; a->dmDisplayFrequency = w->dmDisplayFrequency;
    a->dmICMMethod = w->dmICMMethod; a->dmICMIntent = w->dmICMIntent;
    a->dmMediaType = w->dmMediaType; a->dmDitherType = w->dmDitherType;
    a->dmReserved1 = w->dmReserved1; a->dmReserved2 = w->dmReserved2;
    a->dmPanningWidth = w->dmPanningWidth; a->dmPanningHeight = w->dmPanningHeight;
}
long __stdcall wine_k32compat_CDSE_W(const unsigned short *dev, const void *dm_in, void *hwnd, unsigned long flags, void *lparam)
{
    DEVMODEA_LOCAL dma; int i; char devA[64] = {0};
    if(dev) { for(i=0; i<63 && dev[i]; i++) devA[i]=(char)dev[i]; }
    if(dm_in) {
        devmode_w_to_a((const DEVMODEW_LOCAL*)dm_in, &dma);
        return ChangeDisplaySettingsExA(dev?devA:NULL, &dma, hwnd, flags, lparam);
    }
    return ChangeDisplaySettingsExA(dev?devA:NULL, NULL, hwnd, flags, lparam);
}

/* --- IsBadStringPtrW (Win2000+, Win98 only has A version) --- */
int __stdcall wine_k32compat_IBSP_W(const unsigned short *lpsz, unsigned long ucchMax)
{
    /* No-op: assume pointer is valid. Avoids importing IsBadStringPtrA. */
    (void)ucchMax;
    return lpsz ? 0 : 1;
}

/* --- FreeLibraryAndExitThread (Win2000+, not on Win98) --- */
int __stdcall FreeLibrary(void *);
void __stdcall ExitThread(unsigned long);
void __stdcall wine_k32compat_FLAET(void *hLibModule, unsigned long dwExitCode)
{
    FreeLibrary(hLibModule);
    ExitThread(dwExitCode);
}

#endif /* K32COMPAT_DISPLAY_WRAPPERS — function bodies above */

/* --- __imp__ pointers for __declspec(dllimport) callers --- */
__asm__("\n"
    ".globl __imp__wine_k32compat_GMHEW@12\n"
    ".section .rdata,\"dr\"\n"
    ".align 4\n"
    "__imp__wine_k32compat_GMHEW@12:\n"
    "    .long _wine_k32compat_GMHEW@12\n"
    ".globl __imp__GlobalMemoryStatusEx@4\n"
    ".align 4\n"
    "__imp__GlobalMemoryStatusEx@4:\n"
    "    .long _GlobalMemoryStatusEx@4\n"
    ".globl __imp__RtlIsCriticalSectionLockedByThread@4\n"
    ".align 4\n"
    "__imp__RtlIsCriticalSectionLockedByThread@4:\n"
    "    .long _RtlIsCriticalSectionLockedByThread@4\n"
    ".globl __imp__InitOnceExecuteOnce@16\n"
    ".align 4\n"
    "__imp__InitOnceExecuteOnce@16:\n"
    "    .long _InitOnceExecuteOnce@16\n"
    ".globl __imp__InitializeConditionVariable@4\n"
    ".align 4\n"
    "__imp__InitializeConditionVariable@4:\n"
    "    .long _InitializeConditionVariable@4\n"
    ".globl __imp__WakeConditionVariable@4\n"
    ".align 4\n"
    "__imp__WakeConditionVariable@4:\n"
    "    .long _WakeConditionVariable@4\n"
    ".globl __imp__WakeAllConditionVariable@4\n"
    ".align 4\n"
    "__imp__WakeAllConditionVariable@4:\n"
    "    .long _WakeAllConditionVariable@4\n"
    ".globl __imp__SleepConditionVariableCS@12\n"
    ".align 4\n"
    "__imp__SleepConditionVariableCS@12:\n"
    "    .long _SleepConditionVariableCS@12\n"
    ".globl __imp__SetThreadDescription@8\n"
    ".align 4\n"
    "__imp__SetThreadDescription@8:\n"
    "    .long _SetThreadDescription@8\n"
    ".globl __imp___copysignf\n"
    ".align 4\n"
    "__imp___copysignf:\n"
    "    .long __copysignf\n"
    ".globl __imp__floor\n"
    ".align 4\n"
    "__imp__floor:\n"
    "    .long _floor\n"
    ".globl __imp__floorf\n"
    ".align 4\n"
    "__imp__floorf:\n"
    "    .long _floorf\n"
    ".globl __imp___fstat32\n"
    ".align 4\n"
    "__imp___fstat32:\n"
    "    .long __fstat32\n"
    ".globl __imp___fdclass\n"
    ".align 4\n"
    "__imp___fdclass:\n"
    "    .long __fdclass\n"
    ".globl __imp___dclass\n"
    ".align 4\n"
    "__imp___dclass:\n"
    "    .long __dclass\n"
    ".globl __imp___dsign\n"
    ".align 4\n"
    "__imp___dsign:\n"
    "    .long __dsign\n"
    ".globl __imp___fdsign\n"
    ".align 4\n"
    "__imp___fdsign:\n"
    "    .long __fdsign\n"
    ".globl __imp__strnlen\n"
    ".align 4\n"
    "__imp__strnlen:\n"
    "    .long _strnlen\n"
    ".globl __imp___isctype\n"
    ".align 4\n"
    "__imp___isctype:\n"
    "    .long __isctype\n"
    /* __imp__ for UCRT stdio functions now in ucrtcompat.o (same .o as the
       function bodies) to prevent multiple-definition conflicts when both
       kernel32_compat.o and ucrtcompat.o end up in the same link. */
    ".text\n"
);

#ifdef K32COMPAT_DISPLAY_WRAPPERS
/* __imp__ pointers for user32 W→A wrappers */
__asm__("\n"
    ".globl __imp__wine_k32compat_EDD_W@16\n"
    ".section .rdata,\"dr\"\n"
    ".align 4\n"
    "__imp__wine_k32compat_EDD_W@16:\n"
    "    .long _wine_k32compat_EDD_W@16\n"
    ".globl __imp__wine_k32compat_EDS_W@12\n"
    ".align 4\n"
    "__imp__wine_k32compat_EDS_W@12:\n"
    "    .long _wine_k32compat_EDS_W@12\n"
    ".globl __imp__wine_k32compat_EDSE_W@16\n"
    ".align 4\n"
    "__imp__wine_k32compat_EDSE_W@16:\n"
    "    .long _wine_k32compat_EDSE_W@16\n"
    ".globl __imp__wine_k32compat_GMI_W@8\n"
    ".align 4\n"
    "__imp__wine_k32compat_GMI_W@8:\n"
    "    .long _wine_k32compat_GMI_W@8\n"
    ".globl __imp__wine_k32compat_EDM@16\n"
    ".align 4\n"
    "__imp__wine_k32compat_EDM@16:\n"
    "    .long _wine_k32compat_EDM@16\n"
    ".globl __imp__wine_k32compat_MFW@8\n"
    ".align 4\n"
    "__imp__wine_k32compat_MFW@8:\n"
    "    .long _wine_k32compat_MFW@8\n"
    ".globl __imp__wine_k32compat_MFP@12\n"
    ".align 4\n"
    "__imp__wine_k32compat_MFP@12:\n"
    "    .long _wine_k32compat_MFP@12\n"
    ".globl __imp__wine_k32compat_CDSE_W@20\n"
    ".align 4\n"
    "__imp__wine_k32compat_CDSE_W@20:\n"
    "    .long _wine_k32compat_CDSE_W@20\n"
    ".globl __imp__wine_k32compat_IBSP_W@8\n"
    ".align 4\n"
    "__imp__wine_k32compat_IBSP_W@8:\n"
    "    .long _wine_k32compat_IBSP_W@8\n"
    ".globl __imp__wine_k32compat_FLAET@8\n"
    ".align 4\n"
    "__imp__wine_k32compat_FLAET@8:\n"
    "    .long _wine_k32compat_FLAET@8\n"
    ".text\n"
);

/* __imp__ aliases for original Win2000+ function names (before -D rename).
   __declspec(dllimport) in system headers bypasses preprocessor -D flags,
   generating __imp__ references to the original names. */
__asm__("\n"
    ".globl __imp__FreeLibraryAndExitThread@8\n"
    ".align 4\n"
    "__imp__FreeLibraryAndExitThread@8:\n"
    "    .long _wine_k32compat_FLAET@8\n"
    ".globl __imp__ChangeDisplaySettingsExW@20\n"
    ".align 4\n"
    "__imp__ChangeDisplaySettingsExW@20:\n"
    "    .long _wine_k32compat_CDSE_W@20\n"
    ".text\n"
);
#endif /* K32COMPAT_DISPLAY_WRAPPERS */

/* __imp__IsBadStringPtrW@8 redirect for d3d9/d3d8/ddraw — these DLLs don't
   get K32COMPAT_DISPLAY_WRAPPERS so wine_k32compat_IBSP_W is unavailable.
   No-op: assume pointer is valid. Avoids importing IsBadStringPtrA. */
int __stdcall wine_k32compat_IBSP_W_nop(const void *lpsz, unsigned long ucchMax)
{
    (void)ucchMax;
    return lpsz ? 0 : 1;
}
__asm__("\n"
    ".globl __imp__IsBadStringPtrW@8\n"
    ".section .rdata,\"dr\"\n"
    ".align 4\n"
    "__imp__IsBadStringPtrW@8:\n"
    "    .long _wine_k32compat_IBSP_W_nop@8\n"
    ".text\n"
);

/* Provide _vsnprintf + __imp___vsnprintf for libwinecrt0.a (debug.c).
   crt-git 12.0's libmsvcrt.a doesn't have _vsnprintf, and Wine's
   ucrtbase import lib doesn't either. The no-op body is fine since
   debug.c only uses it for trace formatting. */
int __cdecl _vsnprintf(char *s, unsigned int n, const char *f, ...) {
    if (s && n > 0) s[0] = 0;
    return 0;
}
__asm__("\n"
    ".globl __imp___vsnprintf\n"
    ".section .rdata,\"dr\"\n"
    ".align 4\n"
    "__imp___vsnprintf:\n"
    "    .long __vsnprintf\n"
    ".text\n"
);

/* --- __stdio_common_vsprintf (UCRT, not in Win98 msvcrt.dll) --- */
/* crt-git resolves sprintf/vsnprintf family through this UCRT helper.
   Must be provided locally to prevent importing from msvcrt.dll. */
int __cdecl __stdio_common_vsprintf(unsigned long long o, char *b, unsigned int n, const char *f, void *l, void *a) {
    (void)o; (void)l;
    return _vsnprintf(b, n == (unsigned int)-1 ? 0x7fffffff : n, f, a);
}
__asm__("\n"
    ".globl __imp____stdio_common_vsprintf\n"
    ".section .rdata,\"dr\"\n"
    ".align 4\n"
    "__imp____stdio_common_vsprintf:\n"
    "    .long ___stdio_common_vsprintf\n"
    ".text\n"
);

K32EOF
        # Modern PE build: add UCRT compat directly to kernel32_compat.c.
        # The import libs are generated from stripped specs, so __acrt_iob_func,
        # __stdio_common_*, _initterm, _vsnprintf are not available. Legacy build
        # gets these from ucrtcompat.o injected into system libmsvcrt.a.
        if [ "$_build_mode" = "modern" ]; then
            cat >> "dlls/$dll/kernel32_compat.c" << 'UCRTEOF'

/* --- UCRT compat for modern PE build (not in stripped import libs) --- */
/* __acrt_iob_func: return stdin/stdout/stderr FILE array.
   Wine 8.x modern PE build links against Wine's libucrtbase.a (not MSYS2's
   libmsvcrt.a), so __iob_func is unavailable. Use a static buffer instead. */
static char _fake_iob[3][64];
void * __cdecl __acrt_iob_func(void) { return _fake_iob; }

/* __stdio_common_vsprintf is now in the common K32EOF section. */

int __cdecl __stdio_common_vfprintf(unsigned long long o, void *p, const char *f, void *l, void *a) {
    (void)o; (void)p; (void)f; (void)l; (void)a; return 0;
}
int __cdecl __stdio_common_vsscanf(unsigned long long o, const char *s, unsigned int n, const char *f, void *l, void *a) {
    (void)o; (void)s; (void)n; (void)f; (void)l; (void)a; return -1;
}

__asm__("\n"
    ".globl __imp____acrt_iob_func\n"
    ".section .rdata,\"dr\"\n"
    ".align 4\n"
    "__imp____acrt_iob_func:\n"
    "    .long ___acrt_iob_func\n"
    ".globl __imp____stdio_common_vfprintf\n"
    ".align 4\n"
    "__imp____stdio_common_vfprintf:\n"
    "    .long ___stdio_common_vfprintf\n"
    ".globl __imp____stdio_common_vsscanf\n"
    ".align 4\n"
    "__imp____stdio_common_vsscanf:\n"
    "    .long ___stdio_common_vsscanf\n"
    ".text\n"
);
UCRTEOF
        fi
        # Enable user32 display wrappers only for wined3d (other DLLs don't link user32)
        [ "$dll" = "wined3d" ] && sed -i '1i #define K32COMPAT_DISPLAY_WRAPPERS 1' "dlls/$dll/kernel32_compat.c"
        grep -q 'kernel32_compat.c' "$mf" || sed -i 's/^C_SRCS\s*=/C_SRCS = kernel32_compat.c /' "$mf"
    done
    echo "    Injected Win98 compat stubs into all DLLs"
}

# VidMem/HAL export stubs for the qemu-3dfx passthrough layer.
# Changes @ stub entries to @ stdcall so our C implementations are used.
create_ddraw_hooks() {
    [ -f dlls/ddraw/Makefile.in ] || return 0
    [ -f "$SCRIPT_DIR/qemu3dfx_ddraw_hooks.c" ] || return 0

    echo "    Injecting qemu-3dfx ddraw HAL stubs..."
    cp "$SCRIPT_DIR/qemu3dfx_ddraw_hooks.c" dlls/ddraw/qemu3dfx_ddraw_hooks.c
    grep -q 'qemu3dfx_ddraw_hooks.c' dlls/ddraw/Makefile.in || \
        sed -i 's/^C_SRCS\s*=/C_SRCS = qemu3dfx_ddraw_hooks.c /' dlls/ddraw/Makefile.in

    # Replace @ stub with @ stdcall for our hook functions in ddraw.spec.
    # winebuild does not export @ stub entries — must use @ stdcall.
    # Also add standard ddraw exports that Wine's spec doesn't include.
    if [ -f dlls/ddraw/ddraw.spec ]; then
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
            dlls/ddraw/ddraw.spec
        # Add standard ddraw.dll exports that 3DMark2000 expects but Wine's
        # spec doesn't define.  These are no-op stubs in our hooks file.
        grep -q 'AcquireDDThreadLock' dlls/ddraw/ddraw.spec || cat >> dlls/ddraw/ddraw.spec << 'SPECEOF'
@ stdcall AcquireDDThreadLock()
@ stdcall ReleaseDDThreadLock()
@ stdcall CompleteCreateSysmemSurface(ptr)
@ stdcall D3DParseUnknownCommand(ptr ptr)
SPECEOF
    fi
}

# ── qemu-3dfx ddraw → wined3d passthrough bridge ───────────────────
# Injects qemu3dfx_ddraw_passthrough.c into ddraw build and patches
# ddraw source files to call wined3d passthrough functions at the right
# points: init in DllMain, cooplevel in SetCooperativeLevel, blit/flip
# FPS limiting, and RTV override.
create_ddraw_passthrough() {
    [ -f dlls/ddraw/Makefile.in ] || return 0
    [ -f "$SCRIPT_DIR/qemu3dfx_ddraw_passthrough.c" ] || return 0

    echo "    Injecting qemu-3dfx ddraw passthrough bridge..."
    cp "$SCRIPT_DIR/qemu3dfx_ddraw_passthrough.c" dlls/ddraw/qemu3dfx_ddraw_passthrough.c
    grep -q 'qemu3dfx_ddraw_passthrough.c' dlls/ddraw/Makefile.in || \
        sed -i 's/^C_SRCS\s*=/C_SRCS = qemu3dfx_ddraw_passthrough.c /' dlls/ddraw/Makefile.in

    # ── Patch main.c: call passthrough init from DllMain ───────────
    if [ -f dlls/ddraw/main.c ]; then
        # Add extern declaration before DllMain (substitute preserves portability)
        sed -i 's/^BOOL WINAPI DllMain/extern void qemu3dfx_ddraw_passthrough_init(void);\
\
BOOL WINAPI DllMain/' dlls/ddraw/main.c
        # Add init call in DLL_PROCESS_ATTACH, after DisableThreadLibraryCalls
        sed -i 's/DisableThreadLibraryCalls(inst);/DisableThreadLibraryCalls(inst);\
        qemu3dfx_ddraw_passthrough_init();/' dlls/ddraw/main.c
        grep -q 'qemu3dfx_ddraw_passthrough_init' dlls/ddraw/main.c && \
            echo "    main.c: passthrough init hook injected" || \
            echo "    WARNING: main.c passthrough init hook NOT injected (sed mismatch)"
    fi

    # ── Patch ddraw.c: cooplevel override in SetCooperativeLevel ───
    if [ -f dlls/ddraw/ddraw.c ]; then
        # Add extern declaration after ddraw_private.h include
        sed -i 's/#include "ddraw_private.h"/#include "ddraw_private.h"\
extern void qemu3dfx_ddraw_cooplevel(DWORD *);/' dlls/ddraw/ddraw.c
        # Add cooplevel override right after DDRAW_dump_cooperativelevel
        sed -i 's/DDRAW_dump_cooperativelevel(cooplevel);/DDRAW_dump_cooperativelevel(cooplevel);\
    qemu3dfx_ddraw_cooplevel(\&cooplevel);/' dlls/ddraw/ddraw.c
        grep -q 'qemu3dfx_ddraw_cooplevel' dlls/ddraw/ddraw.c && \
            echo "    ddraw.c: cooplevel override hook injected" || \
            echo "    WARNING: ddraw.c cooplevel hook NOT injected (sed mismatch)"
    fi

    # ── Patch surface.c: blit/flip FPS limiters + RTV override ─────
    if [ -f dlls/ddraw/surface.c ]; then
        # Add extern declarations after ddraw_private.h include
        sed -i 's/#include "ddraw_private.h"/#include "ddraw_private.h"\
extern void qemu3dfx_ddraw_blit(void);\
extern void qemu3dfx_ddraw_flip(void);\
extern void qemu3dfx_ddraw_rtv(void *);/' dlls/ddraw/surface.c
        # Add blit limiter call before wined3d_texture_blt (Wine ≤ 6)
        sed -i 's/return wined3d_texture_blt(dst_surface/qemu3dfx_ddraw_blit();\
    return wined3d_texture_blt(dst_surface/' dlls/ddraw/surface.c
        # Add blit limiter call before wined3d_device_context_blt (Wine 7+)
        sed -i 's/return wined3d_device_context_blt(ddraw/qemu3dfx_ddraw_blit();\
    return wined3d_device_context_blt(ddraw/' dlls/ddraw/surface.c
        # Add flip limiter: match DDSCAPS_FLIP (unique to Flip function)
        # Wine ≤ 5: DDSCAPS2 caps = {DDSCAPS_FLIP, 0, 0, {0}};
        # Wine ≥ 6: DDSCAPS  caps = {DDSCAPS_FLIP};
        sed -i 's/\(DDSCAPS2\? caps = {DDSCAPS_FLIP.*\)/\1\
    qemu3dfx_ddraw_flip();/' dlls/ddraw/surface.c
        # Add RTV override after getting rendertarget view in Flip
        sed -i 's/\(tmp_rtv = ddraw_surface_get_rendertarget_view(dst_impl);\)/\1\
    qemu3dfx_ddraw_rtv(tmp_rtv);/' dlls/ddraw/surface.c
        # Verify patches applied
        echo "    Verifying passthrough patches..."
        grep -c 'qemu3dfx_ddraw_blit\|qemu3dfx_ddraw_flip\|qemu3dfx_ddraw_rtv' dlls/ddraw/surface.c | \
            xargs -I{} echo "      surface.c: {} passthrough hook(s) injected"
    fi
}

# ── Patch DLL imports: ucrtbase.dll → msvcrt.dll ────────────────────
# Post-collection safety net: binary-patch any remaining ucrtbase imports.
# "ucrtbase.dll\0" = 14 bytes; "msvcrt.dll\0\0\0" = 14 bytes — same length.
patch_ucrt_imports() {
    python3 -c "
import sys, os, glob
for path in glob.glob(os.path.join(sys.argv[1], '*.dll')):
    with open(path, 'rb') as f: data = f.read()
    p = data.replace(b'ucrtbase.dll\x00', b'msvcrt.dll\x00\x00\x00')
    if p != data:
        with open(path, 'wb') as f: f.write(p)
        print('  [fix] ucrtbase->msvcrt:', os.path.basename(path))
" "$1" 2>/dev/null || perl -e '
    use File::Glob qw(:bsd_glob);
    for my $f (bsd_glob("$ARGV[0]/*.dll")) {
        open my $fh, "+<:raw", $f or next;
        local $/; my $d = <$fh>;
        my $p = $d; $p =~ s/ucrtbase\.dll\x00/msvcrt.dll\x00\x00\x00/g;
        if ($p ne $d) { seek $fh,0,0; truncate $fh,0; print $fh $p; print "  [fix] ucrtbase->msvcrt: $f\n"; }
        close $fh;
    }
' "$1"
}

# ── Modern build (Wine 8.x+, PE build system) ──────────────────────
build_modern() {
    local srcdir=$1 version=$2 build_msvcrt=$3
    local wine_src="$srcdir/wine-${version}"

    cd "$wine_src"

    # Patch Makefile.in templates BEFORE configure — makedep regenerates
    # Makefiles during the build so post-configure sed doesn't stick.
    echo "    Patching Makefile.in templates (ucrtbase → msvcrt)..."
    find . -name 'Makefile.in' | xargs grep -l 'ucrtbase' 2>/dev/null | \
        xargs sed -i 's/-lucrtbase/-lmsvcrt/g' 2>/dev/null || true

    # Gut dlls/ucrtbase so Wine builds an empty import lib.
    # ucrtbase exports CRT functions (strlen, memset, etc.) that conflict
    # with ntdll's versions when both are in the link. Empty the spec so
    # winebuild generates libucrtbase.a with no exports. Our kernel32_compat.c
    # stubs provide the few UCRT functions actually needed (__acrt_iob_func).
    if [ -f dlls/ucrtbase/Makefile.in ]; then
        sed -i \
            -e '/^DELAYIMPORTS/d' \
            -e '/^IMPORTS/d' \
            -e 's/^C_SRCS\s*=.*/C_SRCS =/' \
            -e 's/^RC_SRCS\s*=.*/RC_SRCS =/' \
            dlls/ucrtbase/Makefile.in
    fi

    # D3DKMT stubs — prevent Vista+-only static imports from gdi32.dll
    create_d3dkmt_stubs

    # qemu-3dfx ddraw HAL VidMem stubs
    create_ddraw_hooks

    # qemu-3dfx ddraw → wined3d passthrough bridge
    create_ddraw_passthrough

    # Inject GetModuleHandleExW Win98 compat into all DLLs
    create_kernel32_compat modern

    # Redirect GetModuleHandleExW calls to our compat wrapper (wined3d only).
    # d3d8/d3d9/ddraw don't use GetModuleHandleExW — they import GetModuleHandleA.
    for dll in wined3d; do
        for f in dlls/$dll/*.c; do
            [ -f "$f" ] || continue
            case "$f" in */kernel32_compat.c) continue ;; esac
            grep -q 'GetModuleHandleExW' "$f" 2>/dev/null || continue
            sed -i '1i #define GetModuleHandleExW wine_k32compat_GMHEW' "$f"
            echo "    Redirected GetModuleHandleExW in $f"
        done
    done

    # Redirect Win2000+ user32 W-version display functions to compat wrappers.
    # wined3d only — d3d8/d3d9 have no user32 imports, ddraw imports
    # MonitorFromWindow/GetMonitorInfoW from user32 directly (available on Win98 SE).
    for dll in wined3d; do
        for f in dlls/$dll/*.c; do
            [ -f "$f" ] || continue
            case "$f" in */kernel32_compat.c) continue ;; esac
            local changed=0
            for func in EnumDisplayDevicesW EnumDisplaySettingsW EnumDisplaySettingsExW \
                        GetMonitorInfoW EnumDisplayMonitors MonitorFromWindow MonitorFromPoint \
                        ChangeDisplaySettingsExW IsBadStringPtrW FreeLibraryAndExitThread; do
                grep -q "$func" "$f" 2>/dev/null || continue
                local compat
                case "$func" in
                    EnumDisplayDevicesW) compat=wine_k32compat_EDD_W ;;
                    EnumDisplaySettingsW) compat=wine_k32compat_EDS_W ;;
                    EnumDisplaySettingsExW) compat=wine_k32compat_EDSE_W ;;
                    GetMonitorInfoW) compat=wine_k32compat_GMI_W ;;
                    EnumDisplayMonitors) compat=wine_k32compat_EDM ;;
                    MonitorFromWindow) compat=wine_k32compat_MFW ;;
                    MonitorFromPoint) compat=wine_k32compat_MFP ;;
                    ChangeDisplaySettingsExW) compat=wine_k32compat_CDSE_W ;;
                    IsBadStringPtrW) compat=wine_k32compat_IBSP_W ;;
                    FreeLibraryAndExitThread) compat=wine_k32compat_FLAET ;;
                esac
                sed -i "1i #define $func $compat" "$f"
                changed=1
            done
            [ "$changed" = 1 ] && echo "    Redirected user32 W-funcs in $f"
        done
    done

    echo "    Configuring (native PE mode on MSYS2)..."
    CROSSCC=gcc ./configure \
        --enable-archs=i386 \
        --without-x \
        --without-alsa --without-capi --without-cups --without-dbus \
        --without-fontconfig --without-freetype --without-gphoto \
        --without-gstreamer --without-opencl \
        --without-pcap --without-pulse --without-sane \
        --without-sdl --without-udev --without-usb \
        --without-v4l2 --without-vulkan --without-oss \
        CFLAGS="-O3 -march=i686 -msse4.2 -mtune=generic -fcommon -fno-builtin -DWINE_NOWINSOCK -DUSE_WIN32_OPENGL -DUSE_WIN32_VULKAN -DNDEBUG -D__MSVCRT__ -U_UCRT -DGetModuleHandleExW=wine_k32compat_GMHEW -Dcopysignf=_copysignf" \
        LDFLAGS="-Wl,--image-base=0x10000000 -static-libgcc -mcrtdll=msvcrt -Xlinker --exclude-symbols -Xlinker _wine_k32compat_GMHEW@12,__imp__wine_k32compat_GMHEW@12,_GlobalMemoryStatusEx@4,__imp__GlobalMemoryStatusEx@4,_RtlIsCriticalSectionLockedByThread@4,__imp__RtlIsCriticalSectionLockedByThread@4,_InitOnceExecuteOnce@16,__imp__InitOnceExecuteOnce@16,_InitializeConditionVariable@4,__imp__InitializeConditionVariable@4,_WakeConditionVariable@4,__imp__WakeConditionVariable@4,_WakeAllConditionVariable@4,__imp__WakeAllConditionVariable@4,_SleepConditionVariableCS@12,__imp__SleepConditionVariableCS@12,_SetThreadDescription@8,__imp__SetThreadDescription@8,_copysignf,__imp___copysignf,floor,__imp__floor,floorf,__imp__floorf,_vsnprintf,__imp___vsnprintf,_isctype,__imp___isctype,atoi,atol,abs,isprint,isdigit,isalpha,isalnum,isspace,isupper,islower,isxdigit,iscntrl,isgraph,ispunct,__acrt_iob_func,__imp____acrt_iob_func,_fdclass,__imp___fdclass,_dclass,__imp___dclass,_dsign,__imp___dsign,_fdsign,__imp___fdsign,__stdio_common_vsprintf,__imp____stdio_common_vsprintf,__stdio_common_vfprintf,__imp____stdio_common_vfprintf,__stdio_common_vsscanf,__imp____stdio_common_vsscanf,memcmp,__imp__memcmp,memchr,__imp__memchr,memcpy,__imp__memcpy,memset,__imp__memset,memmove,__imp__memmove,strlen,__imp__strlen,strcpy,__imp__strcpy,strcat,__imp__strcat,strcmp,__imp__strcmp,strncmp,__imp__strncmp,strchr,__imp__strchr,strrchr,__imp__strrchr,strstr,__imp__strstr,strcspn,__imp__strcspn,strnlen,__imp__strnlen,exp,__imp__exp,log,__imp__log,pow,__imp__pow,sprintf,__imp__sprintf,fprintf,__imp__fprintf,strtoul,__imp__strtoul,getc,__imp__getc,ungetc,__imp__ungetc,__lc_codepage,__imp____lc_codepage,_fstat32,__imp___fstat32,_wine_k32compat_EDD_W@16,__imp__wine_k32compat_EDD_W@16,_wine_k32compat_EDS_W@12,__imp__wine_k32compat_EDS_W@12,_wine_k32compat_EDSE_W@16,__imp__wine_k32compat_EDSE_W@16,_wine_k32compat_GMI_W@8,__imp__wine_k32compat_GMI_W@8,_wine_k32compat_EDM@16,__imp__wine_k32compat_EDM@16,_wine_k32compat_MFW@8,__imp__wine_k32compat_MFW@8,_wine_k32compat_MFP@12,__imp__wine_k32compat_MFP@12,_wine_k32compat_CDSE_W@20,__imp__wine_k32compat_CDSE_W@20,_wine_k32compat_IBSP_W@8,__imp__wine_k32compat_IBSP_W@8,_wine_k32compat_FLAET@8,__imp__wine_k32compat_FLAET@8" \
        CROSSCFLAGS="-O3 -march=i686 -msse4.2 -mtune=generic -fcommon -fno-builtin -DWINE_NOWINSOCK -DUSE_WIN32_OPENGL -DUSE_WIN32_VULKAN -DNDEBUG -mcrtdll=msvcrt -D__MSVCRT__ -U_UCRT -DGetModuleHandleExW=wine_k32compat_GMHEW -Dcopysignf=_copysignf" \
        CROSSLDFLAGS="-Wl,--image-base=0x10000000 -static-libgcc -mcrtdll=msvcrt -Xlinker --exclude-symbols -Xlinker _wine_k32compat_GMHEW@12,__imp__wine_k32compat_GMHEW@12,_GlobalMemoryStatusEx@4,__imp__GlobalMemoryStatusEx@4,_RtlIsCriticalSectionLockedByThread@4,__imp__RtlIsCriticalSectionLockedByThread@4,_InitOnceExecuteOnce@16,__imp__InitOnceExecuteOnce@16,_InitializeConditionVariable@4,__imp__InitializeConditionVariable@4,_WakeConditionVariable@4,__imp__WakeConditionVariable@4,_WakeAllConditionVariable@4,__imp__WakeAllConditionVariable@4,_SleepConditionVariableCS@12,__imp__SleepConditionVariableCS@12,_SetThreadDescription@8,__imp__SetThreadDescription@8,_copysignf,__imp___copysignf,floor,__imp__floor,floorf,__imp__floorf,_vsnprintf,__imp___vsnprintf,_isctype,__imp___isctype,atoi,atol,abs,isprint,isdigit,isalpha,isalnum,isspace,isupper,islower,isxdigit,iscntrl,isgraph,ispunct,__acrt_iob_func,__imp____acrt_iob_func,_fdclass,__imp___fdclass,_dclass,__imp___dclass,_dsign,__imp___dsign,_fdsign,__imp___fdsign,__stdio_common_vsprintf,__imp____stdio_common_vsprintf,__stdio_common_vfprintf,__imp____stdio_common_vfprintf,__stdio_common_vsscanf,__imp____stdio_common_vsscanf,memcmp,__imp__memcmp,memchr,__imp__memchr,memcpy,__imp__memcpy,memset,__imp__memset,memmove,__imp__memmove,strlen,__imp__strlen,strcpy,__imp__strcpy,strcat,__imp__strcat,strcmp,__imp__strcmp,strncmp,__imp__strncmp,strchr,__imp__strchr,strrchr,__imp__strrchr,strstr,__imp__strstr,strcspn,__imp__strcspn,strnlen,__imp__strnlen,exp,__imp__exp,log,__imp__log,pow,__imp__pow,sprintf,__imp__sprintf,fprintf,__imp__fprintf,strtoul,__imp__strtoul,getc,__imp__getc,ungetc,__imp__ungetc,__lc_codepage,__imp____lc_codepage,_fstat32,__imp___fstat32,_wine_k32compat_EDD_W@16,__imp__wine_k32compat_EDD_W@16,_wine_k32compat_EDS_W@12,__imp__wine_k32compat_EDS_W@12,_wine_k32compat_EDSE_W@16,__imp__wine_k32compat_EDSE_W@16,_wine_k32compat_GMI_W@8,__imp__wine_k32compat_GMI_W@8,_wine_k32compat_EDM@16,__imp__wine_k32compat_EDM@16,_wine_k32compat_MFW@8,__imp__wine_k32compat_MFW@8,_wine_k32compat_MFP@12,__imp__wine_k32compat_MFP@12,_wine_k32compat_CDSE_W@20,__imp__wine_k32compat_CDSE_W@20,_wine_k32compat_IBSP_W@8,__imp__wine_k32compat_IBSP_W@8,_wine_k32compat_FLAET@8,__imp__wine_k32compat_FLAET@8"

    # winebuild.exe is a PE binary; in --without-dlltool mode it spawns
    # the assembler via Windows CreateProcess which requires the MinGW bin
    # to be in the Windows PATH.  Remove the flag so winebuild uses dlltool
    # (an MSYS2 binary on the MSYS2 PATH) instead.
    sed -i 's/ --without-dlltool//g' Makefile

    # Strip Vista+ API from kernel32/ntdll specs — MUST be after configure,
    # which regenerates spec files from .spec.in and undoes pre-configure sed.
    strip_kernel32_vista_imports

    # Strip UCRT from msvcrt.spec (same as Docker modern path)
    for spec in dlls/msvcrt/msvcrt.spec; do
        [ -f "$spec" ] || continue
        sed -i -e '/__acrt_iob_func/d' \
               -e '/__stdio_common_/d' \
               "$spec"
    done

    # Strip UCRT wrapper exports from ucrtbase.spec (same as Docker modern path)
    for spec in dlls/ucrtbase/ucrtbase.spec; do
        [ -f "$spec" ] || continue
        sed -i -e '/__acrt_iob_func/d' \
               -e '/__stdio_common_vsprintf/d' \
               -e '/__stdio_common_vfprintf/d' \
               -e '/__stdio_common_vsscanf/d' \
               -e '/__stdio_common_vswprintf/d' \
               -e '/__stdio_common_vfwprintf/d' \
               -e '/__stdio_common_vfscanf/d' \
               -e '/__stdio_common_vsnprintf/d' \
               -e '/__stdio_common_vsnwprintf/d' \
               -e '/__stdio_common_vsprintf_s/d' \
               -e '/__stdio_common_vsprintf_p/d' \
               -e '/__stdio_common_vfprintf_s/d' \
               -e '/__stdio_common_vswprintf_s/d' \
               -e '/__stdio_common_vswprintf_p/d' \
               -e '/__stdio_common_vfwprintf_s/d' \
               -e '/_o___acrt_iob_func/d' \
               -e '/_o___stdio_common/d' \
               "$spec"
    done

    # Same objcopy treatment for msvcrt compatibility
    patch_mingw_archives

    # Inject UCRT compat stubs into libmsvcrt.a
    create_ucrtcompat

    # winebuild.exe (PE binary) uses -b i686-w64-mingw32 to locate cross-
    # tools like i686-w64-mingw32-dlltool.  Copy real MSYS2 binaries with
    # the cross-prefix into /mingw32/bin/ where DLL deps are co-located.
    echo "    Creating cross-prefixed tool copies..."
    for tool in as ar nm objcopy ranlib strip ld dlltool windres; do
        [ -x "/mingw32/bin/$tool.exe" ] && cp "/mingw32/bin/$tool.exe" "/mingw32/bin/i686-w64-mingw32-$tool.exe"
    done

    # Build ALL tools so widl, wrc, etc. are available for the PE build
    echo "    Building all tools..."
    export PATH="/mingw32/bin:$PATH"
    make -j"$NPROC" tools
    export PATH="$(pwd)/tools/winebuild:$PATH"

    # Wine's own import libs (built by make tools) contain Vista+ symbols
    # that our kernel32_compat.c stubs. Strip them so the linker uses our
    # local __imp__ pointers instead of generating PE import table entries.
    echo "    Stripping Vista+ symbols from Wine-built import libs..."
    strip_kernel32_vista_imports_wine

    # Inject ibspw_compat.o into Wine-generated KERNEL32 import lib so d3d9/d3d8
    # can resolve __imp__IsBadStringPtrW@8. IsBadStringPtrW was stripped from
    # kernel32 (Win2K+ API). Our stub redirects to IsBadStringPtrA@8 (Win98-safe).
    # Must go into libkernel32.a (not libmsvcrt.a) — the linker resolves kernel32
    # functions from libkernel32.
    local _ibspw_tmp=$(mktemp -d)
    cat > "$_ibspw_tmp/ibspw_compat.c" << 'IBSPEOF'
__asm__("\n"
    ".globl __imp__IsBadStringPtrW@8\n"
    ".section .rdata,\"dr\"\n"
    ".align 4\n"
    "__imp__IsBadStringPtrW@8:\n"
    "    .long _IsBadStringPtrA@8\n"
    ".text\n"
);
IBSPEOF
    gcc -nostdinc -c -O2 -Wno-attributes -o "$_ibspw_tmp/ibspw_compat.o" "$_ibspw_tmp/ibspw_compat.c"
    for lib in dlls/kernel32/i386-windows/libkernel32.a dlls/kernel32/libkernel32.a; do
        [ -f "$lib" ] || continue
        ar rs "$lib" "$_ibspw_tmp/ibspw_compat.o" 2>/dev/null && \
            echo "    Injected ibspw_compat.o into Wine $lib"
    done
    rm -rf "$_ibspw_tmp"

    local targets=(
        dlls/wined3d/i386-windows/wined3d.dll
        dlls/d3d9/i386-windows/d3d9.dll
        dlls/d3d8/i386-windows/d3d8.dll
        dlls/ddraw/i386-windows/ddraw.dll
    )
    if [ "$build_msvcrt" = "1" ]; then
        targets+=(dlls/msvcrt/i386-windows/msvcrt.dll)
    fi

    echo "    Building targets..."
    make -j"$NPROC" "${targets[@]}"
}

# ── Legacy build (Wine 1.x–7.x, winegcc) ──────────────────────────
build_legacy() {
    local srcdir=$1 version=$2 build_msvcrt=$3
    local wine_src="$srcdir/wine-${version}"

    cd "$wine_src"

    # Patch aclocal.m4: fix broken symlink path for import libs.
    if [ -f aclocal.m4 ]; then
        sed -i 's|\$(LN_S) $ac_name/lib$ac_implib.$IMPLIBEXT \$[@]|\$(LN_S) dlls/$ac_name/lib$ac_implib.$IMPLIBEXT \$[@]|' aclocal.m4
    fi

    # Patch Makefile.in templates to remove libwine dependency at the source.
    # Wine 1.x-3.x use IMPORTS/EXTRALIBS in Makefile.in with "wine" or
    # "libwine" — both must be stripped to prevent winebuild from generating
    # a PE import table entry for libwine.dll in the .spec.o file.
    for dll in wined3d d3d9 d3d8 ddraw; do
        local mf="dlls/$dll/Makefile.in"
        [ -f "$mf" ] || continue
        sed -i \
            -e '/^IMPORTS[[:space:]]*=/s/[[:space:]]libwine\([[:space:]]\|$\)//g' \
            -e '/^IMPORTS[[:space:]]*=/s/[[:space:]]wine\([[:space:]]\|$\)//g' \
            "$mf"
        # Replace -lwine with static archive path
        sed -i 's/-lwine\([[:space:]]\|$\)/..\/..\/libs\/wine\/wine-stubs.a\1/g' "$mf"
    done

    # D3DKMT stubs — prevent Vista+-only static imports from gdi32.dll
    create_d3dkmt_stubs

    # qemu-3dfx ddraw HAL VidMem stubs
    create_ddraw_hooks

    # qemu-3dfx ddraw → wined3d passthrough bridge
    create_ddraw_passthrough

    # Inject GetModuleHandleExW Win98 compat into all DLLs
    create_kernel32_compat

    # Redirect GetModuleHandleExW calls to our compat wrapper (wined3d only).
    # d3d8/d3d9/ddraw don't call GetModuleHandleExW — they use GetModuleHandleA.
    for dll in wined3d; do
        for f in dlls/$dll/*.c; do
            [ -f "$f" ] || continue
            case "$f" in */kernel32_compat.c) continue ;; esac
            grep -q 'GetModuleHandleExW' "$f" 2>/dev/null || continue
            sed -i '1i #define GetModuleHandleExW wine_k32compat_GMHEW' "$f"
            echo "    Redirected GetModuleHandleExW in $f"
        done
    done

    # Redirect Win2000+ user32 W-version display functions to compat wrappers.
    # wined3d only — d3d8/d3d9 have no user32 imports, ddraw imports
    # MonitorFromWindow/GetMonitorInfoW from user32 directly (available on Win98 SE).
    for dll in wined3d; do
        for f in dlls/$dll/*.c; do
            [ -f "$f" ] || continue
            case "$f" in */kernel32_compat.c) continue ;; esac
            local changed=0
            for func in EnumDisplayDevicesW EnumDisplaySettingsW EnumDisplaySettingsExW \
                        GetMonitorInfoW EnumDisplayMonitors MonitorFromWindow MonitorFromPoint \
                        ChangeDisplaySettingsExW IsBadStringPtrW FreeLibraryAndExitThread; do
                grep -q "$func" "$f" 2>/dev/null || continue
                local compat
                case "$func" in
                    EnumDisplayDevicesW) compat=wine_k32compat_EDD_W ;;
                    EnumDisplaySettingsW) compat=wine_k32compat_EDS_W ;;
                    EnumDisplaySettingsExW) compat=wine_k32compat_EDSE_W ;;
                    GetMonitorInfoW) compat=wine_k32compat_GMI_W ;;
                    EnumDisplayMonitors) compat=wine_k32compat_EDM ;;
                    MonitorFromWindow) compat=wine_k32compat_MFW ;;
                    MonitorFromPoint) compat=wine_k32compat_MFP ;;
                    ChangeDisplaySettingsExW) compat=wine_k32compat_CDSE_W ;;
                    IsBadStringPtrW) compat=wine_k32compat_IBSP_W ;;
                    FreeLibraryAndExitThread) compat=wine_k32compat_FLAET ;;
                esac
                sed -i "1i #define $func $compat" "$f"
                changed=1
            done
            [ "$changed" = 1 ] && echo "    Redirected user32 W-funcs in $f"
        done
    done

    echo "    Configuring (legacy winegcc mode)..."
    ./configure \
        --without-x \
        --without-alsa --without-capi --without-cups --without-dbus \
        --without-fontconfig --without-freetype --without-gphoto \
        --without-gstreamer --without-opencl \
        --without-pcap --without-pulse --without-sane --without-oss \
        --without-vulkan \
        --disable-shared --enable-static \
        CFLAGS="-O3 -march=i686 -msse4.2 -mtune=generic -fcommon -fno-builtin -DWINE_NOWINSOCK -DUSE_WIN32_OPENGL -DUSE_WIN32_VULKAN -DNDEBUG -D__MSVCRT__ -DGetModuleHandleExW=wine_k32compat_GMHEW -Dcopysignf=_copysignf" \
        LDFLAGS="-Wl,--image-base=0x10000000 -static-libgcc -mcrtdll=msvcrt"

    # Strip Vista+ API from kernel32/ntdll specs — MUST be after configure,
    # which regenerates spec files from .spec.in and undoes pre-configure sed.
    strip_kernel32_vista_imports

    # Redirect __acrt_iob_func → __iob_func in MinGW runtime archives
    # and inject UCRT compat stubs into libmsvcrt.a
    create_ucrtcompat
    patch_mingw_archives

    echo "    Building tools..."
    make -j"$NPROC" tools/makedep

    # Generate Makefiles — libs/port and libs/wpp restructured/removed in later versions
    local makefiles=(
        libs/wine/Makefile
        tools/winebuild/Makefile tools/wrc/Makefile
        tools/widl/Makefile tools/winegcc/Makefile
        include/Makefile
    )
    [ -d libs/port ] && makefiles+=(libs/port/Makefile)
    [ -d libs/wpp ] && makefiles+=(libs/wpp/Makefile)
    make "${makefiles[@]}"

    make -j"$NPROC" libs/port 2>/dev/null || :
    # Build libs/wine for libwine_static.a (needed by wrc).  We delete the
    # shared DLL files afterwards and replace libwine.a with a stub.
    [ -d libs/wine ] && make -j"$NPROC" -C libs/wine 2>/dev/null || :
    [ -d libs/wpp ] && make -C libs/wpp libwpp.a 2>/dev/null || :

    # Create a winegcc wrapper that:
    # - Filters out -lwine and -lucrtbase from command-line args
    # - Injects -mcrtdll=msvcrt for GCC CRT selection
    # - Adds ucrtcompat.o directly to the link (winegcc uses Wine's own
    #   ucrtbase import lib, not system's libmsvcrt.a, so ucrtcompat.o
    #   injected into system libs is invisible to the linker).
    wine_src_root="$(pwd)"
    cat > tools/winegcc/winegcc-filter << WGEOF
#!/bin/bash
SELFDIR="\$(cd "\$(dirname "\$0")" && pwd)"
ROOTDIR="\$(cd "\$SELFDIR/../.." && pwd)"
STUB="\$ROOTDIR/libs/wine/wine-stubs.a"
args=()
compile_only=0
for arg in "\$@"; do
    case "\$arg" in
        -c)           compile_only=1; args+=("\$arg") ;;
        -E|-S)        compile_only=1; args+=("\$arg") ;;
        -lwine)       args+=("\$STUB") ;;
        -lucrtbase)   args+=("-lmsvcrt") ;;
        *)            args+=("\$arg") ;;
    esac
done
if [ \$compile_only -eq 0 ]; then
    args+=(-mcrtdll=msvcrt)
    args+=(-Wl,-S)
    args+=(-Wl,--image-base=0x10000000)
    # Inject CRT compat stubs directly — winegcc links Wine's own
    # ucrtbase import lib (dlls/ucrtbase/libucrtbase.a) which doesn't
    # have _vsnprintf or the UCRT compat stubs we added to system libs.
    [ -f ${TMPDIR:-/tmp}/ucrtcompat.o ] && args+=(${TMPDIR:-/tmp}/ucrtcompat.o)
    # Exclude wine_k32compat_GMHEW (GetModuleHandleExW redirect) stub from
    # DLL exports so it doesn't leak into import libs.
    args+=(-Xlinker --exclude-symbols -Xlinker _wine_k32compat_GMHEW@12,__imp__wine_k32compat_GMHEW@12,_GlobalMemoryStatusEx@4,__imp__GlobalMemoryStatusEx@4,_RtlIsCriticalSectionLockedByThread@4,__imp__RtlIsCriticalSectionLockedByThread@4,_InitOnceExecuteOnce@16,__imp__InitOnceExecuteOnce@16,_InitializeConditionVariable@4,__imp__InitializeConditionVariable@4,_WakeConditionVariable@4,__imp__WakeConditionVariable@4,_WakeAllConditionVariable@4,__imp__WakeAllConditionVariable@4,_SleepConditionVariableCS@12,__imp__SleepConditionVariableCS@12,_SetThreadDescription@8,__imp__SetThreadDescription@8,floor,__imp__floor,floorf,__imp__floorf,_vsnprintf,__imp___vsnprintf,atoi,atol,abs,isprint,isdigit,isalpha,isalnum,isspace,isupper,islower,isxdigit,iscntrl,isgraph,ispunct,__acrt_iob_func,__imp____acrt_iob_func,_fdclass,__imp___fdclass,_dclass,__imp___dclass,_dsign,__imp___dsign,_fdsign,__imp___fdsign,__stdio_common_vsprintf,__imp____stdio_common_vsprintf,__stdio_common_vfprintf,__imp____stdio_common_vfprintf,__stdio_common_vsscanf,__imp____stdio_common_vsscanf,memcmp,__imp__memcmp,memchr,__imp__memchr,memcpy,__imp__memcpy,memset,__imp__memset,memmove,__imp__memmove,strlen,__imp__strlen,strcpy,__imp__strcpy,strcat,__imp__strcat,strcmp,__imp__strcmp,strncmp,__imp__strncmp,strchr,__imp__strchr,strrchr,__imp__strrchr,strstr,__imp__strstr,strcspn,__imp__strcspn,strnlen,__imp__strnlen,exp,__imp__exp,log,__imp__log,pow,__imp__pow,sprintf,__imp__sprintf,fprintf,__imp__fprintf,strtoul,__imp__strtoul,getc,__imp__getc,ungetc,__imp__ungetc,__lc_codepage,__imp____lc_codepage,_fstat32,__imp___fstat32,_wine_k32compat_EDD_W@16,__imp__wine_k32compat_EDD_W@16,_wine_k32compat_EDS_W@12,__imp__wine_k32compat_EDS_W@12,_wine_k32compat_EDSE_W@16,__imp__wine_k32compat_EDSE_W@16,_wine_k32compat_GMI_W@8,__imp__wine_k32compat_GMI_W@8,_wine_k32compat_EDM@16,__imp__wine_k32compat_EDM@16,_wine_k32compat_MFW@8,__imp__wine_k32compat_MFW@8,_wine_k32compat_MFP@12,__imp__wine_k32compat_MFP@12)
    # Belt-and-suspenders: force static linking for any remaining -lwine
    # references that may have been injected by winebuild/winegcc internals.
    new_args=()
    for a in "\${args[@]}"; do
        if [ "\$a" = "-lwine" ]; then
            new_args+=(-Wl,-Bstatic "\$STUB" -Wl,-Bdynamic)
        else
            new_args+=("\$a")
        fi
    done
    args=("\${new_args[@]}")
fi
exec "\$SELFDIR/winegcc.exe" "\${args[@]}"
WGEOF
    chmod +x tools/winegcc/winegcc-filter

    # Patch winegcc.c to fix libwine and ucrtbase at the source.
    # winegcc uses -nodefaultlibs -nostartfiles and then EXPLICITLY
    # adds the CRT library via add_library(), so -mcrtdll=msvcrt
    # alone has no effect — we must patch the source.
    if [ -f tools/winegcc/winegcc.c ]; then
        # --- libwine fix ---
        # Wine 1.x-3.x: add_library(opts, lib_dirs, files, "wine")
        # This dynamically resolves to -lwine / libwine.so / libwine.dll.a
        # depending on what's found in the library search path.
        # Delete the entire line to prevent any libwine reference.
        sed -i '/add_library.*"wine"/d' tools/winegcc/winegcc.c
        # Wine 7.x+: "-lwine" as a string literal
        sed -i 's/"-lwine"/"..\/..\/libs\/wine\/wine-stubs.a"/g' tools/winegcc/winegcc.c
        # winebuild --import argument: "libwine" (Wine 4.x+) or "wine" (Wine 1.x-3.x)
        sed -i '/"libwine"/d' tools/winegcc/winegcc.c
        # Neutralize /libwine.so in get_lib_dir()
        sed -i 's|/libwine\.so|/libwine_stubs_dummy|g' tools/winegcc/winegcc.c

        # --- ucrtbase fix ---
        # winegcc explicitly calls add_library(lib_dirs, &files, "ucrtbase")
        # when use_msvcrt is true.  Replace with "msvcrt" to link against
        # msvcrt.dll instead of ucrtbase.dll.
        sed -i 's/"ucrtbase"/"msvcrt"/g' tools/winegcc/winegcc.c

        echo "    Patched winegcc.c: libwine + ucrtbase elimination"
        # Verify the patch took effect — if "wine" library references remain,
        # the DLLs will link against libwine.dll at runtime.
        if grep -q 'add_library.*"wine"' tools/winegcc/winegcc.c 2>/dev/null; then
            echo "    WARNING: add_library(\"wine\") still present after patch!"
            grep -n 'add_library.*"wine"' tools/winegcc/winegcc.c
        fi
    fi

    for tool in winebuild wrc widl; do
        make -j"$NPROC" -C "tools/$tool"
    done

    # Force unconditional rebuild of winegcc from patched source.
    # -B flag tells make to rebuild all targets regardless of timestamps.
    echo "    Rebuilding winegcc from patched source..."
    make -B -C tools/winegcc
    # Verify the binary exists
    ls -la tools/winegcc/winegcc* 2>/dev/null || echo "    WARNING: winegcc binary not found!"
    make -C include 2>/dev/null || :
    make tools/make_xftmpl 2>/dev/null || :

    # Localize CRT symbols in libwine_port.a (after all tools are built).
    # ReactOS doesn't link libwine_port.a at all — CRT resolves from
    # msvcrt.dll via import thunks. We can't remove the archive (tools
    # need mkstemps etc.), but localizing CRT symbols makes them invisible
    # to the linker for resolving external references. The linker then
    # finds memcpy/memset/etc. in libmsvcrt.a (→ msvcrt.dll imports).
    # Non-CRT functions (mkstemps, etc.) remain global for tool rebuilds.
    if [ -f libs/port/libwine_port.a ]; then
        local port_tmp="${TMPDIR:-/tmp}/port_$$_$(date +%s).a"
        local loc_args=()
        for sym in \
            memcpy memset memmove memcmp memchr \
            strlen strcpy strcat strcmp strncmp \
            strchr strrchr strstr strcspn strnlen \
            atoi strtol strtoul \
            strcasecmp strncasecmp strnicmp; do
            loc_args+=(--localize-symbol "_${sym}")
        done
        if objcopy "${loc_args[@]}" libs/port/libwine_port.a "$port_tmp" 2>/dev/null && [ -f "$port_tmp" ]; then
            mv "$port_tmp" libs/port/libwine_port.a
            echo "    Localized CRT symbols in libwine_port.a"
        else
            rm -f "$port_tmp"
            echo "    (libwine_port.a CRT localization skipped)"
        fi
    fi

    echo "    Preparing DLL build dirs..."
    make \
        dlls/wined3d/Makefile dlls/d3d9/Makefile \
        dlls/d3d8/Makefile dlls/ddraw/Makefile \
        dlls/winecrt0/Makefile \
        dlls/opengl32/Makefile
    # uuid/dxguid restructured in Wine 7+ — skip if rule doesn't exist
    make dlls/uuid/Makefile 2>/dev/null || true
    make dlls/dxguid/Makefile 2>/dev/null || true
    if [ "$build_msvcrt" = "1" ]; then
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

    # Strip flags not needed on Windows (only DLL Makefiles — touching tool
    # Makefiles triggers tool rebuilds during the DLL make phase)
    find dlls -name Makefile | xargs sed -i \
        -e 's/-fPIC//g' \
        -e 's/-fstack-protector[^ ]*//g'

    # Use winegcc-filter wrapper instead of winegcc in DLL Makefiles
    find dlls -name Makefile | xargs sed -i \
        -e 's|\(^WINEGCC = .*/\)winegcc\(\.exe\)\{0,1\}[[:space:]]|\1winegcc-filter |' \
        -e 's|\(^WINEGCC = .*/\)winegcc\(\.exe\)\{0,1\}$|\1winegcc-filter|'

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

    # Stub shimgdata.h for Wine 4.x/5.x uuid build
    if [ -f dlls/uuid/uuid.c ] && ! [ -f dlls/shell32/shimgdata.h ]; then
        mkdir -p dlls/shell32
        echo '/* stub - not needed for D3D DLLs */' > dlls/shell32/shimgdata.h
    fi

    # Create stub libwine.a (no runtime dependency on libwine.dll)
    rm -f libs/wine/libwine.dll.a libs/wine/libwine.dll
    # Nuke any libwine.dll.a anywhere in the tree AND system dirs
    # (winegcc's add_library resolves "wine" by searching for libwine.dll.a
    # first — if found, it generates a DLL import entry via winebuild)
    find . -name 'libwine.dll.a' -delete 2>/dev/null
    find . -name 'libwine.dll' -delete 2>/dev/null
    rm -f /mingw32/lib/libwine.dll.a /mingw32/lib/libwine.dll 2>/dev/null
    create_stub_libwine

    # Neuter libs/wine/Makefile to prevent regeneration of libwine.dll.a
    # during the DLL build phase (make -C dlls/wined3d could trigger it).
    if [ -d libs/wine ] && [ -f libs/wine/wine-stubs.a ]; then
        printf 'all:\nlibwine.a:\ninstall clean distclean:\n' > libs/wine/Makefile
    fi

    # Nuke libwine.dll.a from ALL possible search paths — GCC and MinGW
    # have multiple library directories, and the linker finds the import
    # library if any of them contain libwine.dll.a.
    for d in /mingw32/lib \
             /mingw32/i686-w64-mingw32/lib \
             /mingw32/i686-w64-mingw32/sys-root/mingw/lib; do
        rm -f "$d/libwine.dll.a" "$d/libwine.dll" 2>/dev/null || true
    done
    for d in /mingw32/lib/gcc/i686-w64-mingw32/*/; do
        rm -f "$d/libwine.dll.a" "$d/libwine.dll" 2>/dev/null || true
    done

    # Remove libwine from IMPORTS — this prevents winegcc from passing
    # --import libwine to winebuild, which embeds a PE import table entry
    # for libwine.dll in the .spec.o file.  The stub libwine.a still
    # provides all needed symbols via direct static linking.
    # Handle both "libwine" (Wine 4.x+) and "wine" (Wine 1.x-3.x).
    # Use trailing-space/end-of-line anchors to avoid matching "wine"
    # inside "wined3d".
    find dlls -name Makefile | xargs sed -i \
        -e '/^IMPORTS[[:space:]]*=/s/[[:space:]]libwine\([[:space:]]\|$\)//g' \
        -e '/^IMPORTS[[:space:]]*=/s/[[:space:]]wine\([[:space:]]\|$\)//g'

    # Replace -lwine with wine-stubs.a path (no "lib" prefix — avoids winegcc
    # Windows-path converting lib*.a back to -lwine)
    find dlls -name Makefile | xargs sed -i \
        -e 's/-lwine /..\/..\/libs\/wine\/wine-stubs.a /g' \
        -e 's/-lwine$/..\/..\/libs\/wine\/wine-stubs.a/g'

    echo "    Building import libs and DLLs..."
    # Final sweep: nuke any libwine.dll.a regenerated during earlier build steps
    find . -name 'libwine.dll.a' -delete 2>/dev/null
    find . -name 'libwine.dll' -delete 2>/dev/null
    make -j"$NPROC" -C dlls/winecrt0

    # Re-strip CRT from ntdll.spec right before import lib generation.
    # Earlier make steps may have regenerated specs from .spec.in.
    for spec in dlls/ntdll/ntdll.spec; do
        [ -f "$spec" ] || continue
        sed -i -e '/^@.*\bfloor\b/d' -e '/^@.*\bceil\b/d' -e '/^@.*\bfabs\b/d' \
               -e '/^@.*\bsqrt\b/d' -e '/^@.*\bsin\b/d' -e '/^@.*\bcos\b/d' \
               -e '/^@.*\btan\b/d' -e '/^@.*\batan\b/d' -e '/^@.*\batan2\b/d' \
               -e '/^@.*\bmodf\b/d' -e '/^@.*\bldexp\b/d' \
               -e '/^@.*\bexp\b/d' -e '/^@.*\blog\b/d' -e '/^@.*\bpow\b/d' \
               -e '/^@.*\bsprintf\b/d' -e '/^@.*\bmemcpy\b/d' \
               -e '/^@.*\bstrlen\b/d' -e '/^@.*\bmemset\b/d' -e '/^@.*\bstrcmp\b/d' \
               -e '/^@.*\bmemcpy\b/d' -e '/^@.*\bstrcpy\b/d' -e '/^@.*\bstrcat\b/d' \
               "$spec"
        echo "    Re-stripped math/CRT from $spec before import lib generation"
    done

    # Re-strip Win2000+ user32 W-version display functions from user32.spec.
    # These functions don't exist on Win98 — only A-versions are available.
    for spec in dlls/user32/user32.spec; do
        [ -f "$spec" ] || continue
        sed -i -e '/EnumDisplayDevicesW/d' \
               -e '/EnumDisplaySettingsExW/d' \
               -e '/EnumDisplaySettingsW/d' \
               -e '/EnumDisplayMonitors/d' \
               -e '/MonitorFromPoint/d' \
               "$spec"
        echo "    Re-stripped Win2000+ user32 funcs from $spec before import lib generation"
    done

    # Generate all import libs needed by wined3d/d3d9/d3d8/ddraw
    generate_import_libs

    # Strip CRT functions from Wine-generated ntdll import lib.
    # configure restores ntdll.spec from .spec.in, so sed stripping
    # before configure doesn't stick. Use per-object approach because
    # objcopy on whole Wine archives silently fails on MSYS2.
    local strip_legacy_ntdll=()
    for api in memcmp memchr \
               _stricmp _strnicmp \
               sprintf vsprintf snprintf vsnprintf sscanf fprintf vfprintf \
               memcpy memset memmove \
               strlen strcpy strcat strcmp strncmp strchr strstr strrchr strcspn strnlen \
               tolower toupper strtol strtoul qsort bsearch \
               pow exp log \
               floor ceil fabs sqrt sin cos tan atan atan2 modf ldexp \
               rand srand abort \
               fopen fclose fgets fputc fread fwrite clearerr feof ferror \
               getc ungetc \
               atoi atol abs \
               isprint isdigit isalpha isalnum isspace isupper islower isxdigit iscntrl isgraph ispunct \
               _initterm _initterm_e; do
        strip_legacy_ntdll+=(--strip-symbol "${api}" --strip-symbol "__imp__${api}")
    done
    local _leg_ntdll_curdir="$(pwd)"
    for lib in dlls/ntdll/libntdll.a; do
        [ -f "$lib" ] || continue
        local _leg_ntdll_tmpdir="${TMPDIR:-/tmp}/strip_legacy_ntdll_$$_$(date +%s)"
        mkdir -p "$_leg_ntdll_tmpdir"
        cd "$_leg_ntdll_tmpdir"
        if ar x "$_leg_ntdll_curdir/$lib" 2>/dev/null; then
            for obj in *.o; do
                [ -f "$obj" ] || continue
                objcopy "${strip_legacy_ntdll[@]}" "$obj" 2>/dev/null || true
            done
            rm -f "$_leg_ntdll_curdir/$lib"
            local _first=1
            for obj in *.o; do
                [ -f "$obj" ] || continue
                if [ "$_first" = 1 ]; then ar cr "$_leg_ntdll_curdir/$lib" "$obj"; _first=0; else ar q "$_leg_ntdll_curdir/$lib" "$obj"; fi
            done
            echo "    Stripped CRT from Wine ntdll import lib (per-object)"
        fi
        rm -rf "$_leg_ntdll_tmpdir"
        cd "$_leg_ntdll_curdir"
    done

    # Strip Vista+ kernel32 APIs from Wine-generated kernel32 import lib.
    # The spec stripping may not stick if make regenerates from .spec.in.
    local strip_legacy_k32=()
    for api in \
        GetModuleHandleExW@12 GlobalMemoryStatusEx@4 \
        RtlIsCriticalSectionLockedByThread@4 \
        InitOnceExecuteOnce@16 \
        InitOnceBeginInitialize@16 InitOnceComplete@12 InitOnceInitialize@4 \
        InitializeSRWLock@4 \
        AcquireSRWLockExclusive@4 AcquireSRWLockShared@4 \
        ReleaseSRWLockExclusive@4 ReleaseSRWLockShared@4 \
        TryAcquireSRWLockExclusive@4 TryAcquireSRWLockShared@4 \
        InitializeConditionVariable@4 \
        WakeConditionVariable@4 WakeAllConditionVariable@4 \
        SleepConditionVariableCS@12 SleepConditionVariableSRW@16 \
        GetTickCount64@0 \
        SetThreadDescription@8 \
        IsBadStringPtrW@8 FreeLibraryAndExitThread@8; do
        strip_legacy_k32+=(--strip-symbol "_${api}" --strip-symbol "__imp__${api}")
    done
    for lib in dlls/kernel32/libkernel32.a; do
        [ -f "$lib" ] || continue
        local tmp="${TMPDIR:-/tmp}/strip_legacy_k32_$$_$(date +%s).a"
        if objcopy "${strip_legacy_k32[@]}" "$lib" "$tmp" 2>/dev/null && [ -f "$tmp" ]; then
            mv "$tmp" "$lib"
            echo "    Stripped Vista+ APIs from Wine-generated kernel32 import lib"
        else
            rm -f "$tmp"
        fi
    done

    # Inject __imp__IsBadStringPtrW@8 redirect (→ IsBadStringPtrA@8) into
    # Wine's in-tree kernel32 import lib. IsBadStringPtrW was stripped above
    # but Wine code still references it. The redirect was already injected into
    # system libkernel32.a by create_ucrtcompat(), but winegcc links against
    # Wine's own import libs first.
    local _ibspw_o="${TMPDIR:-/tmp}/ibspw_compat.o"
    for lib in dlls/kernel32/libkernel32.a; do
        [ -f "$lib" ] && [ -f "$_ibspw_o" ] && ar rs "$lib" "$_ibspw_o" 2>/dev/null && \
            echo "    Injected ibspw_compat into Wine kernel32 import lib"
    done

    # Strip Win2000+ user32 W-version display functions from Wine-generated
    # user32 import lib. Spec stripping may not stick after make regenerates.
    local strip_legacy_user32=()
    for api in \
        EnumDisplayDevicesW@16 EnumDisplaySettingsExW@16 \
        EnumDisplaySettingsW@12 \
        EnumDisplayMonitors@16 MonitorFromPoint@12 \
        ChangeDisplaySettingsExW@20; do
        strip_legacy_user32+=(--strip-symbol "_${api}" --strip-symbol "__imp__${api}")
    done
    for lib in dlls/user32/libuser32.a; do
        [ -f "$lib" ] || continue
        local tmp="${TMPDIR:-/tmp}/strip_legacy_user32_$$_$(date +%s).a"
        if objcopy "${strip_legacy_user32[@]}" "$lib" "$tmp" 2>/dev/null && [ -f "$tmp" ]; then
            mv "$tmp" "$lib"
            echo "    Stripped Win2000+ user32 funcs from Wine-generated user32 import lib"
        else
            rm -f "$tmp"
        fi
    done

    # Strip UCRT-specific functions from Wine-generated msvcrt import lib.
    # Wine 6.x builds custom msvcrt.dll with __stdio_common_vsprintf etc.
    # These are UCRT functions not in Win98's msvcrt.dll.  Our kernel32_compat.c
    # provides local stubs — strip from import lib so the linker uses them.
    local strip_legacy_crt=()
    for api in __stdio_common_vsprintf __stdio_common_vfprintf __stdio_common_vsscanf; do
        strip_legacy_crt+=(--strip-symbol "${api}" --strip-symbol "__imp__${api}")
    done
    for lib in dlls/msvcrt/libmsvcrt.a; do
        [ -f "$lib" ] || continue
        local tmp="${TMPDIR:-/tmp}/strip_legacy_crt_$$_$(date +%s).a"
        if objcopy "${strip_legacy_crt[@]}" "$lib" "$tmp" 2>/dev/null && [ -f "$tmp" ]; then
            mv "$tmp" "$lib"
            echo "    Stripped UCRT/CRT stubs from Wine msvcrt import lib"
        else
            rm -f "$tmp"
        fi
    done

    # Build uuid/dxguid — fall back to system libs on header errors or if
    # directory doesn't exist (restructured in Wine 7+)
    if [ -d dlls/uuid ]; then
        if ! make -C dlls/uuid 2>/dev/null; then
            echo "    uuid build failed, using system libuuid"
            cp /mingw32/lib/libuuid.a dlls/uuid/ 2>/dev/null || true
        fi
    else
        mkdir -p dlls/uuid
        cp /mingw32/lib/libuuid.a dlls/uuid/ 2>/dev/null || true
    fi
    if [ -d dlls/dxguid ]; then
        make -C dlls/dxguid 2>/dev/null || {
            echo "    dxguid build failed, using system libdxguid"
            cp /mingw32/lib/libdxguid.a dlls/dxguid/ 2>/dev/null || true
        }
    else
        mkdir -p dlls/dxguid
        cp /mingw32/lib/libdxguid.a dlls/dxguid/ 2>/dev/null || true
    fi

    make -j"$NPROC" -C dlls/wined3d
    tools/winebuild/winebuild \
        -w --implib \
        -o dlls/wined3d/libwined3d.a \
        --export dlls/wined3d/wined3d.spec

    for dll in d3d9 d3d8 ddraw; do
        make -j"$NPROC" -C "dlls/$dll" "$dll.dll"
    done

    if [ "$build_msvcrt" = "1" ]; then
        patch_msvcrt_6x
        make -j"$NPROC" -C dlls/msvcrt msvcrt.dll
    fi

    # Final sweep: nuke any libwine.dll/libwine.dll.a regenerated during build
    find . -name 'libwine.dll.a' -delete 2>/dev/null
    find . -name 'libwine.dll' -delete 2>/dev/null
}

# ── Generate import libs via winebuild ──────────────────────────────
generate_import_libs() {
    # wined3d/d3d9/d3d8/ddraw link against system DLLs.
    # Generate import libs from spec files for any that are missing.
    local sys_dlls=(user32 gdi32 advapi32 kernel32 opengl32 ntdll setupapi msvcrt)
    for dll in "${sys_dlls[@]}"; do
        local spec="dlls/$dll/$dll.spec"
        local implib="dlls/$dll/lib$dll.a"
        if [ -f "$spec" ] && [ ! -f "$implib" ]; then
            mkdir -p "dlls/$dll"
            tools/winebuild/winebuild \
                -w --implib -o "$implib" --export "$spec" || true
        fi
    done
}

# ── Stub libwine.a ──────────────────────────────────────────────────
create_stub_libwine() {
    echo "    Creating stub libwine.a..."
    local tmpdir="${TMPDIR:-/tmp}"
    cat > "$tmpdir/libwine_stubs.c" << 'STUBEOF'
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
const char *wine_dbgstr_an(const char *s,int n){return s?"":"";}
const char *wine_dbgstr_wn(const wchar_t *s,int n){return s?"":"";}
const char *wine_get_version(void){return "wine-stubs";}
const char *wine_get_config_dir(void){return "";}
const char *wine_get_data_dir(void){return "";}
static unsigned short _cmap[128];
unsigned short *wine_casemap_ascii=_cmap;
unsigned short wine_tolower(unsigned short c){return(c>=65&&c<=90)?c+32:c;}
unsigned short wine_toupper(unsigned short c){return(c>=97&&c<=122)?c-32:c;}
STUBEOF
    gcc -c -O2 -o "$tmpdir/libwine_stubs.o" "$tmpdir/libwine_stubs.c"

    # Name WITHOUT "lib" prefix — winegcc's Windows platform code converts
    # archive paths matching lib*.a back to -L/-l form, undoing our replacement.
    # "wine-stubs.a" bypasses strncmp(p,"lib",3) and gets linked directly.
    ar cr libs/wine/wine-stubs.a "$tmpdir/libwine_stubs.o"
    # Keep libwine.a as a copy so make dependencies don't trigger a rebuild
    cp libs/wine/wine-stubs.a libs/wine/libwine.a
}

# ── Patch msvcrt for Wine 6.x ──────────────────────────────────────
patch_msvcrt_6x() {
    # IsBadStringPtrW was stripped from kernel32/ntdll specs (Win2K+ only).
    # msvcrt.dll uses it via __declspec(dllimport) which bypasses #define
    # redirects. Inject the __imp__ redirect into ntdll's import lib (which
    # msvcrt links against) so the linker finds it.
    local _ibspw_o="${TMPDIR:-/tmp}/ibspw_compat.o"
    for lib in dlls/ntdll/libntdll.a; do
        [ -f "$lib" ] && [ -f "$_ibspw_o" ] && ar rs "$lib" "$_ibspw_o" 2>/dev/null && \
            echo "    Injected ibspw_compat into Wine ntdll import lib (for msvcrt)"
    done

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

# ── Patch PE headers for Windows 98 ────────────────────────────────
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

# ── Collect output DLLs ─────────────────────────────────────────────
collect_output() {
    local version=$1 build_msvcrt=$2 srcdir=$3 mode=$4
    local wine_src="$srcdir/wine-${version}"
    local outdir="$OUTPUT_BASE/$version"

    mkdir -p "$outdir"

    if [ "$mode" = "modern" ]; then
        # Modern PE mode: auto-detect output path (i386-windows/ or direct)
        local d3d_dlls=(wined3d d3d9 d3d8 ddraw)
        for dll in "${d3d_dlls[@]}"; do
            local src=""
            if [ -f "$wine_src/dlls/$dll/i386-windows/$dll.dll" ]; then
                src="$wine_src/dlls/$dll/i386-windows/$dll.dll"
            elif [ -f "$wine_src/dlls/$dll/$dll.dll" ]; then
                src="$wine_src/dlls/$dll/$dll.dll"
            fi
            if [ -n "$src" ]; then
                cp -v "$src" "$outdir/"
            else
                echo "    WARNING: $dll.dll not found"
            fi
        done
        if [ "$build_msvcrt" = "1" ]; then
            local msvcrt_src=""
            if [ -f "$wine_src/dlls/msvcrt/i386-windows/msvcrt.dll" ]; then
                msvcrt_src="$wine_src/dlls/msvcrt/i386-windows/msvcrt.dll"
            elif [ -f "$wine_src/dlls/msvcrt/msvcrt.dll" ]; then
                msvcrt_src="$wine_src/dlls/msvcrt/msvcrt.dll"
            fi
            if [ -n "$msvcrt_src" ]; then
                cp -v "$msvcrt_src" "$outdir/"
            fi
        fi
    else
        # Legacy mode outputs to dlls/xxx/xxx.dll
        cp -v \
            "$wine_src/dlls/wined3d/wined3d.dll" \
            "$wine_src/dlls/d3d9/d3d9.dll" \
            "$wine_src/dlls/d3d8/d3d8.dll" \
            "$wine_src/dlls/ddraw/ddraw.dll" \
            "$outdir/"
        if [ "$build_msvcrt" = "1" ]; then
            cp -v "$wine_src/dlls/msvcrt/msvcrt.dll" "$outdir/"
        fi
    fi

    # Patch any remaining ucrtbase.dll imports → msvcrt.dll
    patch_ucrt_imports "$outdir"

    # Patch PE headers for Windows 98 compatibility:
    # Set Subsystem=2 (GUI) and SubsystemVersion=4.10 (Win98).
    # MinGW defaults to Subsystem=3 (CONSOLE) and SubsystemVersion=0.32
    # which may trigger Win98 kernel32 PE loader bugs.
    patch_pe_win98 "$outdir"

    printf "Built on %s\n" "$(date '+%T %b %-e %Y')" > "$outdir/build-timestamp"
    chmod +x "$outdir/build-timestamp"
}

# ── Main build loop ─────────────────────────────────────────────────
main() {
    echo "=== Wine D3D DLL Builder (MSYS2 CI mode) ==="
    echo ""

    local srcdir="$SCRIPT_DIR/src"
    mkdir -p "$srcdir"

    local pass=0 fail=0 skip=0

    for entry in "${VERSIONS[@]}"; do
        IFS=: read -r WINE_VERSION WINE_BRANCH WINE_EXT BUILD_MSVCRT BUILD_MODE <<< "$entry"

        # Apply version filter
        if [[ ${#FILTER_VERSIONS[@]} -gt 0 ]]; then
            local match=0
            for fv in "${FILTER_VERSIONS[@]}"; do
                [[ "$fv" == "$WINE_VERSION" ]] && match=1 && break
            done
            [[ $match -eq 0 ]] && continue
        fi

        # Skip already-built
        if [[ $FORCE -eq 0 ]] && [[ -f "$OUTPUT_BASE/$WINE_VERSION/wined3d.dll" ]]; then
            echo "=== Skipping Wine $WINE_VERSION (already built — use --force to rebuild) ==="
            ((skip++)) || true
            continue
        fi

        echo "=== Building Wine $WINE_VERSION ($BUILD_MODE) ==="

        download_wine "$WINE_VERSION" "$WINE_BRANCH" "$WINE_EXT" "$srcdir"
        extract_wine "$WINE_VERSION" "$WINE_EXT" "$srcdir"

        case "$BUILD_MODE" in
            modern) build_modern "$srcdir" "$WINE_VERSION" "$BUILD_MSVCRT" ;;
            legacy) build_legacy "$srcdir" "$WINE_VERSION" "$BUILD_MSVCRT" ;;
        esac

        collect_output "$WINE_VERSION" "$BUILD_MSVCRT" "$srcdir" "$BUILD_MODE"

        if [[ -f "$OUTPUT_BASE/$WINE_VERSION/wined3d.dll" ]]; then
            echo "    Done: $(ls "$OUTPUT_BASE/$WINE_VERSION/")"
            ((pass++)) || true
        else
            echo "    FAILED: wined3d.dll not found"
            ((fail++)) || true
        fi
        echo ""
    done

    echo "=== Summary ==="
    for entry in "${VERSIONS[@]}"; do
        IFS=: read -r WINE_VERSION _ <<< "$entry"
        if [[ ${#FILTER_VERSIONS[@]} -gt 0 ]]; then
            local match=0
            for fv in "${FILTER_VERSIONS[@]}"; do
                [[ "$fv" == "$WINE_VERSION" ]] && match=1 && break
            done
            [[ $match -eq 0 ]] && continue
        fi

        if [[ -f "$OUTPUT_BASE/$WINE_VERSION/wined3d.dll" ]]; then
            echo "  [ok] $WINE_VERSION"
        else
            echo "  [FAIL] $WINE_VERSION"
        fi
    done
    echo ""
    echo "  Passed: $pass  Failed: $fail  Skipped: $skip"
    echo "  Output: $OUTPUT_BASE/"

    if [[ $fail -gt 0 ]]; then
        exit 1
    fi
}

main
