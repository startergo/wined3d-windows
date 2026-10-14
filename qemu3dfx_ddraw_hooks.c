/*
 * qemu-3dfx additions to Wine's ddraw.dll exports.
 *
 * Two groups, matching the reference ddraw.dll:
 *
 *   1. Real forwarders to the system DirectDraw (ddrawwq.dll):
 *      DDInternalLock, DDInternalUnlock, D3DParseUnknownCommand,
 *      CompleteCreateSysmemSurface, AcquireDDThreadLock, ReleaseDDThreadLock
 *      (see the block comment further down).
 *
 *   2. DirectDraw HAL/VidMem exports that nothing implements: DDHAL32_*,
 *      VidMem*, InternalLock/Unlock, HeapVidMemAllocAligned,
 *      LateAllocateSurfaceMem, GetNextMipMap, DSoundHelp.  Upstream Wine
 *      declares them "@ stub" and the reference build keeps those Wine spec
 *      stubs, which raise an "unimplemented function" exception when called.
 *      They exist so the export table matches; here they return 0/NULL
 *      instead of raising.  There is no reference code to port for them.
 *
 * Build: this file is injected into the ddraw build.
 */

#ifndef _WIN32
#error "This file is for Windows PE targets only"
#endif

#include <windows.h>
#include <string.h>

/* DirectDraw HAL video memory allocation */
DWORD WINAPI DDHAL32_VidMemAlloc(void *lpDD, int heap, DWORD dwWidth, DWORD dwHeight)
{
    return 0;
}

/* DirectDraw HAL video memory free */
void WINAPI DDHAL32_VidMemFree(void *lpDD, int heap, DWORD fpMem)
{
}

/* DirectSound helper */
long WINAPI DSoundHelp(void *hWnd, void *lpWndProc, DWORD pid)
{
    return 0;
}

/* Get next mipmap level */
void *WINAPI GetNextMipMap(void *lpDDSurface)
{
    return NULL;
}

/* Heap video memory allocation (aligned) */
DWORD WINAPI HeapVidMemAllocAligned(void *lpVidMem, DWORD dwWidth, DWORD dwHeight, void *lpAlignment, long *lpPitch)
{
    return 0;
}

/* Internal surface lock */
long WINAPI InternalLock(void *lpDDSurface, void **ppBits, void *lpRect, DWORD dwFlags)
{
    return 0;
}

/* Internal surface unlock */
long WINAPI InternalUnlock(void *lpDDSurface, void *lpSurfaceData, DWORD dwFlags)
{
    return 0;
}

/* Late surface memory allocation */
long WINAPI LateAllocateSurfaceMem(void *lpSurface, DWORD dwAllocType, DWORD dwWidth, DWORD dwHeight)
{
    return 0;
}

/* Video memory allocation */
DWORD WINAPI VidMemAlloc(DWORD fpStart, DWORD dwSize, void *lpHeap)
{
    return 0;
}

/* Amount of free video memory */
DWORD WINAPI VidMemAmountFree(void *lpHeap)
{
    return 0;
}

/* Video memory heap finalization */
void WINAPI VidMemFini(void *lpHeap)
{
}

/* Video memory free */
DWORD WINAPI VidMemFree(void *lpHeap, DWORD fpMem)
{
    return 0;
}

/* Video memory heap initialization */
void *WINAPI VidMemInit(DWORD dwFlags, DWORD fpStart, DWORD fpEnd, DWORD dwHeight, DWORD dwPitch)
{
    return NULL;
}

/* Largest free video memory block */
DWORD WINAPI VidMemLargestFree(void *lpHeap)
{
    return 0;
}

/* ------------------------------------------------------------------ */
/* Forwarders to the system DirectDraw (ddrawwq.dll)                   */
/* ------------------------------------------------------------------ */
/*
 * qemu-3dfx's ddthru installer renames the system ddraw.dll to ddrawwq.dll.
 * The reference ddraw.dll (8.0.2 build: table at 0x100330c0,
 * loader at 0x1000dbdc, forwarders at 0x1000ee24..0x1000ef6b)
 * loads it on first use, resolves twelve entry points, keeps them only if
 * the six core DirectDraw exports are all present, and forwards these six
 * exports to it, returning E_NOTIMPL when it is not available.
 *
 * Deliberate deviations (safer, documented):
 *   - a missing optional export returns E_NOTIMPL instead of calling NULL;
 *   - Acquire/ReleaseDDThreadLock fall back to the wined3d mutex (stock
 *     Wine behaviour) when ddrawwq.dll is absent, instead of doing nothing.
 */

typedef HRESULT (WINAPI *PFN_DDInternalLock)(void *, void **);
typedef HRESULT (WINAPI *PFN_DDInternalUnlock)(void *);
typedef HRESULT (WINAPI *PFN_D3DParseUnknownCommand)(void *, void **);
typedef HRESULT (WINAPI *PFN_CompleteCreateSysmemSurface)(void *);
typedef void (WINAPI *PFN_DDThreadLock)(void);

static struct
{
    HMODULE module;
    FARPROC DirectDrawCreate, DirectDrawCreateClipper, DirectDrawCreateEx;
    FARPROC DirectDrawEnumerateA, DirectDrawEnumerateExA, GetSurfaceFromDC;
    PFN_DDThreadLock AcquireDDThreadLock, ReleaseDDThreadLock;
    PFN_DDInternalLock DDInternalLock;
    PFN_DDInternalUnlock DDInternalUnlock;
    PFN_D3DParseUnknownCommand D3DParseUnknownCommand;
    PFN_CompleteCreateSysmemSurface CompleteCreateSysmemSurface;
} ddrawwq;

#define DDRAWWQ_PROC(name) (ddrawwq.name = (void *)GetProcAddress(ddrawwq.module, #name))

static void ddrawwq_load(void)
{
    if (ddrawwq.module)
        return;
    if (!(ddrawwq.module = LoadLibraryA("ddrawwq.dll")))
        return;

    DDRAWWQ_PROC(DirectDrawCreate);
    DDRAWWQ_PROC(DirectDrawCreateClipper);
    DDRAWWQ_PROC(DirectDrawCreateEx);
    DDRAWWQ_PROC(DirectDrawEnumerateA);
    DDRAWWQ_PROC(DirectDrawEnumerateExA);
    DDRAWWQ_PROC(GetSurfaceFromDC);
    DDRAWWQ_PROC(AcquireDDThreadLock);
    DDRAWWQ_PROC(ReleaseDDThreadLock);
    DDRAWWQ_PROC(DDInternalLock);
    DDRAWWQ_PROC(DDInternalUnlock);
    DDRAWWQ_PROC(D3DParseUnknownCommand);
    DDRAWWQ_PROC(CompleteCreateSysmemSurface);

    if (!ddrawwq.DirectDrawCreate || !ddrawwq.DirectDrawCreateEx
            || !ddrawwq.DirectDrawCreateClipper || !ddrawwq.GetSurfaceFromDC
            || !ddrawwq.DirectDrawEnumerateA || !ddrawwq.DirectDrawEnumerateExA)
    {
        /* not a usable DirectDraw: forget it entirely (reference 0x1000dba1) */
        FreeLibrary(ddrawwq.module);
        memset(&ddrawwq, 0, sizeof(ddrawwq));
    }
}

/* For qemu3dfx_ddthru.c: the loaded system DirectDraw table, or NULL.  Its
 * first seven fields are the layout struct ddrawwq_table there expects. */
void *qemu3dfx_ddrawwq_table(void)
{
    ddrawwq_load();
    return ddrawwq.module ? (void *)&ddrawwq : NULL;
}

#define E_NOTIMPL_ ((HRESULT)0x80004001L)

HRESULT WINAPI DDInternalLock(void *surface_lcl, void **bits)
{
    ddrawwq_load();
    if (!ddrawwq.module || !ddrawwq.DDInternalLock)
        return E_NOTIMPL_;
    return ddrawwq.DDInternalLock(surface_lcl, bits);
}

HRESULT WINAPI DDInternalUnlock(void *surface_lcl)
{
    ddrawwq_load();
    if (!ddrawwq.module || !ddrawwq.DDInternalUnlock)
        return E_NOTIMPL_;
    return ddrawwq.DDInternalUnlock(surface_lcl);
}

HRESULT WINAPI D3DParseUnknownCommand(void *command, void **next_command)
{
    ddrawwq_load();
    if (!ddrawwq.module || !ddrawwq.D3DParseUnknownCommand)
        return E_NOTIMPL_;
    return ddrawwq.D3DParseUnknownCommand(command, next_command);
}

HRESULT WINAPI CompleteCreateSysmemSurface(void *surface_lcl)
{
    ddrawwq_load();
    if (!ddrawwq.module || !ddrawwq.CompleteCreateSysmemSurface)
        return E_NOTIMPL_;
    return ddrawwq.CompleteCreateSysmemSurface(surface_lcl);
}

extern void WINAPI wined3d_mutex_lock(void);
extern void WINAPI wined3d_mutex_unlock(void);

void WINAPI AcquireDDThreadLock(void)
{
    ddrawwq_load();
    if (ddrawwq.module && ddrawwq.AcquireDDThreadLock)
        ddrawwq.AcquireDDThreadLock();
    else
        wined3d_mutex_lock();
}

void WINAPI ReleaseDDThreadLock(void)
{
    ddrawwq_load();
    if (ddrawwq.module && ddrawwq.ReleaseDDThreadLock)
        ddrawwq.ReleaseDDThreadLock();
    else
        wined3d_mutex_unlock();
}

/* COM exports removed from Wine 7.0+ ddraw */
HRESULT WINAPI DllCanUnloadNow(void) { return 1; }
HRESULT WINAPI DllRegisterServer(void) { return 0; }
HRESULT WINAPI DllUnregisterServer(void) { return 0; }
