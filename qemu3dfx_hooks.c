/*
 * qemu-3dfx module for Wine wined3d (Win9x/ME/XP guests)
 *
 * Clean-room reimplementation of the qemu-3dfx additions found in the
 * reference qemu-3dfx wined3d.dll builds (Wine 1.8.7 .. 8.0.2).
 *  The upstream modified Wine source has not been published, so
 * every behaviour below was recovered from those binaries; the reference
 * addresses (1.8.7 build unless noted) are given next to each function so
 * the derivation can be re-checked with re/annot.py and re/xref.py.
 *
 * Contents
 *   1. Configuration   HKCU\Software\Wine\Direct3D (+ AppDefaults\<exe>)
 *   2. Exported hooks  the 7 (1.x-5.x) / 8 (6.x+) wined3d_* exports that
 *                      ddraw.dll calls
 *   3. Internal API    qemu3dfx_* functions that wined3d core calls from
 *                      swapchain / adapter / device code
 *
 * Build: compiled per Wine version with
 *   -DQEMU3DFX_WINE_MAJOR=<n> -DQEMU3DFX_WINE_MINOR=<n>
 * Version-dependent details (see re/ for the evidence):
 *   - UseLastContextTid: "enabled" -> 1, default 0   (1.8 .. 7.0)
 *                        "disabled" -> 0, default 1  (8.0+)
 *   - DDSurfaceHeap and wined3d_surface_ddheap        (6.0+)
 *   - Silent Hill 4 FMV quirk (quartz.dll loaded)     (2.0+)
 *   - wined3d_override_rendertarget_view touches
 *     resource->usage |= 0x1 (1.x-3.0) or resource->bind_flags |= 0x20
 *     (4.x+), at an offset that moves per version
 */

#ifndef _WIN32
#error "This file is for Windows PE targets only"
#endif

#include <windows.h>
#include <string.h>

#ifndef QEMU3DFX_WINE_MAJOR
#error "build with -DQEMU3DFX_WINE_MAJOR=<n> -DQEMU3DFX_WINE_MINOR=<n>"
#endif
#ifndef QEMU3DFX_WINE_MINOR
#define QEMU3DFX_WINE_MINOR 0
#endif
#define QEMU3DFX_WINE_VER (QEMU3DFX_WINE_MAJOR * 100 + QEMU3DFX_WINE_MINOR)

/* ===================================================================== */
/* 1. Configuration                                                      */
/* ===================================================================== */

/*
 * Field order and defaults match the reference .data block
 * (1.8.7: 0x1005e04c..0x1005e074, 8.0.2: 0x100d504c..0x100d5074).
 * DWORD overrides use 0xffffffff for "not set".
 */
static struct
{
    DWORD use_last_context_tid;      /* UseLastContextTid          */
    DWORD hal_3dfx;                  /* D3D1Hal3Dfx                */
    DWORD enum_hal_last;             /* D3D1EnumHalLast            */
    DWORD dd_surface_heap;           /* DDSurfaceHeap (6.0+)       */
    DWORD blit_fps_limit;            /* BlitFpsLimit               */
    DWORD flip_fps_limit;            /* FlipFpsLimit               */
    DWORD scale_window;              /* ScaleWindow                */
    DWORD display_roi;               /* DisplayROI                 */
    DWORD override_coop_fullscreen;  /* OverrideCoopFullscreen     */
    DWORD override_mode_width;       /* OverrideModeWidth          */
    DWORD swap_interval;             /* SwapInterval               */
} cfg =
{
#if QEMU3DFX_WINE_MAJOR >= 8
    1,
#else
    0,
#endif
    0, 1, 1, 0, 0,
    0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff,
};

static volatile LONG cfg_loaded;

/*
 * Same lookup order as Wine's get_config_key(): the per-application key
 * (AppDefaults\<exe>\Direct3D) wins over the global Direct3D key.
 */
static BOOL cfg_query(HKEY app, HKEY def, const char *name, DWORD want_type,
                      void *buf, DWORD size)
{
    DWORD type, len;

    if (app)
    {
        len = size;
        if (!RegQueryValueExA(app, name, NULL, &type, buf, &len) && type == want_type)
            return TRUE;
    }
    if (def)
    {
        len = size;
        if (!RegQueryValueExA(def, name, NULL, &type, buf, &len) && type == want_type)
            return TRUE;
    }
    return FALSE;
}

static BOOL cfg_string_is(HKEY app, HKEY def, const char *name, const char *value)
{
    char buf[64];

    memset(buf, 0, sizeof(buf));
    if (!cfg_query(app, def, name, REG_SZ, buf, sizeof(buf) - 1))
        return FALSE;
    return !strcmp(buf, value);
}

static void cfg_dword(HKEY app, HKEY def, const char *name, DWORD *out)
{
    DWORD v;

    if (cfg_query(app, def, name, REG_DWORD, &v, sizeof(v)))
        *out = v;
}

static const char *exe_basename(const char *path)
{
    const char *p, *base = path;

    for (p = path; *p; ++p)
        if (*p == '\\' || *p == '/')
            base = p + 1;
    return base;
}

static void cfg_load(void)
{
    char path[MAX_PATH + 64];
    char exe[MAX_PATH];
    HKEY def = NULL, app = NULL;
    DWORD len;

    if (cfg_loaded)
        return;

    RegOpenKeyA(HKEY_CURRENT_USER, "Software\\Wine\\Direct3D", &def);

    len = GetModuleFileNameA(NULL, exe, sizeof(exe));
    if (len && len < sizeof(exe))
    {
        HKEY appdefaults;

        if (!RegOpenKeyA(HKEY_CURRENT_USER, "Software\\Wine\\AppDefaults", &appdefaults))
        {
            lstrcpyA(path, exe_basename(exe));
            lstrcatA(path, "\\Direct3D");
            if (RegOpenKeyA(appdefaults, path, &app))
                app = NULL;
            RegCloseKey(appdefaults);
        }
    }

    if (def || app)
    {
#if QEMU3DFX_WINE_MAJOR >= 8
        if (cfg_string_is(app, def, "UseLastContextTid", "disabled"))
            cfg.use_last_context_tid = 0;
#else
        if (cfg_string_is(app, def, "UseLastContextTid", "enabled"))
            cfg.use_last_context_tid = 1;
#endif
        if (cfg_string_is(app, def, "D3D1Hal3Dfx", "enabled"))
            cfg.hal_3dfx = 1;
        if (cfg_string_is(app, def, "D3D1EnumHalLast", "disabled"))
            cfg.enum_hal_last = 0;
#if QEMU3DFX_WINE_MAJOR >= 6
        if (cfg_string_is(app, def, "DDSurfaceHeap", "disabled"))
            cfg.dd_surface_heap = 0;
#endif
        cfg_dword(app, def, "ScaleWindow", &cfg.scale_window);
        cfg_dword(app, def, "DisplayROI", &cfg.display_roi);
        cfg_dword(app, def, "OverrideCoopFullscreen", &cfg.override_coop_fullscreen);
        cfg_dword(app, def, "OverrideModeWidth", &cfg.override_mode_width);
        cfg_dword(app, def, "SwapInterval", &cfg.swap_interval);
        cfg_dword(app, def, "BlitFpsLimit", &cfg.blit_fps_limit);
        cfg_dword(app, def, "FlipFpsLimit", &cfg.flip_fps_limit);
    }

    if (app) RegCloseKey(app);
    if (def) RegCloseKey(def);
    cfg_loaded = 1;
}

/* Called from wined3d_dll_init() (DLL_PROCESS_ATTACH); every entry point
 * below also loads lazily, so a missing init call only costs a registry
 * read on first use. */
void qemu3dfx_load_config(void)
{
    cfg_load();
}

/* ===================================================================== */
/* Shared helpers                                                        */
/* ===================================================================== */

/* Reference 0x100290fc: true when the primary display adapter is QEMU's
 * Bochs VBE device (the qemu-3dfx host side is present). */
BOOL qemu3dfx_is_qemu_bochs(void)
{
    DISPLAY_DEVICEA dd;

    memset(&dd, 0, sizeof(dd));
    dd.cb = sizeof(dd);                      /* 0x1a8 */
    if (!EnumDisplayDevicesA(NULL, 0, &dd, 0))
        return FALSE;
    return !memcmp(dd.DeviceString, "QEMU Bochs", 10);
}

/* Reference 0x10029190: block until the next frame slot of a 1000/fps ms
 * period, spinning with Sleep(0) and guarding the GetTickCount wrap. */
static DWORD fps_next_tick;

static void fps_limit(DWORD fps)
{
    DWORD now, interval;

    while (GetTickCount() < fps_next_tick)
        Sleep(0);

    now = GetTickCount();
    interval = 1000 / fps;
    fps_next_tick = now;
    while (now >= ~interval)                 /* would wrap: wait it out */
    {
        now = GetTickCount();
        fps_next_tick = now;
    }
    fps_next_tick = now + interval;
}

/* ===================================================================== */
/* 2. Exported hooks (called by ddraw.dll)                               */
/* ===================================================================== */

/* Reference 0x10029764: low byte of BlitFpsLimit (movzbl). */
BOOL WINAPI wined3d_blit_fpslimit(void)
{
    DWORD fps;

    cfg_load();
    fps = cfg.blit_fps_limit & 0xff;
    if (fps)
        fps_limit(fps);
    return TRUE;
}

/* Reference 0x10029754: FlipFpsLimit & 0x7f. */
BOOL WINAPI wined3d_flip_fpslimit(void)
{
    DWORD fps;

    cfg_load();
    fps = cfg.flip_fps_limit & 0x7f;
    if (fps)
        fps_limit(fps);
    return TRUE;
}

/* Reference 0x10029775: D3D1Hal3Dfx, else the executable's basename
 * matches (case-insensitively) the one title qemu-3dfx enables the 3dfx
 * HAL for by default.  The list is {"ds9dw.exe"} in every reference
 * version 1.8.7 .. 8.0.2 (verified by differential test). */
BOOL WINAPI wined3d_hal_3dfx(void)
{
    static const char * const exe_names[] = { "ds9dw.exe", NULL };
    char buf[MAX_PATH];
    const char * const *name;
    DWORD len;

    cfg_load();
    if (cfg.hal_3dfx)
        return TRUE;

    len = GetModuleFileNameA(NULL, buf, sizeof(buf));
    if (len > sizeof(buf) - 1)
        return FALSE;
    for (name = exe_names; *name; ++name)
        if (!lstrcmpiA(*name, exe_basename(buf)))
            return TRUE;
    return FALSE;
}

/* Reference 0x1002980a. */
BOOL WINAPI wined3d_enum_hal_last(void)
{
    cfg_load();
    return cfg.enum_hal_last != 0;
}

/* Reference 8.0.2 0x1004f87e: DDSurfaceHeap.  The reference only exports
 * this from 6.0 on; the build exports it for every version (the ddraw of
 * older versions never calls it), and the registry value is only read on
 * 6.0+, so older versions report the default. */
BOOL WINAPI wined3d_surface_ddheap(void)
{
    cfg_load();
    return cfg.dd_surface_heap != 0;
}

/* Reference 0x10029824 (stdcall, 1 arg): a non-NULL argument sets the
 * passthrough flag to (*enabled != 0); always returns the current flag. */
static DWORD passthru_flag;

BOOL WINAPI wined3d_passthru(BOOL *enabled)
{
    if (enabled)
        passthru_flag = (*enabled != 0);
    return passthru_flag;
}

/* Wine core reads the flag directly (reference 1.8.7 0x1001a3be). */
BOOL qemu3dfx_passthru_active(void)
{
    return passthru_flag != 0;
}

/* Reference 0x10029845 (stdcall): with OverrideCoopFullscreen set, toggle
 * bit 0 (DDSCL_FULLSCREEN) when ScaleWindow is set, and toggle bit 4
 * (DDSCL_NOWINDOWCHANGES) when OverrideCoopFullscreen == 1. */
void WINAPI wined3d_override_cooplevel(DWORD *cooplevel)
{
    DWORD flags;

    cfg_load();
    if (cfg.override_coop_fullscreen == 0xffffffff)
        return;

    flags = (cfg.scale_window != 0xffffffff) ^ *cooplevel;
    *cooplevel = flags;
    *cooplevel = ((DWORD)(cfg.override_coop_fullscreen == 1) << 4) ^ flags;
}

/* Reference 0x10029911 (stdcall): make the view's resource bindable as a
 * render target.  view->resource is the second field of
 * struct wined3d_rendertarget_view in every version.  1.x - 3.0 set
 * WINED3DUSAGE_RENDERTARGET (0x1) in resource->usage; 4.x+ set
 * WINED3D_BIND_RENDER_TARGET (0x20) in resource->bind_flags.  Offsets and
 * bits are taken from each reference build (re/test_module.py checks them). */
#if QEMU3DFX_WINE_VER >= 800
#define RESOURCE_RT_OFFSET 0x34
#define RESOURCE_RT_BIT    0x20
#elif QEMU3DFX_WINE_VER >= 600
#define RESOURCE_RT_OFFSET 0x30
#define RESOURCE_RT_BIT    0x20
#elif QEMU3DFX_WINE_VER >= 500
#define RESOURCE_RT_OFFSET 0x34
#define RESOURCE_RT_BIT    0x20
#elif QEMU3DFX_WINE_VER >= 400
#define RESOURCE_RT_OFFSET 0x30
#define RESOURCE_RT_BIT    0x20
#elif QEMU3DFX_WINE_VER >= 300
#define RESOURCE_RT_OFFSET 0x2c
#define RESOURCE_RT_BIT    0x1
#else
#define RESOURCE_RT_OFFSET 0x28
#define RESOURCE_RT_BIT    0x1
#endif

void WINAPI wined3d_override_rendertarget_view(void *view_ptr)
{
    char *resource;
    DWORD *flags;

    if (!view_ptr)
        return;
    resource = ((char **)view_ptr)[1];
    flags = (DWORD *)(resource + RESOURCE_RT_OFFSET);
    if (!(*flags & RESOURCE_RT_BIT))
        *flags |= RESOURCE_RT_BIT;
}

/* ===================================================================== */
/* 3. Internal API for wined3d core (swapchain / adapter / device)       */
/* ===================================================================== */

BOOL qemu3dfx_use_last_context_tid(void)
{
    cfg_load();
    return cfg.use_last_context_tid != 0;
}

DWORD qemu3dfx_scale_window_value(void)
{
    cfg_load();
    return cfg.scale_window;
}

/* Reference 0x10029473: shrink a presentation rectangle by DisplayROI,
 * packed as (x_margin << 16) | y_margin (15 bits each). */
void qemu3dfx_display_roi(RECT *rect)
{
    DWORD roi, dx, dy;

    cfg_load();
    roi = cfg.display_roi;
    if (roi == 0xffffffff || !rect)
        return;
    dy = roi & 0x7fff;
    dx = (roi >> 16) & 0x7fff;
    rect->top += dy;
    rect->bottom -= dy;
    rect->left += dx;
    rect->right -= dx;
}

/* Reference 0x100294a2: rewrite a DEVMODEA before ChangeDisplaySettings.
 * OverrideModeWidth packs (width << 16) | height, or just a width (the
 * height then follows the requested aspect ratio).  The sign bit, or a
 * request below 16 bpp, forces 16 bpp.  Returns TRUE if *dm changed. */
BOOL qemu3dfx_override_mode(DEVMODEA *dm)
{
    DWORD v, width, height, bpp;

    cfg_load();
    v = cfg.override_mode_width;
    if (v == 0xffffffff || !dm)
        return FALSE;

    if (v & 0x7fff0000)
    {
        width = (v >> 16) & 0x7fff;
        height = v & 0x7fff;
    }
    else
    {
        width = v & 0x7fff;
        height = MulDiv(width, dm->dmPelsHeight, dm->dmPelsWidth);
    }
    if (!width)
        width = dm->dmPelsWidth;
    if (!height)
        height = dm->dmPelsHeight;
    bpp = dm->dmBitsPerPel;

    if (width == dm->dmPelsWidth && height == dm->dmPelsHeight
            && (LONG)v >= 0 && bpp > 15)
        return FALSE;

    if (bpp <= 15 || (LONG)v < 0)
        bpp = 16;
    dm->dmBitsPerPel = bpp;
    dm->dmPelsWidth = width;
    dm->dmPelsHeight = height;
    return TRUE;
}

/* Reference 0x1002954b: SwapInterval overrides the requested interval. */
void qemu3dfx_swap_interval(int *interval)
{
    cfg_load();
    if (cfg.swap_interval != 0xffffffff && interval)
        *interval = (int)cfg.swap_interval;
}

/* Reference 0x1002987b: ScaleWindow support.  Fills the scaled window
 * rect (size packed as (width << 16) | height, origin 0,0), the screen
 * rect, and sets *mode = 2 when the sign bit asks for it.  Returns FALSE
 * (and touches nothing) when ScaleWindow is not configured.  The window
 * rect's top is passed through wined3d_override_cooplevel exactly as the
 * reference does (identical-code-folded helper). */
BOOL qemu3dfx_scale_window(RECT *window, RECT *screen, DWORD *mode)
{
    cfg_load();
    if (cfg.scale_window == 0xffffffff)
        return FALSE;

    if (window)
    {
        window->left = 0;
        window->top = 0;
        wined3d_override_cooplevel((DWORD *)&window->top);
        window->bottom = cfg.scale_window & 0xffff;
        window->right = (cfg.scale_window >> 16) & 0x7fff;
    }
    if (screen)
    {
        screen->left = 0;
        screen->top = 0;
        screen->right = GetSystemMetrics(SM_CXSCREEN);
        screen->bottom = GetSystemMetrics(SM_CYSCREEN);
    }
    if (mode && (LONG)cfg.scale_window < 0)
        *mode = 2;
    return TRUE;
}

/* Three single-value latches used by wined3d core (reference 0x10029431,
 * 0x10029447, 0x1002945d): a non-zero argument stores, every call returns
 * the stored value.  latch0 is set from DllMain(DLL_PROCESS_ATTACH) with
 * hInstDLL just before wined3d_dll_init(); latch1/latch2 are set from the
 * present path (see re/CALLSITES.md). */
static ULONG_PTR latch[3];

ULONG_PTR qemu3dfx_latch0(ULONG_PTR v) { if (v) latch[0] = v; return latch[0]; }
ULONG_PTR qemu3dfx_latch1(ULONG_PTR v) { if (v) latch[1] = v; return latch[1]; }
ULONG_PTR qemu3dfx_latch2(ULONG_PTR v) { if (v) latch[2] = v; return latch[2]; }

/* --- Silent Hill 4 FMV fix (reference 2.0.5+, 8.0.2 0x1004ee08 and
 *     0x1004f563) ---------------------------------------------------- */

#if QEMU3DFX_WINE_MAJOR >= 2
static BOOL exe_is_silent_hill_4(void)
{
    static const char * const exe_names[] = { "Silent Hill 4.exe", NULL };
    char buf[MAX_PATH];
    const char * const *name;
    DWORD len;

    len = GetModuleFileNameA(NULL, buf, sizeof(buf));
    if (len > sizeof(buf) - 1)
        return FALSE;
    for (name = exe_names; *name; ++name)
        if (!lstrcmpiA(*name, exe_basename(buf)))
            return TRUE;
    return FALSE;
}
#endif

/* Called from wined3d_texture_validate_location() right after
 * sub_resource->locations |= location.  While DirectShow (quartz.dll) is
 * loaded, a sub-resource that just became SYSMEM|TEXTURE_RGB (0x12) with
 * sysmem_count == 1 gets its count bumped, so the decrement that follows
 * does not drop the system-memory copy the game's video path relies on. */
void qemu3dfx_sysmem_count_quirk(DWORD locations, LONG *sysmem_count)
{
#if QEMU3DFX_WINE_MAJOR >= 2
    if (!GetModuleHandleA("quartz"))
        return;
    if (locations != 0x12 || *sysmem_count != 1)
        return;
    if (exe_is_silent_hill_4())
        ++*sysmem_count;
#endif
}

/* --- host cursor channel ------------------------------------------- */

/*
 * qemu-3dfx's opengl32 wrapper exposes WGL_3DFX_gamma_control, including
 * wglSetDeviceCursor3DFX, and watches glDebugMessageInsertARB for a magic
 * message carrying the cursor position.  Both are resolved here with
 * wglGetProcAddress (a GL context must be current, which it is on the
 * present path that calls into this), so the module does not depend on
 * each Wine version's gl_info layout.
 */
typedef BOOL (WINAPI *PFN_wglSetDeviceCursor3DFX)(HCURSOR);
typedef void (WINAPI *PFN_glDebugMessageInsertARB)(unsigned int, unsigned int,
        unsigned int, unsigned int, int, const char *);

static PFN_wglSetDeviceCursor3DFX p_wglSetDeviceCursor3DFX;
static PFN_glDebugMessageInsertARB p_glDebugMessageInsertARB;
static BOOL cursor_procs_resolved;

static void cursor_resolve(void)
{
    if (cursor_procs_resolved)
        return;
    p_wglSetDeviceCursor3DFX = (PFN_wglSetDeviceCursor3DFX)(void *)
            wglGetProcAddress("wglSetDeviceCursor3DFX");
    p_glDebugMessageInsertARB = (PFN_glDebugMessageInsertARB)(void *)
            wglGetProcAddress("glDebugMessageInsertARB");
    cursor_procs_resolved = TRUE;
}

/* Reference 0x10029561: hand a cursor image to the host.  Called from
 * wined3d_device_set_cursor_properties() after CreateIconIndirect, and
 * from the cursor sync below. */
void qemu3dfx_set_host_cursor(HCURSOR cursor)
{
    cursor_resolve();
    if (p_wglSetDeviceCursor3DFX && qemu3dfx_is_qemu_bochs())
        p_wglSetDeviceCursor3DFX(cursor);
}

/* Reference 0x10029592: at most every 16 ms, read the guest cursor, map
 * it from window to screen coordinates, and when it moved (or was hidden)
 * send the new image and position to the host.  Called on present. */
static DWORD cursor_last_tick;
static POINT cursor_last;

void qemu3dfx_cursor_sync(HWND window)
{
    CURSORINFO ci;
    RECT wr, cr;
    DWORD now;
    POINT pt;
    LONG win_w, win_h, frame_h;
    DWORD packed;

    now = GetTickCount();
    memset(&ci, 0, sizeof(ci));
    ci.cbSize = sizeof(ci);                  /* 0x14 */
    pt = cursor_last;

    if (now - cursor_last_tick > 15 && qemu3dfx_is_qemu_bochs() && GetCursorInfo(&ci))
    {
        if (ci.flags != CURSOR_SHOWING)
        {
            pt.x = 0;
            pt.y = 0;
        }
        else
        {
            pt = ci.ptScreenPos;
            cursor_last_tick = now;
            GetWindowRect(window, &wr);
            GetClientRect(window, &cr);

            win_h = wr.bottom - wr.top;
            frame_h = win_h - cr.bottom;     /* caption + borders */
            pt.y = pt.y > frame_h ? pt.y - frame_h : 0;
            win_w = wr.right - wr.left;

            if (pt.x < win_w || win_h > pt.y)
            {
                pt.x = MulDiv(pt.x, GetSystemMetrics(SM_CXSCREEN) - 1, win_w - 1);
                pt.y = MulDiv(pt.y, GetSystemMetrics(SM_CYSCREEN) - 1, win_h - 1);
            }
        }
    }

    if (!memcmp(&cursor_last, &pt, sizeof(pt)))
        return;

    qemu3dfx_set_host_cursor(ci.hCursor);
    cursor_last = pt;

    cursor_resolve();
    if (p_glDebugMessageInsertARB)
    {
        packed = (((DWORD)pt.x << 16) & 0x7fff0000) | ((DWORD)pt.y & 0x7fff);
        /* GL_DEBUG_SOURCE_WINDOW_SYSTEM, GL_DEBUG_TYPE_OTHER, id 0x9148,
         * severity ~0: the qemu-3dfx wrapper's cursor-position message. */
        p_glDebugMessageInsertARB(0x8247, 0x8251, 0x9148, 0xffffffff, 4, (const char *)&packed);
    }
}
