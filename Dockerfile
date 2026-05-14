FROM --platform=linux/amd64 archlinux:base-devel

# ── Layer 1: system packages (pinned toolchain for Win98-compatible PE) ──
# Reference working build: binutils 2.44-1, gcc 14.2.0-3
RUN sed -i '/^#\[multilib\]/{N;s/#\[multilib\]\n#Include/\[multilib\]\nInclude/}' /etc/pacman.conf && \
    echo -e "IgnorePkg = mingw-w64-gcc mingw-w64-binutils" \
        >> /etc/pacman.conf && \
    pacman-key --init && \
    pacman -Syu --noconfirm --disable-sandbox && \
    pacman -S --noconfirm --disable-sandbox \
        git wget \
        mingw-w64-headers mingw-w64-winpthreads \
        flex bison mesa \
        lib32-gcc-libs lib32-glibc && \
    pacman -U --noconfirm --disable-sandbox \
        https://archive.archlinux.org/packages/m/mingw-w64-gcc/mingw-w64-gcc-14.2.0-3-x86_64.pkg.tar.zst \
        https://archive.archlinux.org/packages/m/mingw-w64-binutils/mingw-w64-binutils-2.44-1-x86_64.pkg.tar.zst && \
    echo "=== Toolchain ===" && \
    i686-w64-mingw32-ld --version | head -1 && \
    i686-w64-mingw32-gcc --version | head -1

# ── Layer 2: Build CRT from reference commit ────────────────────────
# Pin to ea22a99cb (12.0.0+480 commits) — same CRT as the working reference build.
RUN git clone https://github.com/mingw-w64/mingw-w64.git /tmp/mingw-w64 && \
    cd /tmp/mingw-w64 && \
    git checkout ea22a99cb06640697c45657e17bd5cb9603e62d7 && \
    \
    mkdir -p /tmp/headers-build && cd /tmp/headers-build && \
    /tmp/mingw-w64/mingw-w64-headers/configure \
        --host=i686-w64-mingw32 --prefix=/usr/i686-w64-mingw32 \
        --enable-sdk=all && \
    make -j$(nproc) install && \
    \
    mkdir -p /tmp/crt-build && cd /tmp/crt-build && \
    /tmp/mingw-w64/mingw-w64-crt/configure \
        --host=i686-w64-mingw32 --prefix=/usr/i686-w64-mingw32 \
        --with-default-msvcrt=msvcrt && \
    make -j$(nproc) && \
    make install && \
    \
    echo "=== CRT built from mingw-w64 commit $(cd /tmp/mingw-w64 && git rev-parse --short HEAD) ===" && \
    rm -rf /tmp/mingw-w64 /tmp/headers-build /tmp/crt-build

ARG WINE_VERSION=8.0.2
ARG WINE_BRANCH=8.0
ARG WINE_EXT=tar.xz

# ── Source files for qemu-3dfx ──────────────────────────────────────
COPY qemu3dfx_hooks.c /docker/qemu3dfx_hooks.c
COPY qemu3dfx_ddraw_hooks.c /docker/qemu3dfx_ddraw_hooks.c
COPY qemu3dfx_ddraw_passthrough.c /docker/qemu3dfx_ddraw_passthrough.c
COPY docker/d3dkmt_stubs.c /docker/d3dkmt_stubs.c
COPY docker/kernel32_compat.c /docker/kernel32_compat.c
COPY docker/nocrt_entry.c /docker/nocrt_entry.c
COPY docker/patch_pe_win98.py /docker/patch_pe_win98.py


# ── Build layer: wine9x direct compilation ──────────────────────────
RUN \
    # ══════════════════════════════════════════════════════════════════
    #  TOOLCHAIN SETUP
    # ══════════════════════════════════════════════════════════════════
    \
    # ── Force msvcrt via gcc wrapper ──────────────────────────────────
    mv /usr/bin/i686-w64-mingw32-gcc /usr/bin/i686-w64-mingw32-gcc.orig && \
    \
    # ── Rename __acrt_iob_func → __iob_func in CRT archives ──────
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
    # ── ucrtcompat stubs into libmsvcrt.a ─────────────────────────
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
    echo '__asm__(".globl __imp____stdio_common_vsprintf\n.section .rdata,\"dr\"\n.align 4\n__imp____stdio_common_vsprintf:\n    .long ___stdio_common_vsprintf\n.globl __imp____stdio_common_vfprintf\n.align 4\n__imp____stdio_common_vfprintf:\n    .long ___stdio_common_vfprintf\n.globl __imp____stdio_common_vsscanf\n.align 4\n__imp____stdio_common_vsscanf:\n    .long ___stdio_common_vsscanf\n.text\n");' \
        >> /tmp/ucrtcompat.c && \
    /usr/bin/i686-w64-mingw32-gcc.orig -nostdinc -c \
        /tmp/ucrtcompat.c -o /tmp/ucrtcompat.o && \
    i686-w64-mingw32-ar rs \
        /usr/i686-w64-mingw32/lib/libmsvcrt.a /tmp/ucrtcompat.o && \
    \
    # ── gcc wrapper ────────────────────────────────────────────────────
    printf '#!/bin/sh\nexec /usr/bin/i686-w64-mingw32-gcc.orig -mcrtdll=msvcrt -D__MSVCRT__ -U_UCRT "$@"\n' \
        > /usr/bin/i686-w64-mingw32-gcc && \
    chmod +x /usr/bin/i686-w64-mingw32-gcc && \
    \
    # ══════════════════════════════════════════════════════════════════
    #  WINE9X + PTHREAD9X
    # ══════════════════════════════════════════════════════════════════
    \
    git clone https://github.com/crag-hack/wine9x.git /wine9x && \
    cd /wine9x && git submodule update --init --remote --merge && cd / && \
    \
    cd /wine9x/pthread9x && \
    mkdir -p build && cd build && \
    PT_CFLAGS="-std=gnu99 -O3 -fno-exceptions -march=pentium2 -mtune=core2 \
               -I../include -I. -DNDEBUG -DHAVE_CONFIG_H -DIN_WINPTHREAD \
               -Wall -DWIN32_LEAN_AND_MEAN -DNEW_ALLOC" && \
    for src in src/barrier.c src/cond.c src/misc.c src/mutex.c src/rwlock.c \
               src/spinlock.c src/thread.c src/ref.c src/sem.c src/sched.c \
               src/clock.c src/nanosleep.c src/tryentercriticalsection.c \
               extra/memory.c extra/int64.c extra/lockex.c; do \
        obj="$(basename "${src%.c}").o" && \
        i686-w64-mingw32-gcc $PT_CFLAGS -c -o "$obj" "../$src"; \
    done && \
    i686-w64-mingw32-ar rcs -o libpthread.a barrier.o cond.o misc.o mutex.o rwlock.o \
        spinlock.o thread.o ref.o sem.o sched.o clock.o nanosleep.o \
        tryentercriticalsection.o memory.o int64.o lockex.o && \
    i686-w64-mingw32-gcc $PT_CFLAGS -c -o crtfix.o ../extra/crtfix.c && \
    cd / && \
    \
    # ══════════════════════════════════════════════════════════════════
    #  DOWNLOAD WINE SOURCE
    # ══════════════════════════════════════════════════════════════════
    \
    URL="https://dl.winehq.org/wine/source/${WINE_BRANCH}/wine-${WINE_VERSION}.${WINE_EXT}" && \
    wget "$URL" && \
    tar xf wine-${WINE_VERSION}.${WINE_EXT} && \
    mkdir -p /output/${WINE_VERSION} && \
    cd wine-${WINE_VERSION} && \
    \
    # ══════════════════════════════════════════════════════════════════
    #  QEMU-3DFX PATCHES
    # ══════════════════════════════════════════════════════════════════
    \
    # ── wined3d: d3dkmt stubs + qemu-3dfx hooks ───────────────────────
    cp /docker/d3dkmt_stubs.c dlls/wined3d/d3dkmt_stubs.c && \
    cp /docker/qemu3dfx_hooks.c dlls/wined3d/qemu3dfx_hooks.c && \
    if [ -f dlls/wined3d/wined3d.spec ] && \
       ! grep -q 'wined3d_hal_3dfx' dlls/wined3d/wined3d.spec; then \
        printf '\n@ stdcall wined3d_hal_3dfx()\n@ stdcall wined3d_enum_hal_last()\n@ stdcall wined3d_surface_ddheap()\n@ stdcall wined3d_passthru(ptr)\n@ stdcall wined3d_override_cooplevel(ptr)\n@ stdcall wined3d_override_rendertarget_view(ptr)\n@ stdcall wined3d_blit_fpslimit()\n@ stdcall wined3d_flip_fpslimit()\n@ stdcall wined3d_get_gamma_ramp_3dfx(ptr ptr)\n@ stdcall wined3d_set_gamma_ramp_3dfx(ptr ptr)\n@ stdcall wined3d_set_cursor_3dfx(ptr ptr)\n' \
            >> dlls/wined3d/wined3d.spec; \
    fi && \
    \
    # ── ddraw: hooks + passthrough ─────────────────────────────────────
    cp /docker/qemu3dfx_ddraw_hooks.c dlls/ddraw/qemu3dfx_ddraw_hooks.c && \
    cp /docker/qemu3dfx_ddraw_passthrough.c dlls/ddraw/qemu3dfx_ddraw_passthrough.c && \
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
    # ── ddraw source patches ──────────────────────────────────────────
    if [ -f dlls/ddraw/main.c ]; then \
        sed -i 's/^BOOL WINAPI DllMain/extern void qemu3dfx_ddraw_passthrough_init(void);\n\nBOOL WINAPI DllMain/' dlls/ddraw/main.c && \
        sed -i 's/DisableThreadLibraryCalls(inst);/DisableThreadLibraryCalls(inst);\n        qemu3dfx_ddraw_passthrough_init();/' dlls/ddraw/main.c && \
        sed -i '/#include "wine\/exception.h"/d' dlls/ddraw/main.c && \
        find dlls/ddraw -name '*.c' -exec sed -i '/#include "wine\/exception.h"/d' {} + && \
        sed -i 's/return __wine_register_resources( instance );/return S_OK;/' dlls/ddraw/main.c && \
        sed -i 's/return __wine_unregister_resources( instance );/return S_OK;/' dlls/ddraw/main.c; \
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
    # ── d3d8_main.c bool fix ──────────────────────────────────────────
    if [ -f dlls/d3d8/d3d8_main.c ]; then \
        sed -i \
            -e 's/BOOL bool,/BOOL bool_val,/g' \
            -e 's/, bool,/, bool_val,/g' \
            -e 's/, bool)/, bool_val)/g' \
            dlls/d3d8/d3d8_main.c; \
    fi && \
    \
    # ── RtlIsCriticalSectionLockedByThread redirect (3.0.5+) ──
    if [ -f dlls/wined3d/cs.c ]; then \
        sed -i 's/!RtlIsCriticalSectionLockedByThread(NtCurrentTeb()->Peb->LoaderLock)/1/' dlls/wined3d/cs.c; \
    fi && \
    \
    # ── Strip Win98-incompatible API calls ──
    # GetModuleHandleExW in ddraw/main.c → just use inst
    for f in dlls/ddraw/main.c; do \
        [ -f "$f" ] || continue; \
        perl -i -p0e 's/if \(!GetModuleHandleExW\(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS \| GET_MODULE_HANDLE_EX_FLAG_PIN,\s*\n\s*\(const WCHAR \*\)&ddraw_self, &ddraw_self\)\)\s*\n\s*ERR\("Failed to get own module handle\.\\n"\);/ddraw_self = inst;/g' "$f"; \
    done && \
    \
    # ── W-version API redirects → kernel32_compat wrappers ──
    for f in dlls/wined3d/*.c; do \
        [ -f "$f" ] || continue; \
        case "$f" in */kernel32_compat.c|*/d3dkmt_stubs.c|*/qemu3dfx_hooks.c) continue ;; esac; \
        for _func in EnumDisplayDevicesW EnumDisplaySettingsW EnumDisplaySettingsExW \
                    GetMonitorInfoW EnumDisplayMonitors MonitorFromWindow MonitorFromPoint \
                    ChangeDisplaySettingsExW IsBadStringPtrW FreeLibraryAndExitThread \
                    GetModuleHandleExW \
	                    GetVersionExW; do \
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
                GetModuleHandleExW) _compat=wine_k32compat_GMHEW ;; \
                GetVersionExW) _compat=wine_k32compat_GVXW ;; \
            esac; \
            sed -i "1i #define $_func $_compat" "$f"; \
        done; \
    done && \
    for f in dlls/ddraw/*.c; do \
        [ -f "$f" ] || continue; \
        case "$f" in */kernel32_compat.c|*/qemu3dfx_ddraw*) continue ;; esac; \
        grep -q 'GetModuleHandleExW' "$f" 2>/dev/null || continue; \
        sed -i '1i #define GetModuleHandleExW wine_k32compat_GMHEW' "$f"; \
    done && \
    \
    # ══════════════════════════════════════════════════════════════════
    #  HEADER SETUP
    # ══════════════════════════════════════════════════════════════════
    \
    mv /wine9x/include/wine/wined3d.h /wine9x/include/wine/wined3d.h.wine9x && \
    for h in wgl_driver.h wgl.h wglext.h; do \
        [ -f "/wine9x/include/wine/$h" ] && mv "/wine9x/include/wine/$h" "/wine9x/include/wine/$h.wine9x"; \
    done && \
    \
    # ── Fix DWORD vs unsigned int mismatches (Wine 5.x-7.x only) ───────
    if grep -q 'context_invalidate_state.*DWORD' dlls/wined3d/wined3d_private.h 2>/dev/null; then \
        for f in dlls/wined3d/context.c; do \
            [ -f "$f" ] && sed -i 's/void context_invalidate_state(struct wined3d_context \*context, unsigned int state_id)/void context_invalidate_state(struct wined3d_context *context, DWORD state_id)/' "$f"; \
        done; \
        for f in dlls/wined3d/device.c; do \
            [ -f "$f" ] && sed -i 's/void device_invalidate_state(const struct wined3d_device \*device, unsigned int state_id)/void device_invalidate_state(const struct wined3d_device *device, DWORD state_id)/' "$f"; \
        done; \
        for f in dlls/wined3d/texture.c; do \
            [ -f "$f" ] && sed -i 's/struct wined3d_context \*context, unsigned int location)/struct wined3d_context *context, DWORD location)/' "$f"; \
        done; \
    fi && \
    \
    # ── qemu-3dfx: skip expensive GL context re-setup in needs_set branch ──
    for f in dlls/wined3d/context.c; do \
        [ -f "$f" ] || continue; \
        if grep -q 'else if (context->needs_set)' "$f"; then \
            sed -i '/else if (context->needs_set)/,/}/ s/context_set_gl_context(context);/context_enter(context);/' "$f"; \
        elif grep -q 'else if (context_gl->needs_set)' "$f"; then \
            sed -i '/else if (context_gl->needs_set)/,/}/ s/wined3d_context_gl_set_gl_context(context_gl);/wined3d_context_gl_enter(context_gl);/' "$f"; \
        fi; \
    done && \
    \
    # ── Strip DUMMYUNIONNAME access from wined3d sources ──
    for f in dlls/wined3d/*.c; do \
        [ -f "$f" ] && sed -i 's/\.u[0-9][0-9]*\.s[0-9][0-9]*\./\./g; s/\.u[0-9][0-9]*\./\./g; s#->u[0-9][0-9]*\.s[0-9][0-9]*\.#->#g; s#->u[0-9][0-9]*\.#->#g' "$f"; \
    done && \
    [ -f dlls/wined3d/directx.c ] && \
        sed -i 's/\.u\./\./g; s#->u\.#->#g' dlls/wined3d/directx.c && \
    \
    # ── Fix RTL_CRITICAL_SECTION_DEBUG Spare field ──
    for f in dlls/wined3d/wined3d_private.h; do \
        [ -f "$f" ] && sed -i 's/->Spare\[0\] *=.*;/;/' "$f"; \
    done && \
    \
    # ── Wine 8.0.2 vkd3d/d3d12 stub headers ────────────────────────────
    printf '#ifndef VKD3D_STUB_H\n#define VKD3D_STUB_H\n#include <stdarg.h>\ntypedef void (*PFN_vkd3d_log_callback)(const char *, va_list);\nstatic inline void vkd3d_set_log_callback(PFN_vkd3d_log_callback cb) { (void)cb; }\n#endif\n' > include/vkd3d.h && \
    printf '#ifndef D3D12_STUB_H\n#define D3D12_STUB_H\n#endif\n' > include/d3d12.h && \
    \
    # ── Hollow out vkd3d_log_callback ──
    sed -i '/^static void vkd3d_log_callback/,/^}/c\static void vkd3d_log_callback(const char *fmt, va_list args) {}' dlls/wined3d/wined3d_main.c && \
    \
    # ── Remove spirv_shader_backend_cleanup call ──
    sed -i '/wined3d_spirv_shader_backend_cleanup/d' dlls/wined3d/wined3d_main.c && \
    \
    # ══════════════════════════════════════════════════════════════════
    #  GENERATE .DEF FILES FROM .SPEC
    # ══════════════════════════════════════════════════════════════════
    \
    for dll in wined3d d3d9 d3d8 ddraw; do \
        spec="dlls/$dll/$dll.spec"; \
        [ -f "$spec" ] || continue; \
        echo "EXPORTS" > "/tmp/$dll.def"; \
        grep -E '^\s*@\s+(stdcall|cdecl)' "$spec" | \
            grep -v '\-private' | \
            sed -E 's/^\s*@\s+(stdcall|cdecl)(\s+-(noname|ordinal|stub|ignore))*\s+([A-Za-z_][A-Za-z0-9_]*).*/\4/' | \
            grep -v '^$' >> "/tmp/$dll.def"; \
        if [ "$dll" = "wined3d" ]; then \
            for sym in malloc free realloc calloc strdup _strdup _expand _msize \
                       _msize_int strtoull strtoll \
                       crt_locks_init crt_sse2_is_safe crt_enable_sse2; do \
                echo "$sym" >> "/tmp/$dll.def"; \
            done; \
        fi; \
    done && \
    \
    # ── Generate vkd3d stubs (Wine 8.0.2) ──
    if grep -q 'vkd3d' dlls/wined3d/wined3d.spec 2>/dev/null; then \
        grep -E '^\s*@\s+(stdcall|cdecl)\s+vkd3d' dlls/wined3d/wined3d.spec | \
            sed -E 's/^\s*@\s+(stdcall|cdecl)\s+([A-Za-z_][A-Za-z0-9_]*).*/int \2() { return 0; }/' \
            > /tmp/vkd3d_stubs.c && \
        echo "  Generating vkd3d stubs ($(grep -c 'return 0' /tmp/vkd3d_stubs.c) functions)"; \
    fi && \
    \
    # ══════════════════════════════════════════════════════════════════
    #  COMPILE + LINK
    # ══════════════════════════════════════════════════════════════════
    \
    CC=i686-w64-mingw32-gcc && \
    printf '#define ARRAY_SIZE(x) (sizeof(x)/sizeof((x)[0]))\n' > /tmp/array_size.h && \
    printf '#define __WINE_ALLOC_SIZE(...)\n#define __WINE_MALLOC\n' > /tmp/wine_alloc_size.h && \
    CFLAGS="-std=c99 -O3 -fomit-frame-pointer \
        -Wno-discarded-qualifiers -Wno-write-strings -Wno-cast-qual \
        -Wno-incompatible-pointer-types \
        -D_WIN32 -DWIN32 -D__WINESRC__ \
        -DUSE_WIN32_OPENGL -DWINE_NOWINSOCK \
        -D_USE_MATH_DEFINES \
        -DInterlockedExchangeAddSizeT=InterlockedExchangeAdd \
        -DNDEBUG -DWINE_UNICODE_API=\"\" \
        -DWINE_SILENT -DWINE_NO_TRACE_MSGS -DWINE_NO_DEBUG_MSGS \
        -DDECLSPEC_HIDDEN= -D__GNU_EXTENSION= \
        -DDECLSPEC_HOTPATCH= \
        -DDCX_USESTYLE=0x00010000 \
        -include /tmp/array_size.h \
        -include /tmp/wine_alloc_size.h \
        -DDLLDIR=\"\" -DBINDIR=\"\" -DLIB_TO_BINDIR=\"\" \
        -DLIB_TO_DLLDIR=\"\" -DBIN_TO_DLLDIR=\"\" \
        -DLIB_TO_DATADIR=\"\" -DBIN_TO_DATADIR=\"\" \
        -DWINVER=0x0400 \
        -march=pentium2 -mtune=core2 \
        -fdata-sections -ffunction-sections \
        -include stdint.h \
        -I/wine9x/mingw -I/wine9x/include/wine \
        -I/wine9x/compact -I/wine9x/pthread9x/include -I/wine9x/pthread9x/build \
        -idirafter /wine9x/include \
        -idirafter include \
        -DVBOX_WITH_WINE_FIX_IBMTMR \
        -DVBOX_WITH_WINE_FIX_QUIRKS \
        -DVBOX_WITH_WINE_FIX_PBOPSM \
        -DVBOX_WITH_WINE_FIX_INITCLEAR \
        -DVBOX_WITH_WINE_FIX_BUFOFFSET \
        -DVBOX_WITH_WINE_FIX_STRINFOBUF \
        -DVBOX_WITH_WINE_FIX_CURVBO \
        -DVBOX_WITH_WINE_FIX_FTOA \
        -DVBOX_WITH_WINE_FIX_SURFUPDATA \
        -DVBOX_WITH_WINE_FIX_TEXCLEAR \
        -DVBOX_WITH_WINE_FIX_SHADERCLEANUP \
        -DVBOX_WITH_WINE_FIX_SHADER_DECL \
        -DVBOX_WITH_WINE_FIXES \
        -DVBOX_WITH_WINE_FIX_POLYOFFSET_SCALE \
        -DVBOX_WITH_WINE_FIX_ZEROVERTATTR \
        -DVBOX_WITH_WINE_FIX_MUTE_ERRORS \
        -DVBOX_WITH_WINE_FIX_BLIT_ALPHATEST \
        -DUSE_HOOKS" && \
    \
    # ── wined3d ────────────────────────────────────────────────────────
    echo "=== Compiling wined3d ===" && \
    mkdir -p /tmp/obj_wined3d && \
    WINE3D_SRCS=$(sed -n '/^C_SRCS/,/^[A-Z]/p' dlls/wined3d/Makefile.in | \
        grep -v '^C_SRCS' | grep -v '^[A-Z]' | \
        sed 's/\\//g' | tr ' ' '\n' | grep '\.c$' | grep -v '_vk\.c' | grep -v 'shader_spirv\.c' | sort -u) && \
    WINE3D_SRCS="$WINE3D_SRCS d3dkmt_stubs.c qemu3dfx_hooks.c" && \
    for src in $WINE3D_SRCS; do \
        [ -f "dlls/wined3d/$src" ] || continue; \
        echo "  CC wined3d/$src"; \
        $CC $CFLAGS -Idlls/wined3d -c -o "/tmp/obj_wined3d/${src%.c}.o" "dlls/wined3d/$src" 2>&1 | grep -i error || true; \
    done && \
    echo "  CC wined3d/debug.c" && \
    $CC $CFLAGS -c -o /tmp/obj_wined3d/_debug.o /wine9x/compact/debug.c 2>/dev/null || true && \
    echo "  CC wined3d/kernel32_compat.c" && \
    $CC $CFLAGS -DK32COMPAT_DISPLAY_WRAPPERS -c -o /tmp/obj_wined3d/_kernel32_compat.o /docker/kernel32_compat.c 2>/dev/null || true && \
    echo "  CC nocrt_entry.c" && \
    $CC $CFLAGS -c -o /tmp/_nocrt_entry.o /docker/nocrt_entry.c && \
    echo "  Generating Vulkan stubs from undefined symbols" && \
    nm /tmp/obj_wined3d/*.o 2>/dev/null | grep ' U ' | grep 'vk' | \
        awk '{gsub(/^_/,"",$2); print $2}' | sort -u | \
        awk '{print "int " $1 "() { return 0; }"}' > /tmp/vk_stubs.c && \
    $CC $CFLAGS -c -o /tmp/obj_wined3d/_vk_stubs.o /tmp/vk_stubs.c 2>/dev/null || true && \
    if [ -f /tmp/vkd3d_stubs.c ]; then \
        echo "  CC wined3d/vkd3d_stubs.c" && \
        $CC $CFLAGS -c -o /tmp/obj_wined3d/_vkd3d_stubs.o /tmp/vkd3d_stubs.c 2>/dev/null || true; \
    fi && \
    echo "  LD wined3d.dll" && \
    $CC -shared -static-libgcc \
        -o /tmp/wined3d.dll \
        /tmp/obj_wined3d/*.o \
        /tmp/_nocrt_entry.o \
        /wine9x/pthread9x/build/crtfix.o \
        -L/wine9x/pthread9x/build -lpthread \
        -lgdi32 -lopengl32 \
        -Wl,--allow-multiple-definition \
        -Wl,--out-implib,/tmp/libwined3d.a \
        -Wl,--enable-stdcall-fixup \
        -Wl,--image-base,0x10000000 \
        /tmp/wined3d.def && \
    cp /tmp/wined3d.dll /output/${WINE_VERSION}/ && \
    echo "  Built wined3d.dll" && \
    \
    # ── d3d9 ───────────────────────────────────────────────────────────
    echo "=== Compiling d3d9 ===" && \
    mkdir -p /tmp/obj_d3d9 && \
    for src in $(find dlls/d3d9 -maxdepth 1 -name '*.c' | sed 's|.*/||' | sort); do \
        echo "  CC d3d9/$src"; \
        $CC $CFLAGS -Idlls/d3d9 -c -o "/tmp/obj_d3d9/${src%.c}.o" "dlls/d3d9/$src" 2>&1 | grep -i error || true; \
    done && \
    $CC $CFLAGS -c -o /tmp/obj_d3d9/_debug.o /wine9x/compact/debug.c 2>/dev/null || true && \
    $CC $CFLAGS -c -o /tmp/obj_d3d9/_kernel32_compat.o /docker/kernel32_compat.c 2>/dev/null || true && \
    echo "  LD d3d9.dll" && \
    $CC -shared -static-libgcc \
        -o /tmp/d3d9.dll \
        /tmp/obj_d3d9/*.o \
        /tmp/_nocrt_entry.o \
        /wine9x/pthread9x/build/crtfix.o \
        -L/tmp -lwined3d -lgdi32 \
        -Wl,--allow-multiple-definition \
        -Wl,--out-implib,/tmp/libd3d9.a \
        -Wl,--enable-stdcall-fixup \
        -Wl,--image-base,0x10000000 \
        /tmp/d3d9.def && \
    cp /tmp/d3d9.dll /output/${WINE_VERSION}/ && \
    echo "  Built d3d9.dll" && \
    \
    # ── d3d8 ───────────────────────────────────────────────────────────
    echo "=== Compiling d3d8 ===" && \
    mkdir -p /tmp/obj_d3d8 && \
    for src in $(find dlls/d3d8 -maxdepth 1 -name '*.c' | sed 's|.*/||' | sort); do \
        echo "  CC d3d8/$src"; \
        $CC $CFLAGS -Idlls/d3d8 -c -o "/tmp/obj_d3d8/${src%.c}.o" "dlls/d3d8/$src" 2>&1 | grep -i error || true; \
    done && \
    $CC $CFLAGS -c -o /tmp/obj_d3d8/_debug.o /wine9x/compact/debug.c 2>/dev/null || true && \
    $CC $CFLAGS -c -o /tmp/obj_d3d8/_kernel32_compat.o /docker/kernel32_compat.c 2>/dev/null || true && \
    echo "  LD d3d8.dll" && \
    $CC -shared -static-libgcc \
        -o /tmp/d3d8.dll \
        /tmp/obj_d3d8/*.o \
        /tmp/_nocrt_entry.o \
        /wine9x/pthread9x/build/crtfix.o \
        -L/tmp -lwined3d -lgdi32 \
        -Wl,--allow-multiple-definition \
        -Wl,--out-implib,/tmp/libd3d8.a \
        -Wl,--enable-stdcall-fixup \
        -Wl,--image-base,0x10000000 \
        /tmp/d3d8.def && \
    cp /tmp/d3d8.dll /output/${WINE_VERSION}/ && \
    echo "  Built d3d8.dll" && \
    \
    # ── ddraw ──
    echo "=== Compiling ddraw ===" && \
    DDRAW_CFLAGS="$CFLAGS -DDUMMYUNIONNAME= -DDUMMYUNIONNAME1= -DDUMMYUNIONNAME2= -DDUMMYUNIONNAME3= -DDUMMYUNIONNAME4= -DDUMMYUNIONNAME5= -DDUMMYUNIONNAME6= -DDUMMYUNIONNAME7= -DDUMMYUNIONNAME8=" && \
    DDRAW_CFLAGS="$DDRAW_CFLAGS -Idlls/ddraw -DDECL_WINELIB_TYPE_AW(type)= -DWINELIB_NAME_AW(func)=func##A -D__MSABI_LONG(x)=x##l -DINITGUID -D__TRY=if(1) -D__EXCEPT_PAGE_FAULT=else -D__ENDTRY=" && \
    mkdir -p /tmp/obj_ddraw && \
    for src in $(find dlls/ddraw -maxdepth 1 -name '*.c' | sed 's|.*/||' | sort); do \
        echo "  CC ddraw/$src"; \
        $CC $DDRAW_CFLAGS -Idlls/ddraw -c -o "/tmp/obj_ddraw/${src%.c}.o" "dlls/ddraw/$src" 2>&1 | grep -i error || true; \
    done && \
    $CC $CFLAGS -c -o /tmp/obj_ddraw/_debug.o /wine9x/compact/debug.c 2>/dev/null || true && \
    $CC $CFLAGS -c -o /tmp/obj_ddraw/_kernel32_compat.o /docker/kernel32_compat.c 2>/dev/null || true && \
    echo "  LD ddraw.dll" && \
    $CC -shared -static-libgcc \
        -o /tmp/ddraw.dll \
        /tmp/obj_ddraw/*.o \
        /tmp/_nocrt_entry.o \
        /wine9x/pthread9x/build/crtfix.o \
        -L/tmp -lwined3d -luser32 -lgdi32 -ladvapi32 \
        -Wl,--allow-multiple-definition \
        -Wl,--out-implib,/tmp/libddraw.a \
        -Wl,--enable-stdcall-fixup \
        -Wl,--image-base,0x10000000 \
        /tmp/ddraw.def && \
    cp /tmp/ddraw.dll /output/${WINE_VERSION}/ && \
    echo "  Built ddraw.dll" && \
    \
    # ══════════════════════════════════════════════════════════════════
    #  POST-PROCESSING
    # ══════════════════════════════════════════════════════════════════
    \
    # ── ucrtbase → msvcrt binary patch ──
    python3 -c "import os,glob;[open(p,'wb').write(d.replace(b'ucrtbase.dll\x00',b'msvcrt.dll\x00\x00\x00')) or print('Patched:',os.path.basename(p)) for p in glob.glob('/output/${WINE_VERSION}/*.dll') for d in [open(p,'rb').read()] if b'ucrtbase.dll\x00' in d]" && \
    \
    # ── Strip ──
    for dll in /output/${WINE_VERSION}/*.dll; do \
        i686-w64-mingw32-strip "$dll" 2>/dev/null && echo "Stripped $(basename $dll)"; \
    done && \
    \
    # ── PE patching for Win98 ──
    python3 /docker/patch_pe_win98.py /output/${WINE_VERSION} && \
    \
    # ── Timestamp ──
    printf "Built on %s\n  binutils %s\n  mingw-w64-crt %s\n  mingw-w64-gcc %s\n" \
        "$(date '+%T %b %-e %Y')" \
        "$(pacman -Q mingw-w64-binutils | awk '{print $2}')" \
        "ea22a99cb (12.0.0+480)" \
        "$(pacman -Q mingw-w64-gcc     | awk '{print $2}')" \
        > /output/${WINE_VERSION}/build-timestamp && \
    chmod +x /output/${WINE_VERSION}/build-timestamp && \
    \
    # ── Cleanup ──
    cd / && rm -rf wine-${WINE_VERSION} wine9x
