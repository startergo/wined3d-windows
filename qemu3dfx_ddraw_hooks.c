/*
 * qemu-3dfx DirectDraw HAL stubs for Wine ddraw
 *
 * Provides VidMem/HAL export stubs for the qemu-3dfx MESA OpenGL
 * passthrough layer.  These stubs satisfy the export table so the
 * wrapper and HAL enumeration can find them.
 *
 * Build: this file is injected into the ddraw build.
 */

#ifndef _WIN32
#error "This file is for Windows PE targets only"
#endif

#include <windows.h>

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

/* Internal surface lock (DD-prefixed) */
long WINAPI DDInternalLock(void *lpDDSurface, void **ppBits, void *lpRect, DWORD dwFlags)
{
    return 0;
}

/* Internal surface unlock (DD-prefixed) */
long WINAPI DDInternalUnlock(void *lpDDSurface, void *lpSurfaceData, DWORD dwFlags)
{
    return 0;
}

/* Acquire DirectDraw thread lock */
extern void WINAPI wined3d_mutex_lock(void);
void WINAPI AcquireDDThreadLock(void)
{
    wined3d_mutex_lock();
}

/* Release DirectDraw thread lock */
extern void WINAPI wined3d_mutex_unlock(void);
void WINAPI ReleaseDDThreadLock(void)
{
    wined3d_mutex_unlock();
}

/* Complete creation of a system memory surface */
long WINAPI CompleteCreateSysmemSurface(void *lpDDSurface)
{
    return 0;
}

/* Parse unknown D3D command */
long WINAPI D3DParseUnknownCommand(void *lpCmd, void **lpRetCmd)
{
    if (lpRetCmd) *lpRetCmd = lpCmd;
    return 0x8876086A; /* D3DERR_COMMAND_UNPARSED */
}

/* COM exports removed from Wine 7.0+ ddraw */
HRESULT WINAPI DllCanUnloadNow(void) { return 1; }
HRESULT WINAPI DllRegisterServer(void) { return 0; }
HRESULT WINAPI DllUnregisterServer(void) { return 0; }
