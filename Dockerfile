FROM --platform=linux/amd64 archlinux:base-devel

# ── Layer 1: system packages ────────────────────────────────────────
RUN sed -i '/^#\[multilib\]/{N;s/#\[multilib\]\n#Include/\[multilib\]\nInclude/}' /etc/pacman.conf && \
    pacman-key --init && \
    pacman -Syu --noconfirm --disable-sandbox && \
    pacman -S --noconfirm --disable-sandbox \
        git wget \
        mingw-w64-gcc \
        mingw-w64-binutils \
        mingw-w64-headers \
        mingw-w64-winpthreads \
        flex bison mesa \
        lib32-gcc-libs lib32-glibc

# ── Layer 2: AUR mingw-w64-crt-git ─────────────────────────────────
RUN useradd -m builder && \
    echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

USER builder
RUN git clone https://aur.archlinux.org/yay-bin.git /tmp/yay-bin && \
    cd /tmp/yay-bin && \
    makepkg --noconfirm -si && \
    rm -rf /tmp/yay-bin && \
    cd /tmp && \
    \
    git clone https://aur.archlinux.org/mingw-w64-crt-git.git /tmp/mingw-crt && \
    cd /tmp/mingw-crt && \
    sed -i \
        -e 's/mingw-w64-headers-git[^"'"'"' ]*/mingw-w64-headers/g' \
        -e 's/mingw-w64-gcc-base/mingw-w64-gcc/g' \
        -e 's|git+https://git.code.sf.net/p/mingw-w64/mingw-w64|git+https://github.com/mingw-w64/mingw-w64.git|g' \
        PKGBUILD && \
    if grep -q 'with-default-msvcrt' PKGBUILD; then \
        sed -i 's/--with-default-msvcrt=[a-zA-Z]*/--with-default-msvcrt=msvcrt/g' PKGBUILD; \
    else \
        sed -i 's|_crt_configure_args="\(.*\)"|_crt_configure_args="\1 --with-default-msvcrt=msvcrt"|g' PKGBUILD; \
    fi && \
    sudo pacman -Rdd --noconfirm mingw-w64-crt 2>/dev/null || true && \
    MAKEFLAGS="-j$(nproc)" makepkg --noconfirm -d && \
    sudo pacman -U --noconfirm /tmp/mingw-crt/mingw-w64-crt-git-*.pkg.tar.zst && \
    rm -rf /tmp/mingw-crt
USER root

ARG WINE_VERSION=8.0.2
ARG WINE_BRANCH=8.0
ARG WINE_EXT=tar.xz
ARG BUILD_MSVCRT=0
ARG BUILD_MODE=modern

# ── Source files for qemu-3dfx + Win98 compat ───────────────────────
COPY qemu3dfx_hooks.c /docker/qemu3dfx_hooks.c
COPY qemu3dfx_ddraw_hooks.c /docker/qemu3dfx_ddraw_hooks.c
COPY qemu3dfx_ddraw_passthrough.c /docker/qemu3dfx_ddraw_passthrough.c
COPY docker/d3dkmt_stubs.c /docker/d3dkmt_stubs.c
COPY docker/kernel32_compat.c /docker/kernel32_compat.c

# ── Shared shell snippets (sourced inline in both build paths) ──────
# These are defined as Docker ARG/ENV would be too complex for inline
# shell functions. Instead they appear as literal code in each path.

# define our shared --exclude-symbols list once
#define EXCLUDE_SYMS="_wine_k32compat_GMHEW@12,__imp__wine_k32compat_GMHEW@12,_GlobalMemoryStatusEx@4,__imp__GlobalMemoryStatusEx@4,_RtlIsCriticalSectionLockedByThread@4,__imp__RtlIsCriticalSectionLockedByThread@4,_InitOnceExecuteOnce@16,__imp__InitOnceExecuteOnce@16,_InitializeConditionVariable@4,__imp__InitializeConditionVariable@4,_WakeConditionVariable@4,__imp__WakeConditionVariable@4,_WakeAllConditionVariable@4,__imp__WakeAllConditionVariable@4,_SleepConditionVariableCS@12,__imp__SleepConditionVariableCS@12,_SetThreadDescription@8,__imp__SetThreadDescription@8,_copysignf,__imp___copysignf,floor,__imp__floor,floorf,__imp__floorf,_fdclass,__imp___fdclass,_dclass,__imp___dclass,_dsign,__imp___dsign,_fdsign,__imp___fdsign,_fstat32,__imp___fstat32,_initterm,__imp___initterm,_initterm_e,__imp___initterm_e,_isctype,__imp___isctype,atoi,atol,abs,isprint,isdigit,isalpha,isalnum,isspace,isupper,islower,isxdigit,iscntrl,isgraph,ispunct,memcmp,__imp__memcmp,memchr,__imp__memchr,memcpy,__imp__memcpy,memset,__imp__memset,memmove,__imp__memmove,strlen,__imp__strlen,strcpy,__imp__strcpy,strcat,__imp__strcat,strcmp,__imp__strcmp,strncmp,__imp__strncmp,strchr,__imp__strchr,strrchr,__imp__strrchr,strstr,__imp__strstr,strcspn,__imp__strcspn,strnlen,__imp__strnlen,exp,__imp__exp,log,__imp__log,pow,__imp__pow,sprintf,__imp__sprintf,fprintf,__imp__fprintf,strtoul,__imp__strtoul,getc,__imp__getc,ungetc,__imp__ungetc"

RUN URL="https://dl.winehq.org/wine/source/${WINE_BRANCH}/wine-${WINE_VERSION}.${WINE_EXT}" && \
    wget "$URL" && \
    tar xf wine-${WINE_VERSION}.${WINE_EXT} && \
    mkdir -p /output/${WINE_VERSION} && \
    \
    # ── Force msvcrt via gcc wrapper ────────────────────────────────────────
    mv /usr/bin/i686-w64-mingw32-gcc /usr/bin/i686-w64-mingw32-gcc.orig && \
    \
    # ── Rename __acrt_iob_func → __iob_func in ALL CRT archives ─────────────
    for archive in \
        /usr/i686-w64-mingw32/lib/libmingwex.a \
        /usr/i686-w64-mingw32/lib/libmsvcrt.a \
        /usr/i686-w64-mingw32/lib/libmingw32.a; do \
        tmpdir=$(mktemp -d) && \
        cd "$tmpdir" && \
        i686-w64-mingw32-ar x "$archive" && \
        for obj in *.o; do \
            i686-w64-mingw32-objcopy \
                --redefine-sym ___acrt_iob_func=___iob_func \
                "$obj" 2>/dev/null || true; \
        done && \
        i686-w64-mingw32-ar rcs "$archive" *.o && \
        cd / && rm -rf "$tmpdir"; \
    done && \
    \
    # ── ucrtcompat stubs into libmsvcrt.a ───────────────────────────────────
    printf '%s\n' \
        '/* No includes - avoid header conflicts */' \
        'typedef unsigned long long _u64;' \
        'typedef unsigned int _uint;' \
        'typedef unsigned int _size;' \
        'typedef void *_locale;' \
        'typedef char _va_list[4];' \
        'typedef void FILE;' \
        'typedef unsigned short wchar_t;' \
        'FILE * __cdecl __iob_func(void);' \
        'int __cdecl _vsnprintf(char*,_size,const char*,...);' \
        'int __cdecl _vsnwprintf(wchar_t*,_size,const wchar_t*,...);' \
        'FILE * __cdecl __acrt_iob_func(_uint i){ return (char*)__iob_func()+i*32; }' \
        'int __cdecl __stdio_common_vsprintf(_u64 o,char *b,_size n,const char *f,_locale l,_va_list a){ return _vsnprintf(b,n==((_size)-1)?0x7fffffff:n,f,*(void**)a); }' \
        'int __cdecl __stdio_common_vsprintf_s(_u64 o,char *b,_size n,const char *f,_locale l,_va_list a){ return _vsnprintf(b,n,f,*(void**)a); }' \
        'int __cdecl __stdio_common_vsprintf_p(_u64 o,char *b,_size n,const char *f,_locale l,_va_list a){ return _vsnprintf(b,n,f,*(void**)a); }' \
        'int __cdecl __stdio_common_vsnprintf_s(_u64 o,char *b,_size n,_size c,const char *f,_locale l,_va_list a){ return _vsnprintf(b,c<n?c:n,f,*(void**)a); }' \
        'int __cdecl __stdio_common_vfprintf(_u64 o,FILE *p,const char *f,_locale l,_va_list a){ return 0; }' \
        'int __cdecl __stdio_common_vfprintf_s(_u64 o,FILE *p,const char *f,_locale l,_va_list a){ return 0; }' \
        'int __cdecl __stdio_common_vfscanf(_u64 o,FILE *p,const char *f,_locale l,_va_list a){ return -1; }' \
        'int __cdecl __stdio_common_vsscanf(_u64 o,const char *s,_size n,const char *f,_locale l,_va_list a){ return -1; }' \
        'int __cdecl __stdio_common_vswprintf(_u64 o,wchar_t *b,_size n,const wchar_t *f,_locale l,_va_list a){ return _vsnwprintf(b,n==((_size)-1)?0x7fffffff:n,f,*(void**)a); }' \
        'int __cdecl __stdio_common_vswprintf_s(_u64 o,wchar_t *b,_size n,const wchar_t *f,_locale l,_va_list a){ return _vsnwprintf(b,n,f,*(void**)a); }' \
        'int __cdecl __stdio_common_vswprintf_p(_u64 o,wchar_t *b,_size n,const wchar_t *f,_locale l,_va_list a){ return _vsnwprintf(b,n,f,*(void**)a); }' \
        'int __cdecl __stdio_common_vsnwprintf_s(_u64 o,wchar_t *b,_size n,_size c,const wchar_t *f,_locale l,_va_list a){ return _vsnwprintf(b,c<n?c:n,f,*(void**)a); }' \
        'int __cdecl __stdio_common_vfwprintf(_u64 o,FILE *p,const wchar_t *f,_locale l,_va_list a){ return 0; }' \
        'int __cdecl __stdio_common_vfwprintf_s(_u64 o,FILE *p,const wchar_t *f,_locale l,_va_list a){ return 0; }' \
        > /tmp/ucrtcompat.c && \
    /usr/bin/i686-w64-mingw32-gcc.orig -nostdinc -c \
        /tmp/ucrtcompat.c -o /tmp/ucrtcompat.o && \
    i686-w64-mingw32-ar rs \
        /usr/i686-w64-mingw32/lib/libmsvcrt.a /tmp/ucrtcompat.o && \
    \
    # ── Strip copysignf/floorf from libmsvcrt.a (Win98 only has double) ────
    _csf_dir=$(mktemp -d) && \
    cd "$_csf_dir" && \
    i686-w64-mingw32-ar x /usr/i686-w64-mingw32/lib/libmsvcrt.a && \
    for obj in *.o; do \
        i686-w64-mingw32-objcopy \
            --strip-symbol ___copysignf --strip-symbol __imp___copysignf \
            --strip-symbol ___floorf --strip-symbol __imp___floorf \
            "$obj" 2>/dev/null || true; \
    done && \
    i686-w64-mingw32-ar rcs /usr/i686-w64-mingw32/lib/libmsvcrt.a *.o && \
    cd / && rm -rf "$_csf_dir" && \
    \
    # ── Strip Vista+ from system MinGW import libs ─────────────────────────
    _vstrip="" && \
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
        IsBadStringPtrW@8 FreeLibraryAndExitThread@8; do \
        _vstrip="$_vstrip --strip-symbol _${api} --strip-symbol __imp__${api}"; \
    done && \
    for lib in /usr/i686-w64-mingw32/lib/libkernel32.a \
               /usr/i686-w64-mingw32/lib/libntdll.a; do \
        [ -f "$lib" ] || continue; \
        _tmp="$(mktemp).a" && \
        i686-w64-mingw32-objcopy $_vstrip "$lib" "$_tmp" 2>/dev/null && \
        mv "$_tmp" "$lib" || rm -f "$_tmp"; \
    done && \
    _ustrip="" && \
    for api in \
        EnumDisplayDevicesW@16 EnumDisplaySettingsExW@16 \
        EnumDisplaySettingsW@12 GetMonitorInfoW@8 \
        EnumDisplayMonitors@16 MonitorFromWindow@8 MonitorFromPoint@12 \
        ChangeDisplaySettingsExW@20; do \
        _ustrip="$_ustrip --strip-symbol _${api} --strip-symbol __imp__${api}"; \
    done && \
    for lib in /usr/i686-w64-mingw32/lib/libuser32.a; do \
        [ -f "$lib" ] || continue; \
        _tmp="$(mktemp).a" && \
        i686-w64-mingw32-objcopy $_ustrip "$lib" "$_tmp" 2>/dev/null && \
        mv "$_tmp" "$lib" || rm -f "$_tmp"; \
    done && \
    _nstrip="" && \
    for api in \
        sprintf vsprintf snprintf vsnprintf sscanf \
        memcpy memset memmove memcmp memchr \
        strlen strcpy strcat strcmp strncmp strchr strstr strrchr strcspn strnlen \
        tolower toupper strtol strtoul qsort bsearch \
        atoi atol abs \
        isprint isdigit isalpha isalnum isspace isupper islower isxdigit iscntrl isgraph ispunct \
        _stricmp _strnicmp \
        _vsnprintf _vsnprintf_s \
        sin cos tan atan atan2 sqrt ceil floor; do \
        _nstrip="$_nstrip --strip-symbol ${api} --strip-symbol __imp__${api}"; \
    done && \
    for lib in /usr/i686-w64-mingw32/lib/libntdll.a; do \
        [ -f "$lib" ] || continue; \
        _tmp="$(mktemp).a" && \
        i686-w64-mingw32-objcopy $_nstrip "$lib" "$_tmp" 2>/dev/null && \
        mv "$_tmp" "$lib" || rm -f "$_tmp"; \
    done && \
    _istrip="" && \
    for api in _initterm _initterm_e strnlen _isctype; do \
        _istrip="$_istrip --strip-symbol ${api} --strip-symbol __imp__${api}"; \
    done && \
    for lib in /usr/i686-w64-mingw32/lib/libmsvcrt.a; do \
        [ -f "$lib" ] || continue; \
        _tmp="$(mktemp).a" && \
        i686-w64-mingw32-objcopy $_istrip "$lib" "$_tmp" 2>/dev/null && \
        mv "$_tmp" "$lib" || rm -f "$_tmp"; \
    done && \
    \
    # ── gcc wrapper ─────────────────────────────────────────────────────────
    printf '#!/bin/sh\nexec /usr/bin/i686-w64-mingw32-gcc.orig -mcrtdll=msvcrt -D__MSVCRT__ -U_UCRT "$@"\n' \
        > /usr/bin/i686-w64-mingw32-gcc && \
    chmod +x /usr/bin/i686-w64-mingw32-gcc && \
    \
    # ════════════════════════════════════════════════════════════════════════
    #  Build paths split by BUILD_MODE
    # ════════════════════════════════════════════════════════════════════════
    \
    if [ "$BUILD_MODE" = "modern" ]; then \
        # ─── MODERN PATH (Wine 8.x) ────────────────────────────────────────
        cd wine-${WINE_VERSION} && \
        \
        # Patch makedep.c: default CRT ucrtbase → msvcrt
        # Wine's makedep hardcodes "ucrtbase" as the default CRT for PE DLLs.
        # Change it to "msvcrt" so Wine generates and links libmsvcrt.a.
        sed -i 's/return !make->testdll && (!make->staticlib || make->extlib) ? "ucrtbase" : "msvcrt";/return "msvcrt";/' \
            tools/makedep.c && \
        # Gut ucrtbase Makefile (empty import lib — prevent any ucrtbase linkage)
        sed -i \
            -e '/^DELAYIMPORTS/d' \
            -e '/^IMPORTS/d' \
            -e 's/^C_SRCS\s*=.*/C_SRCS =/' \
            -e 's/^RC_SRCS\s*=.*/RC_SRCS =/' \
            dlls/ucrtbase/Makefile.in && \
        # Strip UCRT printf/iob from ucrtbase.spec so the generated import lib
        # doesn't provide them (our libmsvcrt.a ucrtcompat.o provides local defs)
        if [ -f dlls/ucrtbase/ucrtbase.spec ]; then \
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
                   dlls/ucrtbase/ucrtbase.spec; \
        fi && \
        \
        # ── D3DKMT stubs ───────────────────────────────────────────────────
        cp /docker/d3dkmt_stubs.c dlls/wined3d/d3dkmt_stubs.c && \
        grep -q 'd3dkmt_stubs.c' dlls/wined3d/Makefile.in || \
            sed -i 's/^C_SRCS\s*=/C_SRCS = d3dkmt_stubs.c /' dlls/wined3d/Makefile.in && \
        \
        # ── qemu-3dfx hooks ────────────────────────────────────────────────
        cp /docker/qemu3dfx_hooks.c dlls/wined3d/qemu3dfx_hooks.c && \
        grep -q 'qemu3dfx_hooks.c' dlls/wined3d/Makefile.in || \
            sed -i 's/^C_SRCS\s*=/C_SRCS = qemu3dfx_hooks.c /' dlls/wined3d/Makefile.in && \
        if [ -f dlls/wined3d/wined3d.spec ] && \
           ! grep -q 'wined3d_hal_3dfx' dlls/wined3d/wined3d.spec; then \
            printf '\n@ stdcall wined3d_hal_3dfx()\n@ stdcall wined3d_enum_hal_last()\n@ stdcall wined3d_surface_ddheap()\n@ stdcall wined3d_passthru(ptr)\n@ stdcall wined3d_override_cooplevel(ptr)\n@ stdcall wined3d_override_rendertarget_view(ptr)\n@ stdcall wined3d_blit_fpslimit()\n@ stdcall wined3d_flip_fpslimit()\n@ stdcall wined3d_get_gamma_ramp_3dfx(ptr ptr)\n@ stdcall wined3d_set_gamma_ramp_3dfx(ptr ptr)\n@ stdcall wined3d_set_cursor_3dfx(ptr ptr)\n' \
                >> dlls/wined3d/wined3d.spec; \
        fi && \
        \
        # ── ddraw hooks ────────────────────────────────────────────────────
        cp /docker/qemu3dfx_ddraw_hooks.c dlls/ddraw/qemu3dfx_ddraw_hooks.c && \
        grep -q 'qemu3dfx_ddraw_hooks.c' dlls/ddraw/Makefile.in || \
            sed -i 's/^C_SRCS\s*=/C_SRCS = qemu3dfx_ddraw_hooks.c /' dlls/ddraw/Makefile.in && \
        if [ -f dlls/ddraw/ddraw.spec ]; then \
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
                dlls/ddraw/ddraw.spec; \
            grep -q 'AcquireDDThreadLock' dlls/ddraw/ddraw.spec || \
                printf '@ stdcall AcquireDDThreadLock()\n@ stdcall ReleaseDDThreadLock()\n@ stdcall CompleteCreateSysmemSurface(ptr)\n@ stdcall D3DParseUnknownCommand(ptr ptr)\n' \
                    >> dlls/ddraw/ddraw.spec; \
        fi && \
        \
        # ── ddraw passthrough ──────────────────────────────────────────────
        cp /docker/qemu3dfx_ddraw_passthrough.c dlls/ddraw/qemu3dfx_ddraw_passthrough.c && \
        grep -q 'qemu3dfx_ddraw_passthrough.c' dlls/ddraw/Makefile.in || \
            sed -i 's/^C_SRCS\s*=/C_SRCS = qemu3dfx_ddraw_passthrough.c /' dlls/ddraw/Makefile.in && \
        if [ -f dlls/ddraw/main.c ]; then \
            sed -i 's/^BOOL WINAPI DllMain/extern void qemu3dfx_ddraw_passthrough_init(void);\n\nBOOL WINAPI DllMain/' dlls/ddraw/main.c && \
            sed -i 's/DisableThreadLibraryCalls(inst);/DisableThreadLibraryCalls(inst);\n        qemu3dfx_ddraw_passthrough_init();/' dlls/ddraw/main.c; \
        fi && \
        if [ -f dlls/ddraw/ddraw.c ]; then \
            sed -i 's/#include "ddraw_private.h"/#include "ddraw_private.h"\nextern void qemu3dfx_ddraw_cooplevel(DWORD *);/' dlls/ddraw/ddraw.c && \
            sed -i 's/DDRAW_dump_cooperativelevel(cooplevel);/DDRAW_dump_cooperativelevel(cooplevel);\n    qemu3dfx_ddraw_cooplevel(\&cooplevel);/' dlls/ddraw/ddraw.c; \
        fi && \
        if [ -f dlls/ddraw/surface.c ]; then \
            sed -i 's/#include "ddraw_private.h"/#include "ddraw_private.h"\nextern void qemu3dfx_ddraw_blit(void);\nextern void qemu3dfx_ddraw_flip(void);\nextern void qemu3dfx_ddraw_rtv(void *);/' dlls/ddraw/surface.c && \
            sed -i 's/return wined3d_texture_blt(dst_surface/qemu3dfx_ddraw_blit();\n    return wined3d_texture_blt(dst_surface/' dlls/ddraw/surface.c && \
            sed -i 's/return wined3d_device_context_blt(ddraw/qemu3dfx_ddraw_blit();\n    return wined3d_device_context_blt(ddraw/' dlls/ddraw/surface.c && \
            sed -i 's/\(DDSCAPS2\? caps = {DDSCAPS_FLIP.*\)/\1\n    qemu3dfx_ddraw_flip();/' dlls/ddraw/surface.c && \
            sed -i 's/\(tmp_rtv = ddraw_surface_get_rendertarget_view(dst_impl);\)/\1\n    qemu3dfx_ddraw_rtv(tmp_rtv);/' dlls/ddraw/surface.c; \
        fi && \
        \
        # ── kernel32_compat.c (per-DLL Win98 stubs) ────────────────────────
        for dll in wined3d d3d9 d3d8 ddraw; do \
            [ -f "dlls/$dll/Makefile.in" ] || continue; \
            cp /docker/kernel32_compat.c "dlls/$dll/kernel32_compat.c"; \
            grep -q 'kernel32_compat.c' "dlls/$dll/Makefile.in" || \
                sed -i 's/^C_SRCS\s*=/C_SRCS = kernel32_compat.c /' "dlls/$dll/Makefile.in"; \
        done && \
        \
        # ── GetModuleHandleExW redirect ────────────────────────────────────
        for dll in ddraw wined3d d3d9 d3d8; do \
            for f in dlls/$dll/*.c; do \
                [ -f "$f" ] || continue; \
                case "$f" in */kernel32_compat.c) continue ;; esac; \
                grep -q 'GetModuleHandleExW' "$f" 2>/dev/null || continue; \
                sed -i '1i #define GetModuleHandleExW wine_k32compat_GMHEW' "$f"; \
            done; \
        done && \
        for dll in ddraw wined3d d3d9 d3d8; do \
            for f in dlls/$dll/*.c; do \
                [ -f "$f" ] || continue; \
                case "$f" in */kernel32_compat.c) continue ;; esac; \
                for _func in EnumDisplayDevicesW EnumDisplaySettingsW EnumDisplaySettingsExW \
                            GetMonitorInfoW EnumDisplayMonitors MonitorFromWindow MonitorFromPoint \
                            ChangeDisplaySettingsExW IsBadStringPtrW FreeLibraryAndExitThread; do \
                    grep -q "$_func" "$f" 2>/dev/null || continue; \
                    case "$_func" in \
                        EnumDisplayDevicesW) _compat=wine_k32compat_EDD_W ;; \
                        EnumDisplaySettingsW) _compat=wine_k32compat_EDS_W ;; \
                        EnumDisplaySettingsExW) _compat=wine_k32compat_EDSE_W ;; \
                        GetMonitorInfoW) _compat=wine_k32compat_GMI_W ;; \
                        EnumDisplayMonitors) _compat=wine_k32compat_EDM ;; \
                        MonitorFromWindow) _compat=wine_k32compat_MFW ;; \
                        MonitorFromPoint) _compat=wine_k32compat_MFP ;; \
                        ChangeDisplaySettingsExW) _compat=wine_k32compat_CDSE_W ;; \
                        IsBadStringPtrW) _compat=wine_k32compat_IBSP_W ;; \
                        FreeLibraryAndExitThread) _compat=wine_k32compat_FLAET ;; \
                    esac; \
                    sed -i "1i #define $_func $_compat" "$f"; \
                done; \
            done; \
        done && \
        \
        # ── Configure ──────────────────────────────────────────────────────
        ./configure \
            --without-x \
            --without-alsa --without-capi --without-cups --without-dbus \
            --without-fontconfig --without-freetype --without-gphoto \
            --without-gstreamer --without-opencl \
            --without-pcap --without-pulse --without-sane \
            --without-sdl --without-udev --without-usb \
            --without-v4l2 --without-vulkan --without-oss \
            CROSSCFLAGS="-O3 -march=i686 -msse4.2 -mtune=generic -fcommon -DWINE_NOWINSOCK -DUSE_WIN32_OPENGL -DUSE_WIN32_VULKAN -DNDEBUG -mcrtdll=msvcrt -D__MSVCRT__ -U_UCRT -DGetModuleHandleExW=wine_k32compat_GMHEW -Dcopysignf=_copysignf -DEnumDisplayDevicesW=wine_k32compat_EDD_W -DEnumDisplaySettingsW=wine_k32compat_EDS_W -DEnumDisplaySettingsExW=wine_k32compat_EDSE_W -DGetMonitorInfoW=wine_k32compat_GMI_W -DEnumDisplayMonitors=wine_k32compat_EDM -DMonitorFromWindow=wine_k32compat_MFW -DMonitorFromPoint=wine_k32compat_MFP -DChangeDisplaySettingsExW=wine_k32compat_CDSE_W -DIsBadStringPtrW=wine_k32compat_IBSP_W -DFreeLibraryAndExitThread=wine_k32compat_FLAET" \
            CROSSLDFLAGS="-static-libgcc -mcrtdll=msvcrt -Xlinker --exclude-symbols -Xlinker _wine_k32compat_GMHEW@12,__imp__wine_k32compat_GMHEW@12,_GlobalMemoryStatusEx@4,__imp__GlobalMemoryStatusEx@4,_RtlIsCriticalSectionLockedByThread@4,__imp__RtlIsCriticalSectionLockedByThread@4,_InitOnceExecuteOnce@16,__imp__InitOnceExecuteOnce@16,_InitializeConditionVariable@4,__imp__InitializeConditionVariable@4,_WakeConditionVariable@4,__imp__WakeConditionVariable@4,_WakeAllConditionVariable@4,__imp__WakeAllConditionVariable@4,_SleepConditionVariableCS@12,__imp__SleepConditionVariableCS@12,_SetThreadDescription@8,__imp__SetThreadDescription@8,_copysignf,__imp___copysignf,floor,__imp__floor,floorf,__imp__floorf,_fdclass,__imp___fdclass,_dclass,__imp___dclass,_dsign,__imp___dsign,_fdsign,__imp___fdsign,_fstat32,__imp___fstat32,_initterm,__imp___initterm,_initterm_e,__imp___initterm_e,__acrt_iob_func,__imp____acrt_iob_func,__stdio_common_vsprintf,__imp____stdio_common_vsprintf,__stdio_common_vfprintf,__imp____stdio_common_vfprintf,__stdio_common_vsscanf,__imp____stdio_common_vsscanf,atoi,atol,abs,isprint,isdigit,isalpha,isalnum,isspace,isupper,islower,isxdigit,iscntrl,isgraph,ispunct,memcmp,__imp__memcmp,memchr,__imp__memchr,memcpy,__imp__memcpy,memset,__imp__memset,memmove,__imp__memmove,strlen,__imp__strlen,strcpy,__imp__strcpy,strcat,__imp__strcat,strcmp,__imp__strcmp,strncmp,__imp__strncmp,strchr,__imp__strchr,strrchr,__imp__strrchr,strstr,__imp__strstr,strcspn,__imp__strcspn,strnlen,__imp__strnlen,exp,__imp__exp,log,__imp__log,pow,__imp__pow,sprintf,__imp__sprintf,fprintf,__imp__fprintf,strtoul,__imp__strtoul,getc,__imp__getc,ungetc,__imp__ungetc,_wine_k32compat_EDD_W@16,__imp__wine_k32compat_EDD_W@16,_wine_k32compat_EDS_W@12,__imp__wine_k32compat_EDS_W@12,_wine_k32compat_EDSE_W@16,__imp__wine_k32compat_EDSE_W@16,_wine_k32compat_GMI_W@8,__imp__wine_k32compat_GMI_W@8,_wine_k32compat_EDM@16,__imp__wine_k32compat_EDM@16,_wine_k32compat_MFW@8,__imp__wine_k32compat_MFW@8,_wine_k32compat_MFP@12,__imp__wine_k32compat_MFP@12,_wine_k32compat_CDSE_W@20,__imp__wine_k32compat_CDSE_W@20,_wine_k32compat_IBSP_W@8,__imp__wine_k32compat_IBSP_W@8,_wine_k32compat_FLAET@8,__imp__wine_k32compat_FLAET@8" && \
 \
        \
        # ── Spec stripping (after configure regenerates specs) ──────────────
        for spec in dlls/kernel32/kernel32.spec dlls/ntdll/ntdll.spec; do \
            [ -f "$spec" ] || continue; \
            sed -i -e '/GetModuleHandleExW/d' -e '/GlobalMemoryStatusEx/d' \
                   -e '/RtlIsCriticalSectionLockedByThread/d' \
                   -e '/InitOnceBeginInitialize/d' -e '/InitOnceComplete/d' \
                   -e '/InitOnceExecuteOnce/d' -e '/InitOnceInitialize/d' \
                   -e '/InitializeSRWLock/d' \
                   -e '/AcquireSRWLockExclusive/d' -e '/AcquireSRWLockShared/d' \
                   -e '/ReleaseSRWLockExclusive/d' -e '/ReleaseSRWLockShared/d' \
                   -e '/TryAcquireSRWLockExclusive/d' -e '/TryAcquireSRWLockShared/d' \
                   -e '/InitializeConditionVariable/d' \
                   -e '/WakeConditionVariable/d' -e '/WakeAllConditionVariable/d' \
                   -e '/SleepConditionVariableCS/d' -e '/SleepConditionVariableSRW/d' \
                   -e '/GetTickCount64/d' -e '/SetThreadDescription/d' \
                   -e '/IsBadStringPtrW/d' -e '/FreeLibraryAndExitThread/d' \
                   "$spec"; \
        done && \
        for spec in dlls/ntdll/ntdll.spec; do \
            [ -f "$spec" ] || continue; \
            sed -i -e '/_stricmp/d' \
                   -e '/^@.*_vsnprintf/d' -e '/^@.*_snprintf/d' \
                   -e '/^@.*\bsprintf\b/d' -e '/^@.*\bvsprintf\b/d' \
                   -e '/^@.*\bvsnprintf\b/d' -e '/^@.*\bsnprintf\b/d' \
                   -e '/^@.*\bsscanf/d' \
                   -e '/^@.*\bmemcpy\b/d' -e '/^@.*\bmemset\b/d' \
                   -e '/^@.*\bmemmove\b/d' -e '/^@.*\bmemcmp\b/d' -e '/^@.*\bmemchr\b/d' \
                   -e '/^@.*\bstrlen\b/d' -e '/^@.*\bstrcpy\b/d' \
                   -e '/^@.*\bstrcat\b/d' -e '/^@.*\bstrcmp\b/d' -e '/^@.*\bstrncmp\b/d' \
                   -e '/^@.*\bstrchr\b/d' -e '/^@.*\bstrstr\b/d' -e '/^@.*\bstrrchr\b/d' \
                   -e '/^@.*\btolower\b/d' -e '/^@.*\btoupper\b/d' \
                   -e '/^@.*\batoi\b/d' -e '/^@.*\batol\b/d' -e '/^@.*\bstrtol\b/d' \
                   -e '/^@.*\bqsort\b/d' -e '/^@.*\bbsearch\b/d' \
                   -e '/^@.*\bisprint\b/d' -e '/^@.*\bisdigit\b/d' \
                   -e '/^@.*\bisalpha\b/d' -e '/^@.*\bisalnum\b/d' \
                   -e '/^@.*\bisspace\b/d' -e '/^@.*\bisupper\b/d' -e '/^@.*\bislower\b/d' \
                   -e '/^@.*\bisxdigit\b/d' -e '/^@.*\biscntrl\b/d' \
                   -e '/^@.*\bisgraph\b/d' -e '/^@.*\bispunct\b/d' \
                   -e '/^@.*\babs\b/d' -e '/^@.*\bpow\b/d' \
                   -e '/^@.*\bexp\b/d' -e '/^@.*\blog\b/d' \
                   -e '/^@.*\bstrcspn\b/d' -e '/^@.*\bstrnlen\b/d' \
                   -e '/^@.*\bstrtoul\b/d' -e '/^@.*\bfprintf\b/d' \
                   -e '/^@.*\bsin\b/d' -e '/^@.*\btan\b/d' -e '/^@.*\batan\b/d' \
                   -e '/^@.*\bsqrt\b/d' -e '/^@.*\bceil\b/d' -e '/^@.*\bfloor\b/d' \
                   "$spec"; \
        done && \
        for spec in dlls/msvcrt/msvcrt.spec; do \
            [ -f "$spec" ] || continue; \
            sed -i -e '/__acrt_iob_func/d' \
                   -e '/__stdio_common_/d' \
                   -e '/_initterm/d' \
                   "$spec"; \
        done && \
        for spec in dlls/user32/user32.spec; do \
            [ -f "$spec" ] || continue; \
            sed -i -e '/EnumDisplayDevicesW/d' \
                   -e '/EnumDisplaySettingsExW/d' \
                   -e '/EnumDisplaySettingsW/d' \
                   -e '/GetMonitorInfoW/d' \
                   -e '/EnumDisplayMonitors/d' \
                   -e '/MonitorFromWindow/d' \
                   -e '/MonitorFromPoint/d' \
                   -e '/ChangeDisplaySettingsExW/d' \
                   "$spec"; \
        done && \
        _ustrip_w="" && \
        for api in \
            EnumDisplayDevicesW@16 EnumDisplaySettingsExW@16 \
            EnumDisplaySettingsW@12 GetMonitorInfoW@8 \
            EnumDisplayMonitors@16 MonitorFromWindow@8 MonitorFromPoint@12 \
        ChangeDisplaySettingsExW@20; do \
            _ustrip_w="$_ustrip_w --strip-symbol _${api} --strip-symbol __imp__${api}"; \
        done && \
        for lib in dlls/user32/i386-windows/libuser32.a \
                   dlls/user32/libuser32.a; do \
            [ -f "$lib" ] || continue; \
            _tmp="$(mktemp).a" && \
            i686-w64-mingw32-objcopy $_ustrip_w "$lib" "$_tmp" 2>/dev/null && \
            mv "$_tmp" "$lib" || rm -f "$_tmp"; \
        done && \
        \
        # ── Build ──────────────────────────────────────────────────────────
        TARGETS="dlls/wined3d/i386-windows/wined3d.dll \
                 dlls/d3d9/i386-windows/d3d9.dll \
                 dlls/d3d8/i386-windows/d3d8.dll \
                 dlls/ddraw/i386-windows/ddraw.dll" && \
        if [ "$BUILD_MSVCRT" = "1" ]; then \
            TARGETS="$TARGETS dlls/msvcrt/i386-windows/msvcrt.dll"; \
        fi && \
        make -j$(nproc) $TARGETS && \
        cp dlls/wined3d/i386-windows/wined3d.dll \
           dlls/d3d9/i386-windows/d3d9.dll \
           dlls/d3d8/i386-windows/d3d8.dll \
           dlls/ddraw/i386-windows/ddraw.dll \
           /output/${WINE_VERSION}/ && \
        if [ "$BUILD_MSVCRT" = "1" ]; then \
            cp dlls/msvcrt/i386-windows/msvcrt.dll /output/${WINE_VERSION}/; \
        fi; \
    else \
        # ─── LEGACY PATH (Wine 1.x–7.x) ───────────────────────────────────
        \
        # Stage 1: native tools
        cd wine-${WINE_VERSION} && \
        ./configure \
            --without-x \
            --without-alsa --without-capi --without-cups --without-dbus \
            --without-fontconfig --without-freetype --without-gphoto \
            --without-gstreamer --without-opencl \
            --without-pcap --without-pulse --without-sane --without-oss && \
        make -j$(nproc) tools/makedep && \
        make -j1 __tooldeps__ 2>/dev/null || : && \
        make -j$(nproc) libs/port 2>/dev/null || : && \
        for tool in winebuild wrc widl winegcc; do \
            make -j$(nproc) -C tools/$tool; \
        done && \
        # Patch winegcc.c: remove -lwine (we provide a stub in lib/) and
        # replace -lucrtbase with -lmsvcrt (same as CI build-ci.sh).
        if [ -f tools/winegcc/winegcc.c ]; then \
            sed -i '/add_library.*"wine"/d' tools/winegcc/winegcc.c; \
            sed -i 's/"-lwine"/"lib\/libwine.a"/g' tools/winegcc/winegcc.c; \
            sed -i '/"libwine"/d' tools/winegcc/winegcc.c; \
            sed -i 's|/libwine\.so|/libwine_stubs_dummy|g' tools/winegcc/winegcc.c; \
            sed -i 's|"ucrtbase"|"msvcrt"|g' tools/winegcc/winegcc.c; \
            make -B -C tools/winegcc; \
        fi && \
        make -C libs/wpp libwpp.a 2>/dev/null || : && \
        make tools/make_xftmpl 2>/dev/null || : && \
        # Generate IDL-derived headers (wtypes.h etc.) so makedep can find
        # them when scanning #include deps in the cross tree.
        make include/Makefile 2>/dev/null && \
        make -C include 2>/dev/null || : && \
        cd / && \
        \
        # Stage 2: cross-compile
        cp -r wine-${WINE_VERSION} wine-${WINE_VERSION}-cross && \
        find wine-${WINE_VERSION}-cross -name "*.o" -delete && \
        if [ -f wine-${WINE_VERSION}/libs/port/libwine_port.a ]; then \
            cp wine-${WINE_VERSION}/libs/port/libwine_port.a \
               wine-${WINE_VERSION}-cross/libs/port/; \
        fi && \
        if [ -f wine-${WINE_VERSION}/libs/wpp/libwpp.a ]; then \
            cp wine-${WINE_VERSION}/libs/wpp/libwpp.a \
               wine-${WINE_VERSION}-cross/libs/wpp/; \
        fi && \
        cd wine-${WINE_VERSION}-cross && \
        \
        # Patch makedep.c: default CRT ucrtbase → msvcrt (Wine 6.x+)
        if [ -f tools/makedep.c ]; then \
            sed -i 's/return !make->testdll && (!make->staticlib || make->extlib) ? "ucrtbase" : "msvcrt";/return "msvcrt";/' \
                tools/makedep.c; \
        fi && \
        # port.c / ldt.c stubs
        printf '%s\n' \
            '#include <string.h>' \
            'struct wine_pthread_functions;' \
            'static void *pthread_functions[8];' \
            'void wine_pthread_get_functions(struct wine_pthread_functions *f, unsigned int sz)' \
            '{ if(f&&sz) memcpy(f,&pthread_functions,sz<sizeof(pthread_functions)?sz:sizeof(pthread_functions)); }' \
            'void wine_pthread_set_functions(const struct wine_pthread_functions *f, unsigned int sz)' \
            '{ if(f&&sz) memcpy(&pthread_functions,f,sz<sizeof(pthread_functions)?sz:sizeof(pthread_functions)); }' \
            'void wine_switch_to_stack(void (*func)(void *),void *arg,void *stack){if(func)func(arg);}' \
            'int  wine_call_on_stack(int (*func)(void *),void *arg,void *stack){return func?func(arg):0;}' \
            > libs/wine/port.c && \
        printf '%s\n' \
            'unsigned short wine_get_cs(void){return 0;}' \
            'unsigned short wine_get_ds(void){return 0;}' \
            'unsigned short wine_get_es(void){return 0;}' \
            'unsigned short wine_get_fs(void){return 0;}' \
            'unsigned short wine_get_gs(void){return 0;}' \
            'unsigned short wine_get_ss(void){return 0;}' \
            'void wine_set_fs(unsigned short fs){}' \
            'void wine_set_gs(unsigned short gs){}' \
            > libs/wine/ldt.c && \
        \
        # ── Configure FIRST (before source modifications) ──────────────────
        # Wine 1.x-5.x: configure runs makedep on Makefile.in to generate
        # per-directory Makefiles.  Our source additions confuse makedep,
        # so we run configure on pristine sources, then patch afterwards.
        ./configure \
            --without-x \
            --disable-tests \
            --disable-kernel32 \
            --without-freetype \
            --host=i686-w64-mingw32 \
            --with-wine-tools=../wine-${WINE_VERSION} \
            CFLAGS="-O3 -march=i686 -msse4.2 -mtune=generic -fcommon -DWINE_NOWINSOCK -DUSE_WIN32_OPENGL -DUSE_WIN32_VULKAN -DNDEBUG -mcrtdll=msvcrt -D__MSVCRT__ -U_UCRT -DGetModuleHandleExW=wine_k32compat_GMHEW -Dcopysignf=_copysignf -DEnumDisplayDevicesW=wine_k32compat_EDD_W -DEnumDisplaySettingsW=wine_k32compat_EDS_W -DEnumDisplaySettingsExW=wine_k32compat_EDSE_W -DGetMonitorInfoW=wine_k32compat_GMI_W -DEnumDisplayMonitors=wine_k32compat_EDM -DMonitorFromWindow=wine_k32compat_MFW -DMonitorFromPoint=wine_k32compat_MFP -DChangeDisplaySettingsExW=wine_k32compat_CDSE_W -DIsBadStringPtrW=wine_k32compat_IBSP_W -DFreeLibraryAndExitThread=wine_k32compat_FLAET" \
            LDFLAGS="-static-libgcc -mcrtdll=msvcrt -Xlinker --exclude-symbols -Xlinker _wine_k32compat_GMHEW@12,__imp__wine_k32compat_GMHEW@12,_GlobalMemoryStatusEx@4,__imp__GlobalMemoryStatusEx@4,_RtlIsCriticalSectionLockedByThread@4,__imp__RtlIsCriticalSectionLockedByThread@4,_InitOnceExecuteOnce@16,__imp__InitOnceExecuteOnce@16,_InitializeConditionVariable@4,__imp__InitializeConditionVariable@4,_WakeConditionVariable@4,__imp__WakeConditionVariable@4,_WakeAllConditionVariable@4,__imp__WakeAllConditionVariable@4,_SleepConditionVariableCS@12,__imp__SleepConditionVariableCS@12,_SetThreadDescription@8,__imp__SetThreadDescription@8,_copysignf,__imp___copysignf,floor,__imp__floor,floorf,__imp__floorf,_fdclass,__imp___fdclass,_dclass,__imp___dclass,_dsign,__imp___dsign,_fdsign,__imp___fdsign,_fstat32,__imp___fstat32,_initterm,__imp___initterm,_initterm_e,__imp___initterm_e,__acrt_iob_func,__imp____acrt_iob_func,__stdio_common_vsprintf,__imp____stdio_common_vsprintf,__stdio_common_vfprintf,__imp____stdio_common_vfprintf,__stdio_common_vsscanf,__imp____stdio_common_vsscanf,atoi,atol,abs,isprint,isdigit,isalpha,isalnum,isspace,isupper,islower,isxdigit,iscntrl,isgraph,ispunct,memcmp,__imp__memcmp,memchr,__imp__memchr,memcpy,__imp__memcpy,memset,__imp__memset,memmove,__imp__memmove,strlen,__imp__strlen,strcpy,__imp__strcpy,strcat,__imp__strcat,strcmp,__imp__strcmp,strncmp,__imp__strncmp,strchr,__imp__strchr,strrchr,__imp__strrchr,strstr,__imp__strstr,strcspn,__imp__strcspn,strnlen,__imp__strnlen,exp,__imp__exp,log,__imp__log,pow,__imp__pow,sprintf,__imp__sprintf,fprintf,__imp__fprintf,strtoul,__imp__strtoul,getc,__imp__getc,ungetc,__imp__ungetc,_wine_k32compat_EDD_W@16,__imp__wine_k32compat_EDD_W@16,_wine_k32compat_EDS_W@12,__imp__wine_k32compat_EDS_W@12,_wine_k32compat_EDSE_W@16,__imp__wine_k32compat_EDSE_W@16,_wine_k32compat_GMI_W@8,__imp__wine_k32compat_GMI_W@8,_wine_k32compat_EDM@16,__imp__wine_k32compat_EDM@16,_wine_k32compat_MFW@8,__imp__wine_k32compat_MFW@8,_wine_k32compat_MFP@12,__imp__wine_k32compat_MFP@12,_wine_k32compat_CDSE_W@20,__imp__wine_k32compat_CDSE_W@20,_wine_k32compat_IBSP_W@8,__imp__wine_k32compat_IBSP_W@8,_wine_k32compat_FLAET@8,__imp__wine_k32compat_FLAET@8" && \
        \
        # config.h patches
        sed -i \
            -e '/#define HAVE_DIRECT_H/d' \
            -e '/#define HAVE_IO_H/d' \
            -e '/#define HAVE_PROCESS_H/d' \
            include/config.h && \
        printf '#define HAVE_FSBLKCNT_T 1\n#define HAVE_FSFILCNT_T 1\n#define HAVE_STRUCT_STATVFS_F_BLOCKS 1\n' \
            >> include/config.h && \
        \
        # ── Source additions (AFTER configure, modify Makefile.in) ───────
        # makedep will regenerate per-directory Makefiles from these
        # Makefile.in files during the `make dlls/xxx/Makefile` step below.
        \
        # D3DKMT stubs
        cp /docker/d3dkmt_stubs.c dlls/wined3d/d3dkmt_stubs.c && \
        grep -q 'd3dkmt_stubs.c' dlls/wined3d/Makefile.in || \
            sed -i 's/^C_SRCS\s*=/C_SRCS = d3dkmt_stubs.c /' dlls/wined3d/Makefile.in && \
        \
        # qemu-3dfx hooks
        cp /docker/qemu3dfx_hooks.c dlls/wined3d/qemu3dfx_hooks.c && \
        grep -q 'qemu3dfx_hooks.c' dlls/wined3d/Makefile.in || \
            sed -i 's/^C_SRCS\s*=/C_SRCS = qemu3dfx_hooks.c /' dlls/wined3d/Makefile.in && \
        if [ -f dlls/wined3d/wined3d.spec ] && \
           ! grep -q 'wined3d_hal_3dfx' dlls/wined3d/wined3d.spec; then \
            printf '\n@ stdcall wined3d_hal_3dfx()\n@ stdcall wined3d_enum_hal_last()\n@ stdcall wined3d_surface_ddheap()\n@ stdcall wined3d_passthru(ptr)\n@ stdcall wined3d_override_cooplevel(ptr)\n@ stdcall wined3d_override_rendertarget_view(ptr)\n@ stdcall wined3d_blit_fpslimit()\n@ stdcall wined3d_flip_fpslimit()\n@ stdcall wined3d_get_gamma_ramp_3dfx(ptr ptr)\n@ stdcall wined3d_set_gamma_ramp_3dfx(ptr ptr)\n@ stdcall wined3d_set_cursor_3dfx(ptr ptr)\n' \
                >> dlls/wined3d/wined3d.spec; \
        fi && \
        \
        # ddraw hooks
        cp /docker/qemu3dfx_ddraw_hooks.c dlls/ddraw/qemu3dfx_ddraw_hooks.c && \
        grep -q 'qemu3dfx_ddraw_hooks.c' dlls/ddraw/Makefile.in || \
            sed -i 's/^C_SRCS\s*=/C_SRCS = qemu3dfx_ddraw_hooks.c /' dlls/ddraw/Makefile.in && \
        if [ -f dlls/ddraw/ddraw.spec ]; then \
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
                dlls/ddraw/ddraw.spec; \
            grep -q 'AcquireDDThreadLock' dlls/ddraw/ddraw.spec || \
                printf '@ stdcall AcquireDDThreadLock()\n@ stdcall ReleaseDDThreadLock()\n@ stdcall CompleteCreateSysmemSurface(ptr)\n@ stdcall D3DParseUnknownCommand(ptr ptr)\n' \
                    >> dlls/ddraw/ddraw.spec; \
        fi && \
        \
        # ddraw passthrough
        cp /docker/qemu3dfx_ddraw_passthrough.c dlls/ddraw/qemu3dfx_ddraw_passthrough.c && \
        grep -q 'qemu3dfx_ddraw_passthrough.c' dlls/ddraw/Makefile.in || \
            sed -i 's/^C_SRCS\s*=/C_SRCS = qemu3dfx_ddraw_passthrough.c /' dlls/ddraw/Makefile.in && \
        if [ -f dlls/ddraw/main.c ]; then \
            sed -i 's/^BOOL WINAPI DllMain/extern void qemu3dfx_ddraw_passthrough_init(void);\n\nBOOL WINAPI DllMain/' dlls/ddraw/main.c && \
            sed -i 's/DisableThreadLibraryCalls(inst);/DisableThreadLibraryCalls(inst);\n        qemu3dfx_ddraw_passthrough_init();/' dlls/ddraw/main.c; \
        fi && \
        if [ -f dlls/ddraw/ddraw.c ]; then \
            sed -i 's/#include "ddraw_private.h"/#include "ddraw_private.h"\nextern void qemu3dfx_ddraw_cooplevel(DWORD *);/' dlls/ddraw/ddraw.c && \
            sed -i 's/DDRAW_dump_cooperativelevel(cooplevel);/DDRAW_dump_cooperativelevel(cooplevel);\n    qemu3dfx_ddraw_cooplevel(\&cooplevel);/' dlls/ddraw/ddraw.c; \
        fi && \
        if [ -f dlls/ddraw/surface.c ]; then \
            sed -i 's/#include "ddraw_private.h"/#include "ddraw_private.h"\nextern void qemu3dfx_ddraw_blit(void);\nextern void qemu3dfx_ddraw_flip(void);\nextern void qemu3dfx_ddraw_rtv(void *);/' dlls/ddraw/surface.c && \
            sed -i 's/return wined3d_texture_blt(dst_surface/qemu3dfx_ddraw_blit();\n    return wined3d_texture_blt(dst_surface/' dlls/ddraw/surface.c && \
            sed -i 's/return wined3d_device_context_blt(ddraw/qemu3dfx_ddraw_blit();\n    return wined3d_device_context_blt(ddraw/' dlls/ddraw/surface.c && \
            sed -i 's/\(DDSCAPS2\? caps = {DDSCAPS_FLIP.*\)/\1\n    qemu3dfx_ddraw_flip();/' dlls/ddraw/surface.c && \
            sed -i 's/\(tmp_rtv = ddraw_surface_get_rendertarget_view(dst_impl);\)/\1\n    qemu3dfx_ddraw_rtv(tmp_rtv);/' dlls/ddraw/surface.c; \
        fi && \
        \
        # kernel32_compat.c (per-DLL Win98 stubs)
        for dll in wined3d d3d9 d3d8 ddraw; do \
            [ -f "dlls/$dll/Makefile.in" ] || continue; \
            cp /docker/kernel32_compat.c "dlls/$dll/kernel32_compat.c"; \
            grep -q 'kernel32_compat.c' "dlls/$dll/Makefile.in" || \
                sed -i 's/^C_SRCS\s*=/C_SRCS = kernel32_compat.c /' "dlls/$dll/Makefile.in"; \
        done && \
        \
        # GetModuleHandleExW redirect
        for dll in ddraw wined3d d3d9 d3d8; do \
            for f in dlls/$dll/*.c; do \
                [ -f "$f" ] || continue; \
                case "$f" in */kernel32_compat.c) continue ;; esac; \
                grep -q 'GetModuleHandleExW' "$f" 2>/dev/null || continue; \
                sed -i '1i #define GetModuleHandleExW wine_k32compat_GMHEW' "$f"; \
            done; \
        done && \
        for dll in ddraw wined3d d3d9 d3d8; do \
            for f in dlls/$dll/*.c; do \
                [ -f "$f" ] || continue; \
                case "$f" in */kernel32_compat.c) continue ;; esac; \
                for _func in EnumDisplayDevicesW EnumDisplaySettingsW EnumDisplaySettingsExW \
                            GetMonitorInfoW EnumDisplayMonitors MonitorFromWindow MonitorFromPoint \
                            ChangeDisplaySettingsExW IsBadStringPtrW FreeLibraryAndExitThread; do \
                    grep -q "$_func" "$f" 2>/dev/null || continue; \
                    case "$_func" in \
                        EnumDisplayDevicesW) _compat=wine_k32compat_EDD_W ;; \
                        EnumDisplaySettingsW) _compat=wine_k32compat_EDS_W ;; \
                        EnumDisplaySettingsExW) _compat=wine_k32compat_EDSE_W ;; \
                        GetMonitorInfoW) _compat=wine_k32compat_GMI_W ;; \
                        EnumDisplayMonitors) _compat=wine_k32compat_EDM ;; \
                        MonitorFromWindow) _compat=wine_k32compat_MFW ;; \
                        MonitorFromPoint) _compat=wine_k32compat_MFP ;; \
                        ChangeDisplaySettingsExW) _compat=wine_k32compat_CDSE_W ;; \
                        IsBadStringPtrW) _compat=wine_k32compat_IBSP_W ;; \
                        FreeLibraryAndExitThread) _compat=wine_k32compat_FLAET ;; \
                    esac; \
                    sed -i "1i #define $_func $_compat" "$f"; \
                done; \
            done; \
        done && \
        \
        # d3d8_main.c bool fix
        if [ -f dlls/d3d8/d3d8_main.c ]; then \
            sed -i \
                -e 's/BOOL bool,/BOOL bool_val,/g' \
                -e 's/, bool,/, bool_val,/g' \
                -e 's/, bool)/, bool_val)/g' \
                dlls/d3d8/d3d8_main.c; \
        fi && \
        \
        # ── Generate per-directory DLL Makefiles via makedep ──────────────
        # After modifying Makefile.in, run makedep to regenerate the
        # per-directory Makefiles. config.status only creates the top-level
        # Makefile, not DLL subdirectory Makefiles.
        make dlls/wined3d/Makefile dlls/d3d9/Makefile \
            dlls/d3d8/Makefile dlls/ddraw/Makefile \
            dlls/winecrt0/Makefile dlls/dxguid/Makefile \
            dlls/uuid/Makefile 2>/dev/null || \
        for dll in wined3d d3d9 d3d8 ddraw winecrt0 dxguid uuid; do \
            ../wine-${WINE_VERSION}/tools/makedep/makedep dlls/$dll 2>/dev/null || true; \
        done && \
        # Strip wine/libwine from IMPORTS in generated Makefiles (CI lines 1090-1096)
        # and replace -lwine with stub archive path (CI line 1098).
        for mf in dlls/wined3d/Makefile dlls/d3d9/Makefile \
                  dlls/d3d8/Makefile dlls/ddraw/Makefile; do \
            [ -f "$mf" ] || continue; \
            sed -i \
                -e '/^IMPORTS[[:space:]]*=/s/[[:space:]]libwine\([[:space:]]\|$\)//g' \
                -e '/^IMPORTS[[:space:]]*=/s/[[:space:]]wine\([[:space:]]\|$\)//g' \
                "$mf"; \
            sed -i 's/-lwine\([[:space:]]\|$\)/..\/..\/lib\/libwine.a\1/g' "$mf"; \
        done && \
        \
        # ── Spec stripping (after configure regenerates specs) ──────────────
        for spec in dlls/kernel32/kernel32.spec dlls/ntdll/ntdll.spec; do \
            [ -f "$spec" ] || continue; \
            sed -i -e '/GetModuleHandleExW/d' -e '/GlobalMemoryStatusEx/d' \
                   -e '/RtlIsCriticalSectionLockedByThread/d' \
                   -e '/InitOnceBeginInitialize/d' -e '/InitOnceComplete/d' \
                   -e '/InitOnceExecuteOnce/d' -e '/InitOnceInitialize/d' \
                   -e '/InitializeSRWLock/d' \
                   -e '/AcquireSRWLockExclusive/d' -e '/AcquireSRWLockShared/d' \
                   -e '/ReleaseSRWLockExclusive/d' -e '/ReleaseSRWLockShared/d' \
                   -e '/TryAcquireSRWLockExclusive/d' -e '/TryAcquireSRWLockShared/d' \
                   -e '/InitializeConditionVariable/d' \
                   -e '/WakeConditionVariable/d' -e '/WakeAllConditionVariable/d' \
                   -e '/SleepConditionVariableCS/d' -e '/SleepConditionVariableSRW/d' \
                   -e '/GetTickCount64/d' -e '/SetThreadDescription/d' \
                   -e '/IsBadStringPtrW/d' -e '/FreeLibraryAndExitThread/d' \
                   "$spec"; \
        done && \
        for spec in dlls/ntdll/ntdll.spec; do \
            [ -f "$spec" ] || continue; \
            sed -i -e '/_stricmp/d' \
                   -e '/^@.*_vsnprintf/d' -e '/^@.*_snprintf/d' \
                   -e '/^@.*\bsprintf\b/d' -e '/^@.*\bvsprintf\b/d' \
                   -e '/^@.*\bvsnprintf\b/d' -e '/^@.*\bsnprintf\b/d' \
                   -e '/^@.*\bsscanf/d' \
                   -e '/^@.*\bmemcpy\b/d' -e '/^@.*\bmemset\b/d' \
                   -e '/^@.*\bmemmove\b/d' -e '/^@.*\bmemcmp\b/d' -e '/^@.*\bmemchr\b/d' \
                   -e '/^@.*\bstrlen\b/d' -e '/^@.*\bstrcpy\b/d' \
                   -e '/^@.*\bstrcat\b/d' -e '/^@.*\bstrcmp\b/d' -e '/^@.*\bstrncmp\b/d' \
                   -e '/^@.*\bstrchr\b/d' -e '/^@.*\bstrstr\b/d' -e '/^@.*\bstrrchr\b/d' \
                   -e '/^@.*\btolower\b/d' -e '/^@.*\btoupper\b/d' \
                   -e '/^@.*\batoi\b/d' -e '/^@.*\batol\b/d' -e '/^@.*\bstrtol\b/d' \
                   -e '/^@.*\bqsort\b/d' -e '/^@.*\bbsearch\b/d' \
                   -e '/^@.*\bisprint\b/d' -e '/^@.*\bisdigit\b/d' \
                   -e '/^@.*\bisalpha\b/d' -e '/^@.*\bisalnum\b/d' \
                   -e '/^@.*\bisspace\b/d' -e '/^@.*\bisupper\b/d' -e '/^@.*\bislower\b/d' \
                   -e '/^@.*\bisxdigit\b/d' -e '/^@.*\biscntrl\b/d' \
                   -e '/^@.*\bisgraph\b/d' -e '/^@.*\bispunct\b/d' \
                   -e '/^@.*\babs\b/d' -e '/^@.*\bpow\b/d' \
                   -e '/^@.*\bexp\b/d' -e '/^@.*\blog\b/d' \
                   -e '/^@.*\bstrcspn\b/d' -e '/^@.*\bstrnlen\b/d' \
                   -e '/^@.*\bstrtoul\b/d' -e '/^@.*\bfprintf\b/d' \
                   -e '/^@.*\bsin\b/d' -e '/^@.*\btan\b/d' -e '/^@.*\batan\b/d' \
                   -e '/^@.*\bsqrt\b/d' -e '/^@.*\bceil\b/d' -e '/^@.*\bfloor\b/d' \
                   "$spec"; \
        done && \
        for spec in dlls/user32/user32.spec; do \
            [ -f "$spec" ] || continue; \
            sed -i -e '/EnumDisplayDevicesW/d' \
                   -e '/EnumDisplaySettingsExW/d' \
                   -e '/EnumDisplaySettingsW/d' \
                   -e '/GetMonitorInfoW/d' \
                   -e '/EnumDisplayMonitors/d' \
                   -e '/MonitorFromWindow/d' \
                   -e '/MonitorFromPoint/d' \
                   -e '/ChangeDisplaySettingsExW/d' \
                   "$spec"; \
        done && \
        # Strip UCRT from Wine's msvcrt spec (same as modern path)
        for spec in dlls/msvcrt/msvcrt.spec; do \
            [ -f "$spec" ] || continue; \
            sed -i -e '/__acrt_iob_func/d' \
                   -e '/__stdio_common_/d' \
                   -e '/_initterm/d' \
                   "$spec"; \
        done && \
        _ustrip_w="" && \
        for api in \
            EnumDisplayDevicesW@16 EnumDisplaySettingsExW@16 \
            EnumDisplaySettingsW@12 GetMonitorInfoW@8 \
            EnumDisplayMonitors@16 MonitorFromWindow@8 MonitorFromPoint@12 \
        ChangeDisplaySettingsExW@20; do \
            _ustrip_w="$_ustrip_w --strip-symbol _${api} --strip-symbol __imp__${api}"; \
        done && \
        for lib in dlls/user32/libuser32.a \
                   dlls/user32/i386-windows/libuser32.a; do \
            [ -f "$lib" ] || continue; \
            _tmp="$(mktemp).a" && \
            i686-w64-mingw32-objcopy $_ustrip_w "$lib" "$_tmp" 2>/dev/null && \
            mv "$_tmp" "$lib" || rm -f "$_tmp"; \
        done && \
        \
        # Makefile fixes
        find . -name Makefile | xargs sed -i \
            -e 's/-fPIC//g' \
            -e 's/-fstack-protector[^ ]*//g' && \
        if [ -d libs/port ] && [ -f libs/port/libwine_port.a ]; then \
            printf 'all:\nlibwine_port.a:\ninstall clean distclean:\n' \
                > libs/port/Makefile; \
        fi && \
        if [ -d libs/wpp ] && [ -f libs/wpp/libwpp.a ]; then \
            printf 'all:\nlibwpp.a:\ninstall clean distclean:\n' \
                > libs/wpp/Makefile; \
        fi && \
        # Freeze Makefile timestamps so make doesn't re-run makedep/configure
        find . -name 'Makefile.in' | xargs touch -t 200001010000 && \
        touch -t 200001010000 config.status && \
        \
        # libwine stub (matches CI wine-stubs.a profile)
        mkdir -p lib && \
        printf '%s\n' \
            '#include <windows.h>' \
            '#include <stdarg.h>' \
            '#include <stddef.h>' \
            'struct __wine_debug_channel{unsigned char flags;unsigned char name[15];};' \
            'enum __wine_debug_class{__WINE_DBCL_FIXME,__WINE_DBCL_ERR,__WINE_DBCL_WARN,__WINE_DBCL_TRACE};' \
            'unsigned char __cdecl __wine_dbg_get_channel_flags(struct __wine_debug_channel *ch){return 0;}' \
            'int __cdecl __wine_dbg_header(enum __wine_debug_class c,struct __wine_debug_channel *ch,const char *fn){return -1;}' \
            'int __cdecl __wine_dbg_output(const char *s){return 0;}' \
            'int __cdecl wine_dbg_log(enum __wine_debug_class c,struct __wine_debug_channel *ch,const char *fn,const char *fmt,...){return 0;}' \
            'int __cdecl wine_dbg_vlog(enum __wine_debug_class c,struct __wine_debug_channel *ch,const char *fn,const char *fmt,va_list ap){return 0;}' \
            'int __cdecl wine_dbg_printf(const char *fmt,...){return 0;}' \
            'int __cdecl wine_dbg_vprintf(const char *fmt,va_list ap){return 0;}' \
            'const char * __cdecl wine_dbg_sprintf(const char *fmt,...){return "";}' \
            'int __cdecl wine_dbg_vsprintf(char *buf,size_t sz,const char *fmt,va_list ap){if(buf&&sz)buf[0]=0;return 0;}' \
            'const char * __cdecl wine_dbgstr_a(const char *s){return s?s:"(null)";}' \
            'const char * __cdecl wine_dbgstr_an(const char *s,int n){return s?s:"(null)";}' \
            'const char * __cdecl wine_dbgstr_w(const WCHAR *s){return s?"":"";}' \
            'const char * __cdecl wine_dbgstr_wn(const WCHAR *s,int n){return s?"":"";}' \
            'const char * __cdecl wine_get_version(void){return "wine-stubs";}' \
            'const char * __cdecl wine_get_config_dir(void){return "";}' \
            'const char * __cdecl wine_get_data_dir(void){return "";}' \
            'static unsigned short _cmap[128];' \
            'unsigned short *wine_casemap_ascii=_cmap;' \
            'unsigned short __cdecl wine_tolower(unsigned short c){return(c>=65&&c<=90)?c+32:c;}' \
            'unsigned short __cdecl wine_toupper(unsigned short c){return(c>=97&&c<=122)?c-32:c;}' \
            'int __cdecl wine_utf8_wcstombs(int f,const WCHAR *s,int sl,char *d,int dl){return 0;}' \
            'int __cdecl wine_mbstowcs(int f,const char *s,int sl,WCHAR *d,int dl){return 0;}' \
            'int __cdecl wine_fold_string(int f,const WCHAR *s,int sl,WCHAR *d,int dl){return 0;}' \
            'int __cdecl wine_get_sortkey(int f,const WCHAR *s,int sl,char *d,int dl){return 0;}' \
            'int __cdecl wine_compare_string(int f,const WCHAR *s1,int l1,const WCHAR *s2,int l2){return 0;}' \
            > /tmp/libwine_stub.c && \
        i686-w64-mingw32-gcc -O1 -c \
            -D__WINESRC__ -D_WIN32 \
            -o /tmp/libwine_stub.o /tmp/libwine_stub.c && \
        i686-w64-mingw32-ar rcs lib/libwine.a /tmp/libwine_stub.o && \
        # Also install in system MinGW lib dir so winegcc -lwine finds it
        cp lib/libwine.a /usr/i686-w64-mingw32/lib/ && \
        # Nuke all libwine.dll.a from the system (CI lines 1341-1362).
        # Prevent winebuild from generating PE import table entry for libwine.dll.
        find . -name 'libwine.dll.a' -delete 2>/dev/null; \
        find . -name 'libwine.dll' -delete 2>/dev/null; \
        for d in /usr/i686-w64-mingw32/lib \
                 /usr/i686-w64-mingw32/i686-w64-mingw32/lib \
                 /usr/lib/gcc/i686-w64-mingw32/*/; do \
            rm -f "$d/libwine.dll.a" "$d/libwine.dll" 2>/dev/null || true; \
        done && \
        # Neuter libs/wine/Makefile to prevent regenerating libwine.dll.a (CI line 1349)
        if [ -d libs/wine ]; then \
            printf 'all:\nlibwine.a:\ninstall clean distclean:\n' > libs/wine/Makefile; \
        fi && \
        \
        # debug.c fwrite → WriteFile patch
        if [ -f dlls/winecrt0/debug.c ]; then \
            sed -i \
                -e 's|return fwrite( str, 1, len, stderr );|{ DWORD _nw=0; WriteFile(GetStdHandle(STD_ERROR_HANDLE),str,len,\&_nw,NULL); return _nw; }|' \
                -e 's|return fwrite( buffer, 1, strlen(buffer), stderr );|{ DWORD _nw=0; WriteFile(GetStdHandle(STD_ERROR_HANDLE),buffer,strlen(buffer),\&_nw,NULL); return _nw; }|' \
                dlls/winecrt0/debug.c; \
        fi && \
        \
        # ── Build DLLs ──────────────────────────────────────────────────────
        # Place system MinGW import libs into the Wine build tree.
        # winegcc searches $WINE_OBJDIR/dlls for libfoo.a (winegcc.c:823),
        # and Makefile deps reference ../../dlls/foo/libfoo.a.
        # winebuild --implib can produce broken libs for older Wine versions,
        # so we always use the system MinGW import libs (which have all exports).
        for dll in user32 gdi32 advapi32 kernel32 opengl32 ntdll setupapi; do \
            sys="/usr/i686-w64-mingw32/lib/lib$dll.a"; \
            [ -f "$sys" ] || continue; \
            mkdir -p "dlls/$dll"; \
            cp "$sys" "dlls/$dll/lib$dll.a"; \
            cp "$sys" "dlls/lib$dll.a"; \
        done && \
        make -j$(nproc) -C dlls/winecrt0 2>/dev/null || true && \
        # Build dxguid and uuid (needed by ddraw/d3d9/d3d8 for GUID imports).
        # Generate Makefiles first, then build. Fall back to system lib on failure.
        make dlls/dxguid/Makefile dlls/uuid/Makefile 2>/dev/null || true && \
        for gdll in dxguid uuid; do \
            if [ -d "dlls/$gdll" ]; then \
                make -j$(nproc) -C "dlls/$gdll" 2>/dev/null || \
                cp "/usr/i686-w64-mingw32/lib/lib$gdll.a" "dlls/$gdll/" 2>/dev/null || true; \
            else \
                mkdir -p "dlls/$gdll" && \
                cp "/usr/i686-w64-mingw32/lib/lib$gdll.a" "dlls/$gdll/" 2>/dev/null || true; \
            fi; \
        done && \
        make -j$(nproc) -C dlls/wined3d && \
        # Generate wined3d import library.
        # winebuild --implib produces empty/broken PE import libs on Linux
        # cross-compilation for legacy Wine versions. Use def+dlltool instead.
        echo "=== Generating wined3d import lib via def+dlltool ===" && \
        ../wine-${WINE_VERSION}/tools/winebuild/winebuild \
            --def -o /tmp/wined3d.def \
            --export dlls/wined3d/wined3d.spec && \
        i686-w64-mingw32-dlltool \
            -d /tmp/wined3d.def -l dlls/wined3d/libwined3d.a && \
        cp dlls/wined3d/libwined3d.a dlls/libwined3d.a && \
        echo "=== wined3d import lib: checking mutex_lock ===" && \
        i686-w64-mingw32-nm dlls/wined3d/libwined3d.a 2>/dev/null | grep mutex_lock | head -3 && \
        for dll in d3d9 d3d8 ddraw; do \
            make -j$(nproc) -C dlls/$dll $dll.dll 2>/dev/null || \
            make -j$(nproc) -C dlls/$dll; \
        done && \
        if [ "$BUILD_MSVCRT" = "1" ]; then \
            if [ -f include/msvcrt/corecrt_wstring.h ]; then \
                sed -i \
                    -e 's/wcstok(wchar_t\*,const wchar_t\*,wchar_t\*\*)/wcstok(wchar_t*,const wchar_t*)/' \
                    -e 's/return wcstok(str, delim, NULL)/return wcstok(str, delim)/' \
                    include/msvcrt/corecrt_wstring.h; \
            fi && \
            make -j$(nproc) -C dlls/msvcrt msvcrt.dll; \
        fi && \
        cp dlls/wined3d/wined3d.dll \
           dlls/d3d9/d3d9.dll \
           dlls/d3d8/d3d8.dll \
           dlls/ddraw/ddraw.dll \
           /output/${WINE_VERSION}/ && \
        if [ "$BUILD_MSVCRT" = "1" ]; then \
            cp dlls/msvcrt/msvcrt.dll /output/${WINE_VERSION}/; \
        fi; \
    fi && \
    \
    # ── Post-build: ucrtbase → msvcrt binary patch ─────────────────────────
    python3 -c "import os,glob;[open(p,'wb').write(d.replace(b'ucrtbase.dll\x00',b'msvcrt.dll\x00\x00\x00')) or print('Patched:',os.path.basename(p)) for p in glob.glob('/output/${WINE_VERSION}/*.dll') for d in [open(p,'rb').read()] if b'ucrtbase.dll\x00' in d]" && \
    \
    printf "Built on %s\n  binutils %s\n  crt-git %s\n  gcc-libs %s\n" \
        "$(date '+%T %b %-e %Y')" \
        "$(pacman -Q mingw-w64-binutils | awk '{print $2}')" \
        "$(pacman -Q mingw-w64-crt-git  | awk '{print $2}')" \
        "$(pacman -Q gcc-libs           | awk '{print $2}')" \
        > /output/${WINE_VERSION}/build-timestamp && \
    chmod +x /output/${WINE_VERSION}/build-timestamp && \
    cd / && rm -rf wine-${WINE_VERSION} wine-${WINE_VERSION}-cross
