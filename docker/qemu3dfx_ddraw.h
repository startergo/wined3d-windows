/*
 * Prototypes for the qemu-3dfx call sites that docker/qemu3dfx_callsites.py
 * inserts into Wine's ddraw: the qemu-3dfx exports of wined3d.dll
 * (qemu3dfx_hooks.c) and the ddthru router (qemu3dfx_ddthru.c).
 */
#ifndef QEMU3DFX_DDRAW_H
#define QEMU3DFX_DDRAW_H

BOOL WINAPI wined3d_hal_3dfx(void);
BOOL WINAPI wined3d_enum_hal_last(void);
BOOL WINAPI wined3d_passthru(BOOL *enabled);
void WINAPI wined3d_override_cooplevel(DWORD *cooplevel);
void WINAPI wined3d_override_rendertarget_view(void *view);
BOOL WINAPI wined3d_blit_fpslimit(void);
BOOL WINAPI wined3d_flip_fpslimit(void);
BOOL WINAPI wined3d_surface_ddheap(void);

BOOL qemu3dfx_ddthru(void *caller);
HRESULT WINAPI qemu3dfx_ddthru_DirectDrawCreate(GUID *guid, void **ddraw, IUnknown *outer);
HRESULT WINAPI qemu3dfx_ddthru_DirectDrawCreateClipper(DWORD flags, void **clipper, IUnknown *outer);
HRESULT WINAPI qemu3dfx_ddthru_DirectDrawCreateEx(GUID *guid, void **ddraw, REFIID iid, IUnknown *outer);
HRESULT WINAPI qemu3dfx_ddthru_DirectDrawEnumerateA(void *callback, void *context);
HRESULT WINAPI qemu3dfx_ddthru_DirectDrawEnumerateExA(void *callback, void *context, DWORD flags);
HRESULT WINAPI qemu3dfx_ddthru_GetSurfaceFromDC(HDC dc, void **surface, HDC *device_dc);

/* The six entry points route on their own return address
 * (__builtin_return_address(0)); they must keep their own frame.  If one
 * were inlined into a caller inside ddraw.dll (IDirectDraw::CreateClipper
 * calls DirectDrawCreateClipper, DirectDrawEnumerateA calls ...ExA), the
 * "caller" would become the application and the internal call could be
 * routed to the system DirectDraw, which the reference never does. */
HRESULT WINAPI DirectDrawCreate(GUID *driver_guid, IDirectDraw **ddraw, IUnknown *outer) __attribute__((noinline));
HRESULT WINAPI DirectDrawCreateEx(GUID *driver_guid, void **ddraw, REFIID iid, IUnknown *outer) __attribute__((noinline));
HRESULT WINAPI DirectDrawCreateClipper(DWORD flags, IDirectDrawClipper **clipper, IUnknown *outer) __attribute__((noinline));
HRESULT WINAPI DirectDrawEnumerateA(LPDDENUMCALLBACKA callback, void *context) __attribute__((noinline));
HRESULT WINAPI DirectDrawEnumerateExA(LPDDENUMCALLBACKEXA callback, void *context, DWORD flags) __attribute__((noinline));
HRESULT WINAPI GetSurfaceFromDC(HDC dc, IDirectDrawSurface4 **surface, HDC *device_dc) __attribute__((noinline));

#endif /* QEMU3DFX_DDRAW_H */
