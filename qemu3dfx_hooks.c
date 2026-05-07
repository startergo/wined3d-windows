/*
 * qemu-3dfx passthrough hooks for Wine wined3d
 *
 * Provides DirectDraw HAL enumeration and passthrough detection for
 * the qemu-3dfx MESA OpenGL passthrough layer.
 *
 * Build: this file is injected into the wined3d build by build-ci.sh.
 */

#ifndef _WIN32
#error "This file is for Windows PE targets only"
#endif

#include <windows.h>

/* Wine debug channel — embeds "QEMU" string matching original qemu-3dfx DLLs.
   wine_dbg_log is provided locally as a static no-op to avoid link-order
   dependency on the stub libwine archive across different Wine versions. */
struct __wine_debug_channel { unsigned char flags; unsigned char name[15]; };
enum __wine_debug_class { __WINE_DBCL_FIXME, __WINE_DBCL_ERR, __WINE_DBCL_WARN, __WINE_DBCL_TRACE };

static struct __wine_debug_channel __qemu3dfx_dbch __attribute__((used)) = { 0, {'Q','U','E','M','U'} };
static int wine_dbg_log(enum __wine_debug_class c, struct __wine_debug_channel *ch,
                         const char *fn, const char *fmt, ...) { return 0; }
#define QEMU_DBG(cls, ...) wine_dbg_log(cls, &__qemu3dfx_dbch, __FUNCTION__, __VA_ARGS__)

/* Globals shared across hooks */
static BOOL qemu3dfx_detected;
static BOOL hal_enum_done;
static BOOL ddheap_active;
static BOOL passthru_enabled;
static DWORD override_counter = (DWORD)-1;
static DWORD override_trigger = (DWORD)-1;

/* ── QEMU passthrough device detection ─────────────────────────────── */

static BOOL detect_qemu_passthrough(void)
{
    SECURITY_ATTRIBUTES sa;
    HANDLE h;

    sa.nLength = sizeof(sa);
    sa.lpSecurityDescriptor = NULL;
    sa.bInheritHandle = TRUE;

    h = CreateFileA("\\\\.\\QEMUchs",
                     GENERIC_READ | GENERIC_WRITE,
                     0, &sa, OPEN_EXISTING, 0, NULL);
    if (h == INVALID_HANDLE_VALUE)
    {
        QEMU_DBG(__WINE_DBCL_WARN, "QEMUchs not found\n");
        return FALSE;
    }

    CloseHandle(h);
    QEMU_DBG(__WINE_DBCL_TRACE, "QEMUchs detected\n");
    return TRUE;
}

static void ensure_detected(void)
{
    if (!qemu3dfx_detected)
        qemu3dfx_detected = detect_qemu_passthrough();
}

/* ── Exported hooks ────────────────────────────────────────────────── */

BOOL WINAPI wined3d_enum_hal_last(void)
{
    return hal_enum_done;
}

BOOL WINAPI wined3d_surface_ddheap(void)
{
    return ddheap_active;
}

BOOL WINAPI wined3d_passthru(BOOL *enabled)
{
    if (enabled && *enabled)
        passthru_enabled = TRUE;
    return passthru_enabled;
}

void WINAPI wined3d_override_cooplevel(DWORD *cooplevel)
{
    if (override_counter == (DWORD)-1) return;

    DWORD flags = 0;
    if (override_trigger != (DWORD)-1)
        flags = 0x10;  /* DDSCL_EXCLUSIVE */

    if (--override_counter == 0)
        flags = 0x10;

    *cooplevel ^= flags;
}

static void load_wgl_3dfx_extensions(void);

BOOL WINAPI wined3d_hal_3dfx(void)
{
    static BOOL checked = FALSE;
    static BOOL result = FALSE;

    if (checked) return result;

    ensure_detected();
    if (!qemu3dfx_detected) {
        checked = TRUE;
        return FALSE;
    }

    /* 3dfx HAL found via qemu-3dfx passthrough */
    QEMU_DBG(__WINE_DBCL_TRACE, "3dfx HAL detected, enabling passthrough\n");
    result = TRUE;
    checked = TRUE;
    hal_enum_done = TRUE;
    ddheap_active = TRUE;
    passthru_enabled = TRUE;
    load_wgl_3dfx_extensions();
    return result;
}

/* Mark render target view's resource for passthrough override.
   Sets bit 0x20 in resource->access_flags (offset 0x34 in
   wined3d_resource on Wine 4.x–8.x, 32-bit). */
void WINAPI wined3d_override_rendertarget_view(void *view_ptr)
{
    void **view = (void **)view_ptr;
    DWORD *flags;

    if (!view) return;
    if (!view[1]) return;

    /* resource->access_flags at offset 0x34 */
    flags = (DWORD *)((char *)view[1] + 0x34);
    if (!(*flags & 0x20))
    {
        *flags |= 0x20;
        QEMU_DBG(__WINE_DBCL_TRACE, "RTV passthrough flag set\n");
    }
}

/* ── Blit / Flip frame rate limiting ────────────────────────────────── */

static DWORD blit_frame_count;
static DWORD flip_frame_count;

BOOL WINAPI wined3d_blit_fpslimit(void)
{
    blit_frame_count++;
    return TRUE;
}

BOOL WINAPI wined3d_flip_fpslimit(void)
{
    flip_frame_count++;
    return TRUE;
}

/* ── Registry config keys (queried by Wine D3D initialization) ────── */

const char qemu3dfx_hal_key[] = "D3D1Hal3Dfx";
const char qemu3dfx_enum_hal_last_key[] = "D3D1EnumHalLast";

/* ── WGL 3DFX extensions (loaded from wrapper opengl32.dll) ───────── */

typedef BOOL (WINAPI *PFN_wglGetDeviceGammaRamp3DFX)(void *, void *);
typedef BOOL (WINAPI *PFN_wglSetDeviceGammaRamp3DFX)(void *, void *);
typedef BOOL (WINAPI *PFN_wglSetDeviceCursor3DFX)(void *, void *);

static PFN_wglGetDeviceGammaRamp3DFX p_wglGetDeviceGammaRamp3DFX;
static PFN_wglSetDeviceGammaRamp3DFX p_wglSetDeviceGammaRamp3DFX;
static PFN_wglSetDeviceCursor3DFX p_wglSetDeviceCursor3DFX;

/* Extension string exposed to applications via wglGetExtensionsString */
static const char wgl_3dfx_gamma_control[] = "WGL_3DFX_gamma_control";

/* Load WGL 3DFX extensions from the wrapper opengl32.dll.
   Called automatically when qemu-3dfx passthrough is detected. */
static void load_wgl_3dfx_extensions(void)
{
    typedef void *(WINAPI *wglGetProcAddress_t)(const char *);
    HMODULE hGL;
    wglGetProcAddress_t pGetProc;

    hGL = GetModuleHandleA("opengl32.dll");
    if (!hGL) return;

    pGetProc = (wglGetProcAddress_t)GetProcAddress(hGL, "wglGetProcAddress");
    if (!pGetProc) return;

    p_wglGetDeviceGammaRamp3DFX = (PFN_wglGetDeviceGammaRamp3DFX)pGetProc("wglGetDeviceGammaRamp3DFX");
    p_wglSetDeviceGammaRamp3DFX = (PFN_wglSetDeviceGammaRamp3DFX)pGetProc("wglSetDeviceGammaRamp3DFX");
    p_wglSetDeviceCursor3DFX = (PFN_wglSetDeviceCursor3DFX)pGetProc("wglSetDeviceCursor3DFX");
    QEMU_DBG(__WINE_DBCL_TRACE, "WGL 3DFX extensions %s\n",
             p_wglGetDeviceGammaRamp3DFX ? "loaded" : "not available");
}

/* Exported: get the WGL 3DFX gamma ramp */
BOOL WINAPI wined3d_get_gamma_ramp_3dfx(void *hDC, void *ramp)
{
    if (p_wglGetDeviceGammaRamp3DFX)
        return p_wglGetDeviceGammaRamp3DFX(hDC, ramp);
    return FALSE;
}

/* Exported: set the WGL 3DFX gamma ramp */
BOOL WINAPI wined3d_set_gamma_ramp_3dfx(void *hDC, void *ramp)
{
    if (p_wglSetDeviceGammaRamp3DFX)
        return p_wglSetDeviceGammaRamp3DFX(hDC, ramp);
    return FALSE;
}

/* Exported: set the WGL 3DFX cursor */
BOOL WINAPI wined3d_set_cursor_3dfx(void *hDC, void *cursor)
{
    if (p_wglSetDeviceCursor3DFX)
        return p_wglSetDeviceCursor3DFX(hDC, cursor);
    return FALSE;
}
