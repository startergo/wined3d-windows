/*
 * qemu-3dfx DirectDraw passthrough bridge with ddrawwq.dll switcher
 *
 * Reverse-engineered from reference qemu-3dfx Wine 1.8.7 ddraw.dll.
 * Loads ddrawwq.dll (the system's original ddraw) and provides a
 * passthrough function table for forwarding DirectDraw calls when
 * qemu-3dfx HAL is active.
 *
 * Build: this file is injected into the ddraw build.
 */

#ifndef _WIN32
#error "This file is for Windows PE targets only"
#endif

#include <windows.h>
#ifndef IUnknown
typedef struct IUnknown IUnknown;
#endif

#ifndef DDERR_GENERIC
#define DDERR_GENERIC 0x80004005  /* E_FAIL */
#endif

/* Passthrough functions exported by wined3d.dll */
extern BOOL WINAPI wined3d_hal_3dfx(void);
extern BOOL WINAPI wined3d_enum_hal_last(void);
extern BOOL WINAPI wined3d_passthru(BOOL *enabled);
extern void WINAPI wined3d_override_cooplevel(DWORD *cooplevel);
extern void WINAPI wined3d_override_rendertarget_view(void *view_ptr);
extern BOOL WINAPI wined3d_blit_fpslimit(void);
extern BOOL WINAPI wined3d_flip_fpslimit(void);

/* ── ddrawwq.dll function table ────────────────────────────────────── */

typedef HRESULT (WINAPI *PFN_DirectDrawCreate)(GUID *, void **, IUnknown *);
typedef HRESULT (WINAPI *PFN_DirectDrawCreateClipper)(DWORD, void *, IUnknown *);
typedef HRESULT (WINAPI *PFN_DirectDrawCreateEx)(GUID *, void **, REFIID, IUnknown *);
typedef HRESULT (WINAPI *PFN_DirectDrawEnumerateA)(void *, void *);
typedef HRESULT (WINAPI *PFN_DirectDrawEnumerateExA)(void *, void *, DWORD);
typedef HRESULT (WINAPI *PFN_GetSurfaceFromDC)(HDC, void **, void **);
typedef void    (WINAPI *PFN_AcquireDDThreadLock)(void);
typedef void    (WINAPI *PFN_ReleaseDDThreadLock)(void);

static HMODULE g_ddrawwq_handle;
static PFN_DirectDrawCreate        g_DirectDrawCreate;
static PFN_DirectDrawCreateClipper g_DirectDrawCreateClipper;
static PFN_DirectDrawCreateEx      g_DirectDrawCreateEx;
static PFN_DirectDrawEnumerateA    g_DirectDrawEnumerateA;
static PFN_DirectDrawEnumerateExA  g_DirectDrawEnumerateExA;
static PFN_GetSurfaceFromDC        g_GetSurfaceFromDC;
static PFN_AcquireDDThreadLock     g_AcquireDDThreadLock;
static PFN_ReleaseDDThreadLock     g_ReleaseDDThreadLock;

static BOOL g_passthru_active;

/* ── Load ddrawwq.dll and populate function table ─────────────────── */

static BOOL load_ddrawwq(void)
{
    HMODULE h;

    h = LoadLibraryA("ddrawwq.dll");
    if (!h) return FALSE;

    g_DirectDrawCreate        = (PFN_DirectDrawCreate)GetProcAddress(h, "DirectDrawCreate");
    g_DirectDrawCreateClipper = (PFN_DirectDrawCreateClipper)GetProcAddress(h, "DirectDrawCreateClipper");
    g_DirectDrawCreateEx      = (PFN_DirectDrawCreateEx)GetProcAddress(h, "DirectDrawCreateEx");
    g_DirectDrawEnumerateA    = (PFN_DirectDrawEnumerateA)GetProcAddress(h, "DirectDrawEnumerateA");
    g_DirectDrawEnumerateExA  = (PFN_DirectDrawEnumerateExA)GetProcAddress(h, "DirectDrawEnumerateExA");
    g_GetSurfaceFromDC        = (PFN_GetSurfaceFromDC)GetProcAddress(h, "GetSurfaceFromDC");
    g_AcquireDDThreadLock     = (PFN_AcquireDDThreadLock)GetProcAddress(h, "AcquireDDThreadLock");
    g_ReleaseDDThreadLock     = (PFN_ReleaseDDThreadLock)GetProcAddress(h, "ReleaseDDThreadLock");

    if (!g_DirectDrawCreate)
    {
        FreeLibrary(h);
        return FALSE;
    }

    g_ddrawwq_handle = h;
    return TRUE;
}

/* ── Initialize passthrough — called from DllMain DLL_PROCESS_ATTACH ─ */

void qemu3dfx_ddraw_passthrough_init(void)
{
    if (!wined3d_hal_3dfx())
        return;

    if (load_ddrawwq())
    {
        BOOL enable = TRUE;
        wined3d_passthru(&enable);
        g_passthru_active = TRUE;
    }

    wined3d_enum_hal_last();
}

/* ── Get passthrough function table ────────────────────────────────── */

BOOL qemu3dfx_ddraw_passthrough_get_table(void **table)
{
    if (!g_passthru_active || !table)
        return FALSE;

    table[0] = g_DirectDrawCreate;
    table[1] = g_DirectDrawCreateClipper;
    table[2] = g_DirectDrawCreateEx;
    table[3] = g_DirectDrawEnumerateA;
    table[4] = g_DirectDrawEnumerateExA;
    table[5] = g_GetSurfaceFromDC;
    table[6] = g_AcquireDDThreadLock;
    table[7] = g_ReleaseDDThreadLock;

    return TRUE;
}

/* ── Check if passthrough is active ────────────────────────────────── */

BOOL qemu3dfx_ddraw_is_passthru(void)
{
    return g_passthru_active;
}

/* ── Forward to ddrawwq.dll ───────────────────────────────────────── */

HRESULT qemu3dfx_ddraw_create(GUID *guid, void **lpDD, IUnknown *pUnkOuter)
{
    if (g_passthru_active && g_DirectDrawCreate)
        return g_DirectDrawCreate(guid, lpDD, pUnkOuter);
    return DDERR_GENERIC;
}

HRESULT qemu3dfx_ddraw_create_ex(GUID *guid, void **lpDD, REFIID iid, IUnknown *pUnkOuter)
{
    if (g_passthru_active && g_DirectDrawCreateEx)
        return g_DirectDrawCreateEx(guid, lpDD, iid, pUnkOuter);
    return DDERR_GENERIC;
}

HRESULT qemu3dfx_ddraw_create_clipper(DWORD dwFlags, void *lpDD, IUnknown *pUnkOuter)
{
    if (g_passthru_active && g_DirectDrawCreateClipper)
        return g_DirectDrawCreateClipper(dwFlags, lpDD, pUnkOuter);
    return DDERR_GENERIC;
}

/* ── Cooperative level override ────────────────────────────────────── */

void qemu3dfx_ddraw_cooplevel(DWORD *cooplevel)
{
    if (g_passthru_active && cooplevel)
        wined3d_override_cooplevel(cooplevel);
}

/* ── Blit/flip frame rate limiting ─────────────────────────────────── */

void qemu3dfx_ddraw_blit(void)
{
    if (g_passthru_active)
        wined3d_blit_fpslimit();
}

void qemu3dfx_ddraw_flip(void)
{
    if (g_passthru_active)
        wined3d_flip_fpslimit();
}

/* ── Render target view passthrough override ───────────────────────── */

void qemu3dfx_ddraw_rtv(void *view)
{
    if (g_passthru_active && view)
        wined3d_override_rendertarget_view(view);
}
