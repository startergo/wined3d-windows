FROM --platform=linux/amd64 archlinux:base-devel

# ── Layer 1: system packages (pinned toolchain for Win98-compatible PE) ──
RUN sed -i '/^#\[multilib\]/{N;s/#\[multilib\]\n#Include/\[multilib\]\nInclude/}' /etc/pacman.conf && \
    echo -e "IgnorePkg = mingw-w64-gcc mingw-w64-binutils" \
        >> /etc/pacman.conf && \
    pacman-key --init && \
    pacman -Syu --noconfirm --disable-sandbox && \
    pacman -S --noconfirm --disable-sandbox \
        git wget python3 nasm \
        mingw-w64-headers mingw-w64-winpthreads \
        lib32-gcc-libs lib32-glibc && \
    pacman -U --noconfirm --disable-sandbox \
        https://archive.archlinux.org/packages/m/mingw-w64-gcc/mingw-w64-gcc-14.2.0-3-x86_64.pkg.tar.zst \
        https://archive.archlinux.org/packages/m/mingw-w64-binutils/mingw-w64-binutils-2.44-1-x86_64.pkg.tar.zst && \
    echo "=== Toolchain ===" && \
    i686-w64-mingw32-ld --version | head -1 && \
    i686-w64-mingw32-gcc --version | head -1

# ── Layer 2: Build CRT from reference commit ────────────────────────
RUN git clone https://github.com/mingw-w64/mingw-w64.git /tmp/mingw-w64 && \
    cd /tmp/mingw-w64 && \
    git checkout ea22a99cb06640697c45657e17bd5cb9603e62d7 && \
    mkdir -p /tmp/headers-build && cd /tmp/headers-build && \
    /tmp/mingw-w64/mingw-w64-headers/configure \
        --host=i686-w64-mingw32 --prefix=/usr/i686-w64-mingw32 \
        --enable-sdk=all && \
    make -j$(nproc) install && \
    mkdir -p /tmp/crt-build && cd /tmp/crt-build && \
    /tmp/mingw-w64/mingw-w64-crt/configure \
        --host=i686-w64-mingw32 --prefix=/usr/i686-w64-mingw32 \
        --with-default-msvcrt=msvcrt && \
    make -j$(nproc) && make install && \
    sed -i 's/#define __LONG32 long/#define __LONG32 int/' /usr/i686-w64-mingw32/include/_mingw.h && \
    rm -rf /tmp/mingw-w64 /tmp/headers-build /tmp/crt-build

ARG WINE_VERSION=1.8.7
ARG WINE_BRANCH=1.8
ARG WINE_EXT=tar.bz2
ARG BUILD_MSVCRT=0
ARG BUILD_MODE=legacy

# ── Copy wine9x-support infrastructure ─────────────────────────────
COPY wine9x-support/compact/         /wine9x/compact/
COPY wine9x-support/pthread9x/       /wine9x/pthread9x/
COPY wine9x-support/include/         /wine9x/include/
COPY wine9x-support/mingw/           /wine9x/mingw/
COPY wine9x-support/pthread.mk       /wine9x/pthread.mk
COPY wine9x-support/Makefile         /wine9x/Makefile
COPY wine9x-support/wined3d/         /wine9x/wined3d/
COPY wine9x-support/ddraw/           /wine9x/ddraw/
COPY wine9x-support/d3d8/            /wine9x/d3d8/
COPY wine9x-support/d3d9/            /wine9x/d3d9/

# ── Copy qemu-3dfx hooks + Win98 compat files ───────────────────────
COPY qemu3dfx_hooks.c                /docker/qemu3dfx_hooks.c
COPY qemu3dfx_ddraw_hooks.c          /docker/qemu3dfx_ddraw_hooks.c
COPY qemu3dfx_ddraw_passthrough.c    /docker/qemu3dfx_ddraw_passthrough.c
COPY docker/ /docker/

# ── Layer 3: Build — version-aware, Win98-compatible ────────────────
RUN set -ex && \
    \
    WINE_MAJ=$(echo "$WINE_VERSION" | cut -d. -f1) && \
    WINE_MIN=$(echo "$WINE_VERSION" | cut -d. -f2) && \
    echo "=== Wine ${WINE_VERSION} (major=${WINE_MAJ}, minor=${WINE_MIN}) ===" && \
    \
    mkdir -p /build && cd /build && \
    \
    true "=== Copy wine9x-support infrastructure ===" && \
    cp -r /wine9x/compact /build/compact && \
    cp -r /wine9x/pthread9x /build/pthread9x && \
    cp -r /wine9x/include /build/include && \
    cp -r /wine9x/mingw /build/mingw && \
    cp /wine9x/pthread.mk /build/pthread.mk && \
    cp /wine9x/Makefile /build/Makefile && \
    sed -i 's|-Imingw -Iinclude -Iinclude/wine|-Iinclude -Iinclude/wine -Imingw|g; s|-Imingw -Iinclude/wine -Iinclude|-Iinclude -Iinclude/wine -Imingw|g' /build/Makefile && \
    sed -i 's|^[[:space:]]*CFLAGS = -std=c99|CFLAGS = -I/docker -std=c99|' /build/Makefile && \
    printf '#ifndef ARRAY_SIZE\n#define ARRAY_SIZE(x) (sizeof(x) / sizeof((x)[0]))\n#endif\n' > /build/include/array_size.h && \
    sed -i 's|CFLAGS = -I/docker -std=c99|CFLAGS = -I/docker -std=c99 -include include/array_size.h|' /build/Makefile && \
    true "=== Wine 6.0+ macros not in wine9x headers ===" && \
    printf '#ifndef DECLSPEC_HOTPATCH\n#define DECLSPEC_HOTPATCH\n#endif\n' >> /build/include/array_size.h && \
    printf '#ifndef InterlockedExchangeAddSizeT\n#define InterlockedExchangeAddSizeT(a,b) InterlockedExchangeAdd((LONG*)(a),(b))\n#endif\n' >> /build/include/array_size.h && \
    sed -i 's| -Iinclude -Iinclude/wine -Imingw| -I/docker -Iinclude -Iinclude/wine -Imingw|' /build/Makefile && \
    \
    true "=== Download Wine ${WINE_VERSION} source ===" && \
    WINE_URL="https://dl.winehq.org/wine/source/${WINE_BRANCH}/wine-${WINE_VERSION}.${WINE_EXT}" && \
    echo "Downloading ${WINE_URL}" && \
    wget -q -O "/tmp/wine-${WINE_VERSION}.${WINE_EXT}" "$WINE_URL" && \
    cd /tmp && tar xf "wine-${WINE_VERSION}.${WINE_EXT}" && \
    cd /build && \
    \
    true "=== Patch Makefile: compat flags ===" && \
    sed -i 's/-DHAVE_CRTEX//' Makefile && \
    sed -i 's/-DUSE_HOOKS//' Makefile && \
    sed -i 's/-Wno-discarded-qualifiers/-Wno-discarded-qualifiers -Wno-incompatible-pointer-types/' Makefile && \
    sed -i '/NEW_ALLOC=1/d' pthread.mk && \
    sed -i '/ddraw\/memmgr.c/d' Makefile && \
    sed -i 's/-DWINVER=0x0400/-DWINVER=0x0400 -DDECLSPEC_HIDDEN= -D_USE_MATH_DEFINES/' Makefile && \
    sed -i '1i#include <stdint.h>' include/wine/debug.h && \
    echo "DX_LIBS += -ldxguid -luuid" >> Makefile && \
    true "=== Patch crtfix.c: no-op __chk_fail (removes GetCurrentProcess+TerminateProcess imports) ===" && \
    sed -i '/^void __cdecl.*__chk_fail/,/^}/c\void __cdecl __attribute__((__noreturn__)) __chk_fail(void) { for(;;); }' pthread9x/extra/crtfix.c && \
    true "=== Fix pthread9x Interlocked casts: (long*) -> (LONG*) to match __LONG32=int ===" && \
    find /build/pthread9x/src -name '*.c' -exec sed -i 's/(long\*)/(LONG*)/g' {} + && \
    find /build/pthread9x/src -name '*.c' -o -name '*.h' | xargs sed -i 's/volatile long /volatile LONG /g' && \
    find /build/pthread9x/src -name '*.c' -exec sed -i 's/(DWORD \*) &info/(ULONG_PTR *) \&info/g' {} + && \
    true "=== Patch debug.c: remove GetCurrentThreadId from debug log ===" && \
    sed -i 's/debug_classes\[cls\], GetCurrentThreadId(), channel->name, func/debug_classes[cls], 0, channel->name, func/' compact/debug.c && \
    \
    true "=== Copy wined3d source from Wine ${WINE_VERSION} ===" && \
    mkdir -p /build/wined3d && \
    cp /tmp/wine-${WINE_VERSION}/dlls/wined3d/*.c /build/wined3d/ && \
    cp /tmp/wine-${WINE_VERSION}/dlls/wined3d/*.h /build/wined3d/ 2>/dev/null || true && \
    cp /wine9x/wined3d/*.rc /build/wined3d/ && \
    \
    true "=== Copy ddraw/d3d8/d3d9 source from Wine ${WINE_VERSION} ===" && \
    mkdir -p /build/ddraw && \
    cp /tmp/wine-${WINE_VERSION}/dlls/ddraw/*.c /build/ddraw/ && \
    cp /tmp/wine-${WINE_VERSION}/dlls/ddraw/*.h /build/ddraw/ 2>/dev/null || true && \
    cp /wine9x/ddraw/*.rc /build/ddraw/ && \
    mkdir -p /build/d3d8 && \
    cp /tmp/wine-${WINE_VERSION}/dlls/d3d8/*.c /build/d3d8/ && \
    cp /tmp/wine-${WINE_VERSION}/dlls/d3d8/*.h /build/d3d8/ 2>/dev/null || true && \
    cp /wine9x/d3d8/*.rc /build/d3d8/ && \
    mkdir -p /build/d3d9 && \
    cp /tmp/wine-${WINE_VERSION}/dlls/d3d9/*.c /build/d3d9/ && \
    cp /tmp/wine-${WINE_VERSION}/dlls/d3d9/*.h /build/d3d9/ 2>/dev/null || true && \
    cp /wine9x/d3d9/*.rc /build/d3d9/ && \
    \
    true "=== Strip Makefile entries for source files absent in this Wine version ===" && \
    for dir in wined3d ddraw d3d8 d3d9; do \
        for src in $(grep -oP "$dir/[a-z_A-Z0-9]+\.c" Makefile 2>/dev/null | sort -u); do \
            [ ! -f "/build/$src" ] && echo "  Removing absent: $src" && sed -i "\|$src|d" Makefile; \
        done; \
    done && \
    \
    true "=== Wine 6.0+ modular files handled at injection step ===" && \
    true "=== Add ARRAY_SIZE macro for Wine 6.0+ source files (injected into Makefile CFLAGS) ===" && \
    \
    true "=== Replace wined3d_gl.h with Wine 6.0+ version (has all needed GL enum values) ===" && \
    perl -pi -e 's|#include "wine/wgl\.h"|#include "wine/wgl.h"\n#include "wine/wglext.h"\n\nextern void (WINE_GLAPI *glDisableWINE)(GLenum cap) DECLSPEC_HIDDEN;\nextern void (WINE_GLAPI *glEnableWINE)(GLenum cap) DECLSPEC_HIDDEN;\n|' /build/wined3d/wined3d_gl.h 2>/dev/null || true && \
    \
    true "=== Copy Wine headers needed by ddraw/d3d8/d3d9 ===" && \
    cp /tmp/wine-${WINE_VERSION}/include/wine/exception.h /build/include/wine/ 2>/dev/null || true && \
    sed -i 's/frame->Prev/frame->prev/g; s/(frame->Prev)/(frame->prev)/g' /build/include/wine/exception.h && \
    true "unicode.h: keep wine9x version (more portable, no __ms_va_list/FORCEINLINE)" && \
    for f in /tmp/wine-${WINE_VERSION}/include/wine/*.h; do \
      target=/build/include/wine/$(basename "$f"); \
      [ ! -f "$target" ] && cp "$f" "$target"; \
    done && \
    mkdir -p /build/include/ddk && \
    cp /tmp/wine-${WINE_VERSION}/include/ddk/*.h /build/include/ddk/ 2>/dev/null || true && \
    ls /build/include/ddk/d3dkmthk.h 2>/dev/null && cp /build/include/ddk/d3dkmthk.h /docker/ddk/d3dkmthk.h || echo "NOTE: using docker/ddk/d3dkmthk.h" && \
    cp /tmp/wine-${WINE_VERSION}/include/d3d.h /build/include/ 2>/dev/null || true && \
    cp /tmp/wine-${WINE_VERSION}/include/d3dukmdt.h /build/include/ 2>/dev/null || true && \
    [ -f /build/include/d3dukmdt.h ] && cp /build/include/d3dukmdt.h /docker/d3dukmdt.h || true && \
    [ ! -f /build/include/d3dukmdt.h ] && cp /docker/include/d3dukmdt.h /build/include/ || true && \
    cp /tmp/wine-${WINE_VERSION}/include/ddraw.h /build/include/ 2>/dev/null || true && \
    rm -f /build/include/ddraw.h && \
    true "=== ddraw.h comes from mingw/ (uses DECL_WINELIB_TYPE_AW from windef.h) ===" && \
    cp /tmp/wine-${WINE_VERSION}/include/d3d8.h /build/include/ 2>/dev/null || true && \
    cp /tmp/wine-${WINE_VERSION}/include/d3d9.h /build/include/ 2>/dev/null || true && \
    \
    true "=== Replace wine9x wined3d.h with Wine version's own ===" && \
    cp /tmp/wine-${WINE_VERSION}/include/wine/wined3d.h /build/include/wine/wined3d.h && \
    \
    true "=== Append missing definitions to wined3d.h if absent ===" && \
    if ! grep -q '^#define WINED3D_SRGB_READ_WRITE_CONTROL' /build/include/wine/wined3d.h; then \
      printf '\n#ifndef WINED3D_SRGB_READ_WRITE_CONTROL\n#define WINED3D_SRGB_READ_WRITE_CONTROL 0x00000200\n#endif\n' >> /build/include/wine/wined3d.h; \
    fi && \
    if ! grep -q '^#define WINED3DERR_DEVICELOST' /build/include/wine/wined3d.h; then \
      printf '\n#ifndef WINED3DERR_DEVICELOST\n#define WINED3DERR_DEVICELOST 0x88760868\n#endif\n' >> /build/include/wine/wined3d.h; \
    fi && \
    \
    true "=== Win9x: keep W-version window procs (they work on Win98) ===" && \
    true "=== (DefWindowProcW, CallWindowProcW, Get/SetWindowLongW all exist) ===" && \
    \
    true "=== Win9x: stub Wine COM registration helpers ===" && \
    sed -i 's/__wine_register_resources([^)]*)/0/g' /build/ddraw/main.c && \
    sed -i 's/__wine_unregister_resources([^)]*)/0/g' /build/ddraw/main.c && \
    \
    true "=== Win9x: runtime critical section init ===" && \
    perl -pi -e 's/^static CRITICAL_SECTION wined3d_cs = \{.*\};/\/\* runtime initialized for Win9x \*\//' /build/wined3d/wined3d_main.c && \
    perl -pi -e 's/^static CRITICAL_SECTION wined3d_wndproc_cs = \{.*\};/\/\* runtime initialized for Win9x \*\//' /build/wined3d/wined3d_main.c && \
    perl -pi -e 'if (/DisableThreadLibraryCalls/) { $_ .= "    InitializeCriticalSection(&wined3d_cs);\n    InitializeCriticalSection(&wined3d_wndproc_cs);\n" }' /build/wined3d/wined3d_main.c && \
    \
    true "=== Win9x: disable MT command stream (uses NT internals not on Win98) ===" && \
    sed -i 's/&& !RtlIsCriticalSectionLockedByThread(NtCurrentTeb()->Peb->LoaderLock)/\&\& 0 \/* Win9x: no MT CS *\//' /build/wined3d/cs.c 2>/dev/null || true && \
    \
    true "=== Win9x: AllocateLocallyUniqueId fallback ===" && \
    if [ -f /build/wined3d/directx.c ]; then \
        perl -pi -0777 -e 's/(if \(!AllocateLocallyUniqueId\(&adapter->luid\)\)\s*\{\s*)(ERR|WARN)\("[^"]*"[^;]*;\s*return FALSE;/${1}FILETIME _ftm_luid;\n        WARN("LUID alloc failed, using time fallback.\\n");\n        GetSystemTimeAsFileTime(\&_ftm_luid);\n        adapter->luid.HighPart = _ftm_luid.dwLowDateTime;\n        adapter->luid.LowPart = _ftm_luid.dwHighDateTime;/s' /build/wined3d/directx.c; \
        echo "  Patched AllocateLocallyUniqueId fallback"; \
    fi && \
    \
    true "=== Win9x: RTL_CRITICAL_SECTION_DEBUG Spare field ===" && \
    for f in /build/wined3d/wined3d_private.h; do \
        [ -f "$f" ] && sed -i 's/->Spare\[0\] *=.*;/;/' "$f"; \
    done && \
    true "=== Remove vkd3d (Wine 8.0+ Vulkan D3D, not needed for Win98) ===" && \
    sed -i '/#include <vkd3d.h>/d' /build/wined3d/wined3d_main.c 2>/dev/null || true && \
    sed -i '/WINE_DECLARE_DEBUG_CHANNEL(vkd3d)/d' /build/wined3d/wined3d_main.c 2>/dev/null || true && \
    perl -0777 -pi -e 's/static void vkd3d_log_callback\(.*?\n\}/static void vkd3d_log_callback(void) { }/s' /build/wined3d/wined3d_main.c 2>/dev/null || true && \
    sed -i '/vkd3d_set_log_callback/d' /build/wined3d/wined3d_main.c 2>/dev/null || true && \
    sed -i '/VKD3D_DEBUG/d; /VKD3D_SHADER_DEBUG/d; /TRACE_ON(vkd3d)/d; /WARN_ON(vkd3d)/d; /FIXME_ON(vkd3d)/d; /ERR_ON(vkd3d)/d' /build/wined3d/wined3d_main.c 2>/dev/null || true && \
    \
    true "=== Apply CS_OWNDC patch ===" && \
    sed -i 's/CS_HREDRAW | CS_VREDRAW/CS_HREDRAW | CS_VREDRAW | CS_OWNDC/' \
        /build/wined3d/wined3d_main.c && \
    \
    true "=== Win9x: W→A display/version API patches (W versions not on Win98) ===" && \
    sed -i 's/GetVersionExW/GetVersionExA/g; s/OSVERSIONINFOW/OSVERSIONINFOA/g' /build/wined3d/directx.c && \
    sed -i 's/ChangeDisplaySettingsExW/ChangeDisplaySettingsExA/g' /build/wined3d/directx.c && \
    sed -i 's/EnumDisplayDevicesW/EnumDisplayDevicesA/g; s/DISPLAY_DEVICEW/DISPLAY_DEVICEA/g' /build/wined3d/directx.c && \
    sed -i 's/EnumDisplaySettingsExW/EnumDisplaySettingsExA/g' /build/wined3d/directx.c && \
    sed -i 's/EnumDisplaySettingsW/EnumDisplaySettingsA/g' /build/wined3d/directx.c && \
    sed -i 's/\bDEVMODEW\b/DEVMODEA/g' /build/wined3d/directx.c && \
    \
    true "=== Win9x: W→A string/event API patches ===" && \
    find /build/wined3d -name "*.c" -exec sed -i 's/\blstrcmpiW\b/lstrcmpiA/g; s/\blstrcpyW\b/lstrcpyA/g; s/\bCreateEventW\b/CreateEventA/g' {} + && \
    true "=== Fix DEVMODEA anonymous union access — MinGW uses __C89_NAMELESS (direct members) ===" && \
    sed -i 's/\.u2\.dmDisplayFlags/.dmDisplayFlags/g; s/->u2\.dmDisplayFlags/->dmDisplayFlags/g' /build/wined3d/directx.c && \
    sed -i 's/\.u1\.s2\././g; s/->u1\.s2\./->/g' /build/wined3d/directx.c && \
    find /build/wined3d -name '*.c' -exec sed -i 's/\.u2\.dmDisplayFlags/.dmDisplayFlags/g; s/->u2\.dmDisplayFlags/->dmDisplayFlags/g; s/\.u1\.s2\./\./g; s/->u1\.s2\./->/g' {} + 2>/dev/null || true && \
    true "=== Fix WINEDDBLTFX anonymous union u5 — DUMMYUNIONNAME5 expands empty ===" && \
    find /build/wined3d -name '*.c' -exec sed -i 's/->u5\./->/g; s/\.u5\./\./g' {} + 2>/dev/null || true && \
    true "=== Fix D3DKMT_CREATEDEVICE anonymous union — DUMMYUNIONNAME expands empty ===" && \
    find /build/wined3d -name '*.c' -exec sed -i 's/\.u\.hAdapter/.hAdapter/g; s/->u\.hAdapter/->hAdapter/g' {} + 2>/dev/null || true && \
    find /build/wined3d -name '*.h' -exec sed -i 's/->Spare\[0\]/->Spare/' {} + 2>/dev/null || true && \
    \
    true "=== Remove WGL extensions not in wine9x headers ===" && \
    sed -i '/USE_GL_FUNC(wglQuery.*Renderer.*WINE)/d' /build/wined3d/directx.c && \
    sed -i '/wglQueryCurrentRendererIntegerWINE/d' /build/wined3d/directx.c && \
    sed -i '/wglQueryRendererIntegerWINE/d' /build/wined3d/directx.c && \
    sed -i '/WGL_RENDERER_VENDOR_ID_WINE/d; /WGL_RENDERER_DEVICE_ID_WINE/d; /WGL_RENDERER_VIDEO_MEMORY_WINE/d' /build/wined3d/directx.c && \
    sed -i '/WGL_WINE_query_renderer/d' /build/wined3d/directx.c && \
    true "=== Fix GL extension naming: wine9x uses EXT suffix ===" && \
    find /build/wined3d -name '*.c' -exec sed -i 's/p_glPolygonOffsetClamp(/p_glPolygonOffsetClampEXT(/g; s/GL_TEXTURE_MAX_ANISOTROPY)/GL_TEXTURE_MAX_ANISOTROPY_EXT)/g; s/GL_TEXTURE_MAX_ANISOTROPY,/GL_TEXTURE_MAX_ANISOTROPY_EXT,/g; s/GL_MAX_TEXTURE_MAX_ANISOTROPY\b/GL_MAX_TEXTURE_MAX_ANISOTROPY_EXT/g' {} + 2>/dev/null || true && \
    sed -i 's/USE_GL_FUNC(glPolygonOffsetClamp)/USE_GL_FUNC(glPolygonOffsetClampEXT)/g' /build/wined3d/adapter_gl.c 2>/dev/null || true && \
    sed -i '/MAP_GL_FUNCTION(glPolygonOffsetClamp,/d' /build/wined3d/adapter_gl.c 2>/dev/null || true && \
    true "=== Patch adapter_gl.c: remove WGL query renderer (not in wine9x) ===" && \
    sed -i '/USE_GL_FUNC(wglQueryCurrentRendererIntegerWINE)/d' /build/wined3d/adapter_gl.c 2>/dev/null || true && \
    sed -i '/USE_GL_FUNC(wglQueryCurrentRendererStringWINE)/d' /build/wined3d/adapter_gl.c 2>/dev/null || true && \
    sed -i '/USE_GL_FUNC(wglQueryRendererIntegerWINE)/d' /build/wined3d/adapter_gl.c 2>/dev/null || true && \
    sed -i '/USE_GL_FUNC(wglQueryRendererStringWINE)/d' /build/wined3d/adapter_gl.c 2>/dev/null || true && \
    sed -i '/WGL_WINE_query_renderer/d' /build/wined3d/adapter_gl.c 2>/dev/null || true && \
    perl -0777 -pi -e 's/if \(gl_info->supported\[WGL_WINE_QUERY_RENDERER\]\)\s*\{(?:[^{}]+|\{(?:[^{}]+|\{[^{}]*\})*\})*\}/if (0) { }/g' /build/wined3d/adapter_gl.c 2>/dev/null || true && \
    true "=== Patch adapter_gl.c: remove GL memory object extensions (not in wine9x) ===" && \
    sed -i '/USE_GL_FUNC(glGetUnsignedByte/d' /build/wined3d/adapter_gl.c 2>/dev/null || true && \
    perl -0777 -pi -e 's/if \(gl_info->supported\[EXT_MEMORY_OBJECT\]\)\s*\{(?:[^{}]+|\{(?:[^{}]+|\{[^{}]*\})*\})*\}/if (0) { }/g' /build/wined3d/adapter_gl.c 2>/dev/null || true && \
    true "=== Add WGL constants via wglext.h to all wined3d source files ===" && \
    find /build/wined3d -name '*.c' -exec grep -l 'wined3d_private\.h' {} \; | xargs -I{} sed -i '/#include "wined3d_private.h"/a\#include "wine/wglext.h"' {} 2>/dev/null || true && \
    \
    true "=== Generate .def from Wine spec (add HAL stubs and COM exports for ddraw) ===" && \
    echo "EXPORTS" > /build/wined3d/wined3d.def && \
    grep -E '^@ (stdcall|cdecl)' /tmp/wine-${WINE_VERSION}/dlls/wined3d/wined3d.spec 2>/dev/null | \
        sed -E 's/^@ (stdcall|cdecl)( -private)? ([a-zA-Z0-9_]+).*/  \3/' | \
        grep -v -E 'wined3d_get_adapter_monitor|wined3d_surface_is_lost|wined3d_surface_restore' >> /build/wined3d/wined3d.def && \
    printf '  wined3d_surface_ddheap\n  wined3d_streaming_buffer_map\n  wined3d_streaming_buffer_unmap\n  wined3d_streaming_buffer_upload\n' >> /build/wined3d/wined3d.def && \
    echo "EXPORTS" > /build/ddraw/ddraw.def && \
    grep -E '^@ (stdcall|cdecl)' /tmp/wine-${WINE_VERSION}/dlls/ddraw/ddraw.spec 2>/dev/null | \
        sed -E 's/^@ (stdcall|cdecl)( -private)? ([a-zA-Z0-9_]+).*/  \3/' | \
        grep -v '^$' >> /build/ddraw/ddraw.def && \
    printf '  AcquireDDThreadLock\n  ReleaseDDThreadLock\n  D3DParseUnknownCommand\n  DDInternalLock\n  DDInternalUnlock\n  CompleteCreateSysmemSurface\n  DDHAL32_VidMemAlloc\n  DDHAL32_VidMemFree\n  DSoundHelp\n  GetNextMipMap\n  HeapVidMemAllocAligned\n  InternalLock\n  InternalUnlock\n  LateAllocateSurfaceMem\n  VidMemAlloc\n  VidMemAmountFree\n  VidMemFini\n  VidMemFree\n  VidMemInit\n  VidMemLargestFree\n  DllCanUnloadNow\n  DllGetClassObject\n  DllRegisterServer\n  DllUnregisterServer\n' >> /build/ddraw/ddraw.def && \
    echo "EXPORTS" > /build/d3d8/d3d8.def && \
    grep -E '^@ (stdcall|cdecl)' /tmp/wine-${WINE_VERSION}/dlls/d3d8/d3d8.spec 2>/dev/null | \
        sed -E 's/^@ (stdcall|cdecl)( -private)? ([a-zA-Z0-9_]+).*/  \3/' >> /build/d3d8/d3d8.def && \
    echo "EXPORTS" > /build/d3d9/d3d9.def && \
    grep -E '^@ (stdcall|cdecl)' /tmp/wine-${WINE_VERSION}/dlls/d3d9/d3d9.spec 2>/dev/null | \
        sed -E 's/^@ (stdcall|cdecl)( -private)? ([a-zA-Z0-9_]+).*/  \3/' >> /build/d3d9/d3d9.def && \
    printf '  DebugSetLevel\n  PSGPError\n  PSGPSampleTexture\n' >> /build/d3d9/d3d9.def && \
    \
    echo "=== Inject qemu-3dfx + compat objects into Makefile ===" && \
    echo "wined3d_OBJS += wined3d/qemu3dfx_hooks.c.o /build/kernel32_compat.o /build/copysign.o /build/wine_spec_stubs.o" >> Makefile && \
    [ -f wined3d/adapter_gl.c ] && echo "wined3d_OBJS += wined3d/adapter_gl.c.o" >> Makefile || true && \
    [ -f wined3d/context_gl.c ] && echo "wined3d_OBJS += wined3d/context_gl.c.o" >> Makefile || true && \
    echo "wined3d_OBJS += wined3d/d3dkmt_stubs.c.o" >> Makefile && \
    echo "wined3d_OBJS += /build/vk_stubs.o" >> Makefile && \
    echo "ddraw_OBJS += ddraw/qemu3dfx_ddraw_hooks.c.o ddraw/qemu3dfx_ddraw_passthrough.c.o /build/kernel32_compat.o /build/copysign.o /build/libwine_stubs.o" >> Makefile && \
    echo "d3d8_OBJS += /build/kernel32_compat.o /build/copysign.o" >> Makefile && \
    echo "d3d9_OBJS += /build/kernel32_compat.o /build/copysign.o /build/wine_spec_stubs.o" >> Makefile && \
    \
    echo "=== Add qemu-3dfx exports to wined3d.def ===" && \
    echo "  wined3d_hal_3dfx" >> wined3d/wined3d.def && \
    echo "  wined3d_passthru" >> wined3d/wined3d.def && \
    echo "  wined3d_enum_hal_last" >> wined3d/wined3d.def && \
    echo "  wined3d_override_cooplevel" >> wined3d/wined3d.def && \
    echo "  wined3d_override_rendertarget_view" >> wined3d/wined3d.def && \
    echo "  wined3d_blit_fpslimit" >> wined3d/wined3d.def && \
    echo "  wined3d_flip_fpslimit" >> wined3d/wined3d.def && \
    \
    echo "=== Compile Win98 compat objects ===" && \
    CFLAGS_COMPAT="-std=c99 -O3 -fomit-frame-pointer -I/docker -Iinclude -Iinclude/wine -Imingw -Icompact -Ipthread9x/include -D_WIN32 -DWIN32 -D__WINESRC__ -DUSE_WIN32_OPENGL -DWINE_NOWINSOCK -DNDEBUG -DWINVER=0x0400 -DWINE_SILENT -DWINE_NO_TRACE_MSGS -DWINE_NO_DEBUG_MSGS -DDECLSPEC_HIDDEN= -D__USE_MINGW_ANSI_STDIO=0" && \
    CFLAGS_HOOKS="-std=c99 -O3 -fomit-frame-pointer -D_WIN32 -DWIN32 -DNDEBUG -DWINVER=0x0400 -D__USE_MINGW_ANSI_STDIO=0" && \
    i686-w64-mingw32-gcc $CFLAGS_COMPAT -c -o /build/kernel32_compat.o /docker/kernel32_compat.c && \
    i686-w64-mingw32-gcc $CFLAGS_COMPAT -c -o /build/copysign.o /docker/copysign.c && \
    i686-w64-mingw32-gcc $CFLAGS_COMPAT -c -o /build/vk_stubs.o /docker/vk_stubs.c && \
    i686-w64-mingw32-gcc $CFLAGS_COMPAT -c -o /build/libwine_stubs.o /docker/libwine_stubs.c && \
    i686-w64-mingw32-gcc $CFLAGS_COMPAT -c -o /build/wine_spec_stubs.o /docker/wine_spec_stubs.c && \
    \
    echo "=== Copy and pre-compile qemu-3dfx hooks ===" && \
    cp /docker/qemu3dfx_hooks.c wined3d/qemu3dfx_hooks.c && \
    cp /docker/qemu3dfx_ddraw_hooks.c ddraw/qemu3dfx_ddraw_hooks.c && \
    cp /docker/qemu3dfx_ddraw_passthrough.c ddraw/qemu3dfx_ddraw_passthrough.c && \
    cp /docker/d3dkmt_stubs.c wined3d/d3dkmt_stubs.c && \
    i686-w64-mingw32-gcc $CFLAGS_HOOKS -c -o wined3d/qemu3dfx_hooks.c.o wined3d/qemu3dfx_hooks.c && \
    i686-w64-mingw32-gcc $CFLAGS_HOOKS -Iwined3d -c -o ddraw/qemu3dfx_ddraw_hooks.c.o ddraw/qemu3dfx_ddraw_hooks.c && \
    i686-w64-mingw32-gcc $CFLAGS_HOOKS -Iwined3d -Iddraw -c -o ddraw/qemu3dfx_ddraw_passthrough.c.o ddraw/qemu3dfx_ddraw_passthrough.c && \
    i686-w64-mingw32-gcc $CFLAGS_HOOKS -c -o wined3d/d3dkmt_stubs.c.o wined3d/d3dkmt_stubs.c && \
    \
    echo "=== Patch ddraw source for qemu-3dfx ===" && \
    sed -i '/#include "ddraw_private.h"/a\extern void qemu3dfx_ddraw_passthrough_init(void);\
extern BOOL qemu3dfx_ddraw_is_passthru(void);\
extern HRESULT qemu3dfx_ddraw_create(GUID *, void **, IUnknown *);\
extern HRESULT qemu3dfx_ddraw_create_ex(GUID *, void **, REFIID, IUnknown *);\
extern HRESULT qemu3dfx_ddraw_create_clipper(DWORD, void *, IUnknown *);' ddraw/main.c && \
    sed -i '/DisableThreadLibraryCalls(inst);/a\        qemu3dfx_ddraw_passthrough_init();' ddraw/main.c && \
    perl -pi -e 'if (/^HRESULT WINAPI.*DirectDrawCreate\(GUID \*driver_guid, IDirectDraw/) { $in_ddc = 1; } if ($in_ddc && /^    wined3d_mutex_lock/) { $_ = "    if (qemu3dfx_ddraw_is_passthru())\n        return qemu3dfx_ddraw_create(driver_guid, (void **)ddraw, outer);\n\n" . $_; $in_ddc = 0; }' ddraw/main.c && \
    perl -pi -e 'if (/^HRESULT WINAPI.*DirectDrawCreateEx\(/) { $in_ddce = 1; } if ($in_ddce && /^    wined3d_mutex_lock/) { $_ = "    if (qemu3dfx_ddraw_is_passthru())\n        return qemu3dfx_ddraw_create_ex(driver_guid, ddraw, interface_iid, outer);\n\n" . $_; $in_ddce = 0; }' ddraw/main.c && \
    sed -i -e '/#include "ddraw_private.h"/a\extern void qemu3dfx_ddraw_cooplevel(DWORD *);' \
           -e '/DDRAW_dump_cooperativelevel(cooplevel);/a\    qemu3dfx_ddraw_cooplevel(\&cooplevel);' ddraw/ddraw.c && \
    sed -i '/#include "ddraw_private.h"/a\extern void qemu3dfx_ddraw_blit(void);\nextern void qemu3dfx_ddraw_flip(void);\nextern void qemu3dfx_ddraw_rtv(void *);' ddraw/surface.c && \
    \
    echo "=== Create config.mk ===" && \
    echo "CC      = i686-w64-mingw32-gcc" > config.mk && \
    echo "LD      = i686-w64-mingw32-gcc" >> config.mk && \
    echo "AR      = i686-w64-mingw32-ar" >> config.mk && \
    echo "WINDRES = i686-w64-mingw32-windres" >> config.mk && \
    echo "ASM     = nasm" >> config.mk && \
    echo "RM      = rm -f" >> config.mk && \
    echo "SPEED   = 1" >> config.mk && \
    echo "WINED3D_SILENT = 1" >> config.mk && \
    echo 'CPPFLAGS = -I/docker' >> config.mk && \
    echo 'CFLAGS += -I/docker' >> config.mk && \
    echo 'CXXFLAGS += -I/docker' >> config.mk && \
    echo 'TUNE    = -I/docker -march=pentium2 -mtune=core2 -fno-stack-protector -fdata-sections -ffunction-sections -DDCX_USESTYLE=0x00010000 -D__USE_MINGW_ANSI_STDIO=0' >> config.mk && \
    echo 'TUNE_LD = ,--allow-multiple-definition,--gc-sections' >> config.mk && \
    true "=== Pre-compile Wine 6.0+ GL source files via make pattern rule ===" && \
    [ -f wined3d/adapter_gl.c ] && make wined3d/adapter_gl.c.o || true && \
    [ -f wined3d/context_gl.c ] && make wined3d/context_gl.c.o || true && \
    true "=== Link ddraw/d3d8/d3d9 with nocrt (no CRT startup, only math from msvcrt) ===" && \
    sed -i 's|\$\$LD) \$\$CFLAGS) \$\$ddraw_OBJS) \$\$DX_LIBS) \$\$DLLFLAGS)|\$\$LD) \$\$CFLAGS) \$\$ddraw_OBJS) -static-libgcc -L. -lwined3d -lgdi32 -lmsvcrt \$\$DLLFLAGS_NOCRT)|' Makefile && \
    sed -i 's|\$\$LD) \$\$CFLAGS) \$\$d3d8_OBJS) \$\$DX_LIBS) \$\$DLLFLAGS)|\$\$LD) \$\$CFLAGS) \$\$d3d8_OBJS) -static-libgcc -L. -lwined3d -lgdi32 -lmsvcrt \$\$DLLFLAGS_NOCRT)|' Makefile && \
    sed -i 's|\$\$LD) \$\$CFLAGS) \$\$d3d9_OBJS) \$\$DX_LIBS) \$\$DLLFLAGS)|\$\$LD) \$\$CFLAGS) \$\$d3d9_OBJS) -static-libgcc -L. -lwined3d -lgdi32 -lmsvcrt \$\$DLLFLAGS_NOCRT)|' Makefile && \
    true "=== Build all DLLs ===" && \
    make wined3d.dll winedd.dll wined8.dll wined9.dll && \
    \
    true "=== Build msvcrt.dll from Wine source (BUILD_MSVCRT=1 only) ===" && \
    if [ "$BUILD_MSVCRT" = "1" ]; then \
        mkdir -p /tmp/wine-tools && cd /tmp/wine-tools && \
        /tmp/wine-${WINE_VERSION}/configure \
            --disable-win16 --disable-win64 --disable-tests \
            --without-x --without-vulkan --without-alsa --without-capi \
            --without-cups --without-dbus --without-fontconfig --without-freetype \
            --without-gphoto --without-gnutls --without-inotify --without-krb5 \
            --without-ldap --without-netapi --without-openal \
            --without-opencl --without-opengl --without-osmesa --without-oss \
            --without-pcap --without-pulse --without-sane --without-sdl \
            --without-udev --without-unwind --without-usb --without-v4l2 \
            2>&1 | tail -5 && \
        echo "=== Build all native tools via recursive make ===" && \
        make -j$(nproc) depend 2>&1 | tail -5 && \
        make -j$(nproc) tools/winebuild/winebuild tools/widl/widl tools/wrc/wrc tools/wmc/wmc tools/sfnt2fon/sfnt2fon tools/winegcc/winegcc 2>&1 | tail -10 && \
        ls -la tools/widl/widl tools/wrc/wrc tools/wmc/wmc tools/winebuild/winebuild tools/winegcc/winegcc 2>&1 && \
        mkdir -p /tmp/wine-cross && cd /tmp/wine-cross && \
        /tmp/wine-${WINE_VERSION}/configure \
            --host=i686-w64-mingw32 \
            --with-wine-tools=/tmp/wine-tools \
            --with-mingw \
            --disable-win16 --disable-win64 --disable-tests \
            --without-x --without-vulkan --without-alsa --without-capi \
            --without-cups --without-dbus --without-fontconfig --without-freetype \
            --without-gphoto --without-gnutls --without-inotify --without-krb5 \
            --without-ldap --without-netapi --without-openal \
            --without-opencl --without-opengl --without-osmesa --without-oss \
            --without-pcap --without-pulse --without-sane --without-sdl \
            --without-udev --without-unwind --without-usb --without-v4l2 \
            CC=i686-w64-mingw32-gcc \
            2>&1 | tail -5 && \
        echo "=== Patch corecrt.h: prevent _UCRT definition ===" && \
        sed -i 's/^#if !defined(_UCRT) && _MSVCR_VER >= 140/#if 0/' /tmp/wine-${WINE_VERSION}/include/msvcrt/corecrt.h && \
        echo "=== Patch corecrt_wstring.h: force 2-arg wcstok ===" && \
        sed -i 's/^#ifdef _UCRT/#if 0/' /tmp/wine-${WINE_VERSION}/include/msvcrt/corecrt_wstring.h && \
        echo "=== Patch stdio.h + corecrt_wstdio.h: disable UCRT inline wrappers ===" && \
        sed -i 's/^#if defined(_UCRT) && !defined(_NO_CRT_STDIO_INLINE)/#if 0/' /tmp/wine-${WINE_VERSION}/include/msvcrt/stdio.h && \
        sed -i 's/^#if defined(_UCRT) && !defined(_NO_CRT_STDIO_INLINE)/#if 0/' /tmp/wine-${WINE_VERSION}/include/msvcrt/corecrt_wstdio.h && \
        mkdir -p /output/${WINE_VERSION} && \
        make -j$(nproc) dlls/msvcrt/msvcrt.dll CFLAGS+="-U_UCRT" 2>&1 | tail -20 && \
        cp dlls/msvcrt/msvcrt.dll /output/${WINE_VERSION}/msvcrt.dll && \
        echo "Built msvcrt.dll from Wine source" || \
        echo "WARNING: msvcrt.dll build failed"; \
    fi && \
    \
    echo "=== Collect output ===" && \
    mkdir -p /output/${WINE_VERSION} && \
    cd /build && \
    cp wined3d.dll /output/${WINE_VERSION}/wined3d.dll && \
    cp winedd.dll  /output/${WINE_VERSION}/ddraw.dll && \
    cp wined8.dll  /output/${WINE_VERSION}/d3d8.dll && \
    cp wined9.dll  /output/${WINE_VERSION}/d3d9.dll && \
    date '+%Y-%m-%d %H:%M:%S' > /output/${WINE_VERSION}/build-timestamp && \
    chmod +x /output/${WINE_VERSION}/build-timestamp && \
    \
    echo "=== Patch ucrtbase->msvcrt imports ===" && \
    find /output/${WINE_VERSION} -name '*.dll' -exec sh -c 'python3 -c "import sys;d=open(sys.argv[1],\"rb\").read();r=d.replace(b\"ucrtbase.dll\\x00\",b\"msvcrt.dll\\x00\\x00\\x00\");open(sys.argv[1],\"wb\").write(r) if r!=d else None" "$1"' _ {} \; && \
    \
    echo "=== Strip import decorations ===" && \
    python3 /docker/strip_import_decorations.py /output/${WINE_VERSION}/ && \
    \
    echo "=== Patch PE headers ===" && \
    python3 /docker/patch_pe_win98.py /output/${WINE_VERSION}/ && \
    \
    echo "=== Done ===" && \
    ls -la /output/
