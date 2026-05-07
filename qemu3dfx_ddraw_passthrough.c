/*
 * qemu-3dfx DirectDraw passthrough bridge
 *
 * Bridges ddraw.dll to wined3d passthrough functions for
 * qemu-3dfx MESA OpenGL passthrough support.
 *
 * Build: this file is injected into the ddraw build by build-ci.sh.
 */

#ifndef _WIN32
#error "This file is for Windows PE targets only"
#endif

#include <windows.h>

/* Passthrough functions exported by wined3d.dll */
extern BOOL WINAPI wined3d_hal_3dfx(void);
extern BOOL WINAPI wined3d_enum_hal_last(void);
extern void *WINAPI wined3d_surface_ddheap(void);
extern BOOL WINAPI wined3d_passthru(BOOL *enabled);
extern void WINAPI wined3d_override_cooplevel(DWORD *cooplevel);
extern void WINAPI wined3d_override_rendertarget_view(void *view_ptr);
extern BOOL WINAPI wined3d_blit_fpslimit(void);
extern BOOL WINAPI wined3d_flip_fpslimit(void);

static BOOL g_passthru_active;

/* Initialize passthrough — called from DllMain DLL_PROCESS_ATTACH */
void qemu3dfx_ddraw_passthrough_init(void)
{
    if (wined3d_hal_3dfx())
    {
        BOOL enable = TRUE;
        wined3d_passthru(&enable);
        g_passthru_active = TRUE;
        wined3d_enum_hal_last();
        wined3d_surface_ddheap();
    }
}

/* Override cooperative level for passthrough — called from SetCooperativeLevel */
void qemu3dfx_ddraw_cooplevel(DWORD *cooplevel)
{
    if (g_passthru_active && cooplevel)
        wined3d_override_cooplevel(cooplevel);
}

/* Blit frame rate limiter — called from ddraw_surface_blt */
void qemu3dfx_ddraw_blit(void)
{
    if (g_passthru_active)
        wined3d_blit_fpslimit();
}

/* Flip frame rate limiter — called from ddraw_surface7_Flip */
void qemu3dfx_ddraw_flip(void)
{
    if (g_passthru_active)
        wined3d_flip_fpslimit();
}

/* Render target view passthrough override — called when setting RTV */
void qemu3dfx_ddraw_rtv(void *view)
{
    if (g_passthru_active && view)
        wined3d_override_rendertarget_view(view);
}
