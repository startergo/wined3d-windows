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
    for archive in /mingw32/lib/libmingwex.a \
                   /mingw32/lib/gcc/i686-w64-mingw32/*/libgcc.a \
                   /mingw32/lib/gcc/i686-w64-mingw32/*/libgcc_eh.a; do
        if [ -f "$archive" ]; then
            local tmpdir="${TMPDIR:-/tmp}/objcopy_$$_$(basename "$archive")"
            mkdir -p "$tmpdir"
            cd "$tmpdir"
            ar x "$archive"
            for obj in *.o; do
                objcopy --redefine-sym ___acrt_iob_func=___iob_func "$obj" 2>/dev/null || true
            done
            ar cr "$archive" *.o
            rm -rf "$tmpdir"
            cd "$curdir"
        fi
    done
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
FILE * __cdecl __acrt_iob_func(_uint i){ return (char*)__iob_func()+i*32; }
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
UCRTEOF
    gcc -nostdinc -c -O2 -Wno-attributes -o "$tmpdir/ucrtcompat.o" "$tmpdir/ucrtcompat.c"
    ar rs /mingw32/lib/libmsvcrt.a "$tmpdir/ucrtcompat.o"
    # Inject floorf-only object into libgcc.a for Wine 8.x PE builds.
    # Wine 8.x links via -static-libgcc (searches libgcc.a) but uses
    # Wine-generated import libs, not the system libmsvcrt.a where the
    # UCRT stubs live.  Use a separate object to avoid multiple-definition
    # errors with __acrt_iob_func (already in both libmsvcrt.a and libgcc.a).
    cat > "$tmpdir/floorf_compat.c" << 'FLOORFEOF'
double __cdecl floor(double);
float __cdecl floorf(float x){ return (float)floor((double)x); }
FLOORFEOF
    gcc -nostdinc -c -O2 -Wno-attributes -o "$tmpdir/floorf_compat.o" "$tmpdir/floorf_compat.c"
    for gcc_lib in /mingw32/lib/gcc/i686-w64-mingw32/*/libgcc.a; do
        [ -f "$gcc_lib" ] && ar rs "$gcc_lib" "$tmpdir/floorf_compat.o"
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
    sed -i 's/^C_SRCS\s*=/C_SRCS = d3dkmt_stubs.c /' dlls/wined3d/Makefile.in

    # qemu-3dfx passthrough hooks — inject into wined3d for HAL enumeration
    # and passthrough device detection (\\.\QEMUchs).
    if [ -f "$SCRIPT_DIR/qemu3dfx_hooks.c" ]; then
        echo "    Injecting qemu-3dfx passthrough hooks..."
        cp "$SCRIPT_DIR/qemu3dfx_hooks.c" dlls/wined3d/qemu3dfx_hooks.c
        sed -i 's/^C_SRCS\s*=/C_SRCS = qemu3dfx_hooks.c /' dlls/wined3d/Makefile.in
        # Add exports to spec file
        if [ -f dlls/wined3d/wined3d.spec ]; then
            cat >> dlls/wined3d/wined3d.spec << 'SPECEOF'

# qemu-3dfx passthrough hooks
@ stdcall wined3d_hal_3dfx()
@ stdcall wined3d_enum_hal_last()
@ stdcall wined3d_surface_ddheap()
@ stdcall wined3d_passthru(ptr)
@ stdcall wined3d_override_cooplevel(ptr)
@ stdcall wined3d_override_rendertarget_view(ptr)
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
               "$spec"
    done
    echo "    Stripped Vista+ APIs and CRT from kernel32/ntdll specs"

    # Strip SetThreadDescription from kernel32.spec (Windows 10+)
    for spec in dlls/kernel32/kernel32.spec; do
        [ -f "$spec" ] || continue
        sed -i -e '/SetThreadDescription/d' "$spec"
    done
    echo "    Stripped Vista+ APIs and CRT from kernel32/ntdll specs"

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
        SetThreadDescription@8; do
        strip_syms+=(--strip-symbol "_${api}" --strip-symbol "__imp__${api}")
    done
    # ntdll CRT functions (cdecl, no @N suffix) — resolve from msvcrt instead
    for api in _snprintf _strnicmp _vsnprintf _stricmp \
               sprintf vsprintf snprintf vsnprintf sscanf \
               memcpy memset memmove memcmp \
               strlen strcpy strcat strcmp strncmp strchr strstr strrchr \
               tolower toupper atoi atol strtol qsort bsearch; do
        strip_syms+=(--strip-symbol "${api}" --strip-symbol "__imp__${api}")
    done

    for lib in /mingw32/lib/libkernel32.a \
               /mingw32/i686-w64-mingw32/lib/libkernel32.a \
               /mingw32/lib/libntdll.a \
               /mingw32/i686-w64-mingw32/lib/libntdll.a; do
        [ -f "$lib" ] || continue
        local tmp="${TMPDIR:-/tmp}/strip_$$_$(date +%s).a"
        if objcopy "${strip_syms[@]}" "$lib" "$tmp" 2>/dev/null && [ -f "$tmp" ]; then
            mv "$tmp" "$lib"
            echo "    Stripped Vista+ symbols from $lib"
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
        SetThreadDescription@8; do
        strip_all+=(--strip-symbol "_${api}" --strip-symbol "__imp__${api}")
    done
    # CRT we stub locally — strip from ALL Wine import libs including ntdll
    for api in _snprintf _strnicmp _vsnprintf \
               atoi atol abs \
               isprint isdigit isalpha isalnum isspace isupper islower isxdigit iscntrl isgraph ispunct \
               __acrt_iob_func; do
        strip_all+=(--strip-symbol "${api}" --strip-symbol "__imp__${api}")
    done
    # Basic CRT that Win98 ntdll HAS — only strip from ucrtbase/msvcrt
    # to avoid multiple-definition with our stubs. Do NOT strip from ntdll.
    local strip_crtlib=()
    for api in _stricmp \
               sprintf vsprintf snprintf vsnprintf sscanf \
               memcpy memset memmove memcmp \
               strlen strcpy strcat strcmp strncmp strchr strstr strrchr \
               tolower toupper strtol qsort bsearch; do
        strip_crtlib+=(--strip-symbol "${api}" --strip-symbol "__imp__${api}")
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
        dlls/msvcrt/libmsvcrt.a; do
        [ -f "$lib" ] || continue
        local tmp="${TMPDIR:-/tmp}/strip_wine_$$_$(date +%s).a"
        if objcopy "${strip_all[@]}" "$lib" "$tmp" 2>/dev/null && [ -f "$tmp" ]; then
            mv "$tmp" "$lib"
            echo "    Stripped Vista+ symbols from Wine $lib"
        else
            rm -f "$tmp"
        fi
    done
    # Basic CRT: strip from ucrtbase/msvcrt only (avoid multiple-def with our stubs)
    for lib in \
        dlls/ucrtbase/i386-windows/libucrtbase.a \
        dlls/ucrtbase/libucrtbase.a \
        dlls/msvcrt/i386-windows/libmsvcrt.a \
        dlls/msvcrt/libmsvcrt.a; do
        [ -f "$lib" ] || continue
        local tmp="${TMPDIR:-/tmp}/strip_crtlib_$$_$(date +%s).a"
        if objcopy "${strip_crtlib[@]}" "$lib" "$tmp" 2>/dev/null && [ -f "$tmp" ]; then
            mv "$tmp" "$lib"
            echo "    Stripped CRT symbols from Wine $lib"
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
    for dll in wined3d d3d9 d3d8 ddraw; do
        local mf="dlls/$dll/Makefile.in"
        [ -f "$mf" ] || continue
        cat > "dlls/$dll/kernel32_compat.c" << 'K32EOF'
/* Win98-compatible stubs for Vista+/Win2000+ kernel32/ntdll APIs.
   Each provides the function + __imp__ pointer for __declspec(dllimport). */
typedef unsigned long DWORD;
typedef unsigned long long DWORD64;
typedef unsigned short WCHAR;
typedef const WCHAR *LPCWSTR;
typedef unsigned long ULONG_PTR;
typedef void *HMODULE;
typedef int BOOL;
#ifndef __stdcall
#define __stdcall __attribute__((stdcall))
#endif

/* --- GetModuleHandleExW (Vista+) ---
   Uses VirtualQuery (Win95+) for FROM_ADDRESS, GetModuleHandleA for name. */
#define GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS 0x4
HMODULE __stdcall GetModuleHandleA(const char *);
typedef struct { void *BaseAddress; void *AllocationBase; DWORD Partition; DWORD RegionSize; DWORD State; DWORD Protect; DWORD Type; } MBINFO;
DWORD __stdcall VirtualQuery(const void *, MBINFO *, DWORD);
BOOL __stdcall GetModuleHandleExW(DWORD flags, LPCWSTR name, HMODULE *module)
{
    if(!module) return 0;
    if(flags & GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS) {
        MBINFO mbi;
        if(VirtualQuery((const void *)name, &mbi, sizeof(mbi)))
            { *module = (HMODULE)mbi.AllocationBase; return 1; }
        return 0;
    }
    if(!name) { *module = (HMODULE)0x400000; return 1; }
    { char buf[260]; int i; for(i=0; i<259 && name[i]; i++) buf[i]=(char)name[i]; buf[i]=0;
      *module = GetModuleHandleA(buf); }
    return *module != 0;
}

/* --- GlobalMemoryStatusEx (Win2000+) ---
   Falls back to GlobalMemoryStatus (Win95+). */
typedef struct { DWORD dwLength; DWORD dwMemoryLoad; DWORD dwTotalPhys; DWORD dwAvailPhys;
  DWORD dwTotalPageFile; DWORD dwAvailPageFile; DWORD dwTotalVirtual; DWORD dwAvailVirtual; } MEMSTATUS;
typedef struct { DWORD dwLength; DWORD dwMemoryLoad; DWORD64 ullTotalPhys; DWORD64 ullAvailPhys;
  DWORD64 ullTotalPageFile; DWORD64 ullAvailPageFile; DWORD64 ullTotalVirtual; DWORD64 ullAvailVirtual;
  DWORD64 ullAvailExtendedVirtual; } MEMSTATUSEX;
void __stdcall GlobalMemoryStatus(MEMSTATUS *);
BOOL __stdcall GlobalMemoryStatusEx(MEMSTATUSEX *lpBuffer)
{
    MEMSTATUS ms; ms.dwLength = sizeof(ms);
    GlobalMemoryStatus(&ms);
    lpBuffer->dwLength = sizeof(*lpBuffer);
    lpBuffer->dwMemoryLoad = ms.dwMemoryLoad;
    lpBuffer->ullTotalPhys = ms.dwTotalPhys;
    lpBuffer->ullAvailPhys = ms.dwAvailPhys;
    lpBuffer->ullTotalPageFile = ms.dwTotalPageFile;
    lpBuffer->ullAvailPageFile = ms.dwAvailPageFile;
    lpBuffer->ullTotalVirtual = ms.dwTotalVirtual;
    lpBuffer->ullAvailVirtual = ms.dwAvailVirtual;
    lpBuffer->ullAvailExtendedVirtual = 0;
    return 1;
}

/* --- RtlIsCriticalSectionLockedByThread (Vista+) ---
   Checks if the critical section is owned by the calling thread. */
typedef struct _RTL_CRITICAL_SECTION { void *DebugInfo; long LockCount; long RecursionCount; void *OwningThread; void *LockSemaphore; DWORD SpinCount; } CRITSEC;
DWORD __stdcall GetCurrentThreadId(void);
BOOL __stdcall RtlIsCriticalSectionLockedByThread(CRITSEC *cs)
{
    return cs && cs->OwningThread == (void *)(ULONG_PTR)GetCurrentThreadId() && cs->RecursionCount > 0;
}

/* --- InitOnceExecuteOnce (Vista+) ---
   One-time initialization. Just call the init function immediately. */
typedef long BOOL_CALL_ONCE(void *, void **);
BOOL __stdcall InitOnceExecuteOnce(void *init_once, BOOL_CALL_ONCE *init_fn, void *param, void **context)
{
    if(init_fn) return init_fn(param, context ? context : (void **)init_once);
    return 1;
}

/* --- ConditionVariable family (Vista+) ---
   Used by vkd3d (Vulkan). No-ops — vkd3d won't function without Vulkan anyway. */
typedef struct _CONDITION_VARIABLE { void *Ptr; } CONDITION_VARIABLE;
void __stdcall InitializeConditionVariable(CONDITION_VARIABLE *cv) { if(cv) cv->Ptr = 0; }
void __stdcall WakeConditionVariable(CONDITION_VARIABLE *cv) { }
void __stdcall WakeAllConditionVariable(CONDITION_VARIABLE *cv) { }
unsigned long __stdcall SleepConditionVariableCS(CONDITION_VARIABLE *cv, CRITSEC *cs, unsigned long ms) { return 0; }

/* --- SetThreadDescription (Windows 10+) ---
   Sets a descriptive string for a thread. No-op on Win98. */
typedef long HRESULT;
typedef void *HANDLE;
typedef const unsigned short *PCWSTR;
HRESULT __stdcall SetThreadDescription(HANDLE hThread, PCWSTR lpThreadDescription) { return 0; }

/* --- ntdll CRT stubs (not available on Win98 ntdll.dll) ---
   Wine imports these from ntdll but Win98's ntdll is minimal.
   No-op stubs + __imp__ pointers for __declspec(dllimport) callers.
   Debug output is suppressed by stub __wine_dbg_get_channel_flags(=0)
   so _vsnprintf/_snprintf are never called with real data. */
int __cdecl _strnicmp(const char *s1, const char *s2, unsigned int n)
{
    if(!n) return 0;
    for(; n--; s1++, s2++) {
        unsigned char c1 = (unsigned char)*s1, c2 = (unsigned char)*s2;
        if(c1 >= 'A' && c1 <= 'Z') c1 += 32;
        if(c2 >= 'A' && c2 <= 'Z') c2 += 32;
        if(c1 != c2) return (int)c1 - (int)c2;
        if(!c1) return 0;
    }
    return 0;
}
int __cdecl _vsnprintf(char *buf, unsigned int size, const char *fmt, ...)
{
    return 0;
}
int __cdecl _snprintf(char *buf, unsigned int size, const char *fmt, ...)
{
    return 0;
}

/* --- Standard C library (normally from ntdll, not on Win98) --- */
int __cdecl atoi(const char *s)
{
    int n = 0, neg = 0;
    while (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r') s++;
    if (*s == '-') { neg = 1; s++; } else if (*s == '+') s++;
    while (*s >= '0' && *s <= '9') { n = n * 10 + (*s - '0'); s++; }
    return neg ? -n : n;
}
long __cdecl atol(const char *s) { return (long)atoi(s); }
int __cdecl abs(int n) { return n < 0 ? -n : n; }
int __cdecl isprint(int c) { return c >= 32 && c < 127; }
int __cdecl isdigit(int c) { return c >= '0' && c <= '9'; }
int __cdecl isalpha(int c) { return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'); }
int __cdecl isalnum(int c) { return isalpha(c) || isdigit(c); }
int __cdecl isspace(int c) { return c == ' ' || (c >= 9 && c <= 13); }
int __cdecl isupper(int c) { return c >= 'A' && c <= 'Z'; }
int __cdecl islower(int c) { return c >= 'a' && c <= 'z'; }
int __cdecl isxdigit(int c) { return isdigit(c) || (c >= 'A' && c <= 'F') || (c >= 'a' && c <= 'f'); }
int __cdecl iscntrl(int c) { return (c >= 0 && c <= 31) || c == 127; }
int __cdecl isgraph(int c) { return c > 32 && c < 127; }
int __cdecl ispunct(int c) { return isgraph(c) && !isalnum(c); }

/* --- __acrt_iob_func (UCRT, not in Win98 msvcrt.dll) ---
   Returns a dummy FILE slot — debug output is suppressed anyway. */
static char _dummy_iob[96];
void * __cdecl __acrt_iob_func(unsigned int i) { return (i < 3) ? _dummy_iob + i * 32 : 0; }

/* --- __imp__ pointers for __declspec(dllimport) callers --- */
__asm__("\n"
    ".globl __imp__GetModuleHandleExW@12\n"
    ".section .rdata,\"dr\"\n"
    ".align 4\n"
    "__imp__GetModuleHandleExW@12:\n"
    "    .long _GetModuleHandleExW@12\n"
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
    ".globl __imp___strnicmp\n"
    ".align 4\n"
    "__imp___strnicmp:\n"
    "    .long __strnicmp\n"
    ".globl __imp___vsnprintf\n"
    ".align 4\n"
    "__imp___vsnprintf:\n"
    "    .long __vsnprintf\n"
    ".globl __imp___snprintf\n"
    ".align 4\n"
    "__imp___snprintf:\n"
    "    .long __snprintf\n"
    ".globl __imp____acrt_iob_func\n"
    ".align 4\n"
    "__imp____acrt_iob_func:\n"
    "    .long ___acrt_iob_func\n"
    ".globl __imp__atoi\n"
    ".align 4\n"
    "__imp__atoi:\n"
    "    .long _atoi\n"
    ".globl __imp__atol\n"
    ".align 4\n"
    "__imp__atol:\n"
    "    .long _atol\n"
    ".globl __imp__abs\n"
    ".align 4\n"
    "__imp__abs:\n"
    "    .long _abs\n"
    ".globl __imp__isprint\n"
    ".align 4\n"
    "__imp__isprint:\n"
    "    .long _isprint\n"
    ".globl __imp__isdigit\n"
    ".align 4\n"
    "__imp__isdigit:\n"
    "    .long _isdigit\n"
    ".globl __imp__isalpha\n"
    ".align 4\n"
    "__imp__isalpha:\n"
    "    .long _isalpha\n"
    ".globl __imp__isalnum\n"
    ".align 4\n"
    "__imp__isalnum:\n"
    "    .long _isalnum\n"
    ".globl __imp__isspace\n"
    ".align 4\n"
    "__imp__isspace:\n"
    "    .long _isspace\n"
    ".globl __imp__isupper\n"
    ".align 4\n"
    "__imp__isupper:\n"
    "    .long _isupper\n"
    ".globl __imp__islower\n"
    ".align 4\n"
    "__imp__islower:\n"
    "    .long _islower\n"
    ".globl __imp__isxdigit\n"
    ".align 4\n"
    "__imp__isxdigit:\n"
    "    .long _isxdigit\n"
    ".globl __imp__iscntrl\n"
    ".align 4\n"
    "__imp__iscntrl:\n"
    "    .long _iscntrl\n"
    ".globl __imp__isgraph\n"
    ".align 4\n"
    "__imp__isgraph:\n"
    "    .long _isgraph\n"
    ".globl __imp__ispunct\n"
    ".align 4\n"
    "__imp__ispunct:\n"
    "    .long _ispunct\n"
    ".text\n"
);
K32EOF
        sed -i 's/^C_SRCS\s*=/C_SRCS = kernel32_compat.c /' "$mf"
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
    sed -i 's/^C_SRCS\s*=/C_SRCS = qemu3dfx_ddraw_hooks.c /' dlls/ddraw/Makefile.in

    # Replace @ stub with @ stdcall for our hook functions in ddraw.spec
    if [ -f dlls/ddraw/ddraw.spec ]; then
        sed -i \
            -e 's/^@ stub DDHAL32_VidMemAlloc$/@ stdcall DDHAL32_VidMemAlloc(ptr long long long)/' \
            -e 's/^@ stub DDHAL32_VidMemFree$/@ stdcall DDHAL32_VidMemFree(ptr long long)/' \
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

    # Gut dlls/ucrtbase/Makefile.in so makedep generates an empty PE lib.
    # This prevents Wine from building a real ucrtbase import library that
    # would pull in ucrtbase.dll. Our ucrtcompat stubs in libmsvcrt.a satisfy
    # __acrt_iob_func/__stdio_common_* before the empty libucrtbase.a is searched.
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

    # Inject GetModuleHandleExW Win98 compat into all DLLs
    create_kernel32_compat

    # Strip Vista+ API from kernel32 import (GetModuleHandleExW → local stub)
    strip_kernel32_vista_imports

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
        CFLAGS="-O3 -march=i686 -msse4.2 -mtune=generic -fcommon -DWINE_NOWINSOCK -DUSE_WIN32_OPENGL -DUSE_WIN32_VULKAN -DNDEBUG -D__MSVCRT__ -U_UCRT" \
        LDFLAGS="-static-libgcc -mcrtdll=msvcrt -Xlinker --exclude-symbols -Xlinker _GetModuleHandleExW@12,__imp__GetModuleHandleExW@12,_GlobalMemoryStatusEx@4,__imp__GlobalMemoryStatusEx@4,_RtlIsCriticalSectionLockedByThread@4,__imp__RtlIsCriticalSectionLockedByThread@4,_InitOnceExecuteOnce@16,__imp__InitOnceExecuteOnce@16,_InitializeConditionVariable@4,__imp__InitializeConditionVariable@4,_WakeConditionVariable@4,__imp__WakeConditionVariable@4,_WakeAllConditionVariable@4,__imp__WakeAllConditionVariable@4,_SleepConditionVariableCS@12,__imp__SleepConditionVariableCS@12,_SetThreadDescription@8,__imp__SetThreadDescription@8,_strnicmp,__imp___strnicmp,_vsnprintf,__imp___vsnprintf,_snprintf,__imp___snprintf,atoi,atol,abs,isprint,isdigit,isalpha,isalnum,isspace,isupper,islower,isxdigit,iscntrl,isgraph,ispunct,__acrt_iob_func,__imp____acrt_iob_func" \
        CROSSCFLAGS="-O3 -march=i686 -msse4.2 -mtune=generic -fcommon -DWINE_NOWINSOCK -DUSE_WIN32_OPENGL -DUSE_WIN32_VULKAN -DNDEBUG -mcrtdll=msvcrt -D__MSVCRT__ -U_UCRT" \
        CROSSLDFLAGS="-static-libgcc -mcrtdll=msvcrt -Xlinker --exclude-symbols -Xlinker _GetModuleHandleExW@12,__imp__GetModuleHandleExW@12,_GlobalMemoryStatusEx@4,__imp__GlobalMemoryStatusEx@4,_RtlIsCriticalSectionLockedByThread@4,__imp__RtlIsCriticalSectionLockedByThread@4,_InitOnceExecuteOnce@16,__imp__InitOnceExecuteOnce@16,_InitializeConditionVariable@4,__imp__InitializeConditionVariable@4,_WakeConditionVariable@4,__imp__WakeConditionVariable@4,_WakeAllConditionVariable@4,__imp__WakeAllConditionVariable@4,_SleepConditionVariableCS@12,__imp__SleepConditionVariableCS@12,_SetThreadDescription@8,__imp__SetThreadDescription@8,_strnicmp,__imp___strnicmp,_vsnprintf,__imp___vsnprintf,_snprintf,__imp___snprintf,atoi,atol,abs,isprint,isdigit,isalpha,isalnum,isspace,isupper,islower,isxdigit,iscntrl,isgraph,ispunct,__acrt_iob_func,__imp____acrt_iob_func"

    # winebuild.exe is a PE binary; in --without-dlltool mode it spawns
    # the assembler via Windows CreateProcess which requires the MinGW bin
    # to be in the Windows PATH.  Remove the flag so winebuild uses dlltool
    # (an MSYS2 binary on the MSYS2 PATH) instead.
    sed -i 's/ --without-dlltool//g' Makefile


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
        sed -i 's/-lwine/..\/..\/libs\/wine\/wine-stubs.a/g' "$mf"
    done

    # D3DKMT stubs — prevent Vista+-only static imports from gdi32.dll
    create_d3dkmt_stubs

    # qemu-3dfx ddraw HAL VidMem stubs
    create_ddraw_hooks

    # Inject GetModuleHandleExW Win98 compat into all DLLs
    create_kernel32_compat

    # Strip Vista+ API from kernel32 import (GetModuleHandleExW → local stub)
    strip_kernel32_vista_imports

    echo "    Configuring (legacy winegcc mode)..."
    ./configure \
        --without-x \
        --without-alsa --without-capi --without-cups --without-dbus \
        --without-fontconfig --without-freetype --without-gphoto \
        --without-gstreamer --without-opencl \
        --without-pcap --without-pulse --without-sane --without-oss \
        --without-vulkan \
        --disable-shared --enable-static \
        CFLAGS="-O3 -march=i686 -msse4.2 -mtune=generic -fcommon -DWINE_NOWINSOCK -DUSE_WIN32_OPENGL -DUSE_WIN32_VULKAN -DNDEBUG -D__MSVCRT__" \
        LDFLAGS="-static-libgcc -mcrtdll=msvcrt"

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
    # UCRT compat stubs are already in libmsvcrt.a (via create_ucrtcompat)
    # so no separate .o injection needed.
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
    # Exclude GetModuleHandleExW stub from DLL exports so it doesn't
    # leak into import libs (causes ddraw.dll export errors).
    args+=(-Xlinker --exclude-symbols -Xlinker _GetModuleHandleExW@12,__imp__GetModuleHandleExW@12,_GlobalMemoryStatusEx@4,__imp__GlobalMemoryStatusEx@4,_RtlIsCriticalSectionLockedByThread@4,__imp__RtlIsCriticalSectionLockedByThread@4,_InitOnceExecuteOnce@16,__imp__InitOnceExecuteOnce@16,_InitializeConditionVariable@4,__imp__InitializeConditionVariable@4,_WakeConditionVariable@4,__imp__WakeConditionVariable@4,_WakeAllConditionVariable@4,__imp__WakeAllConditionVariable@4,_SleepConditionVariableCS@12,__imp__SleepConditionVariableCS@12,_SetThreadDescription@8,__imp__SetThreadDescription@8,_strnicmp,__imp___strnicmp,_vsnprintf,__imp___vsnprintf,_snprintf,__imp___snprintf,atoi,atol,abs,isprint,isdigit,isalpha,isalnum,isspace,isupper,islower,isxdigit,iscntrl,isgraph,ispunct,__acrt_iob_func,__imp____acrt_iob_func)
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

    # Strip flags not needed on Windows
    find . -name Makefile | xargs sed -i \
        -e 's/-fPIC//g' \
        -e 's/-fstack-protector[^ ]*//g'

    # Use winegcc-filter wrapper instead of winegcc in DLL Makefiles
    find dlls -name Makefile | xargs sed -i \
        -e 's|\(^WINEGCC = .*/\)winegcc[[:space:]]|\1winegcc-filter |' \
        -e 's|\(^WINEGCC = .*/\)winegcc$|\1winegcc-filter|'

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

    # Generate all import libs needed by wined3d/d3d9/d3d8/ddraw
    generate_import_libs

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
