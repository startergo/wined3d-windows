/*
 * qemu-3dfx DirectDraw HAL stubs for Wine ddraw
 *
 * Provides VidMem/HAL export stubs for the qemu-3dfx MESA OpenGL
 * passthrough layer.  The passthrough wrapper handles actual video
 * memory management; these stubs satisfy the export table so the
 * wrapper and HAL enumeration can find them.
 *
 * Build: this file is injected into the ddraw build by build-ci.sh.
 */

#ifndef _WIN32
#error "This file is for Windows PE targets only"
#endif

#include <windows.h>

/* DirectDraw HAL video memory allocation.
   DDK: FLATPTR WINAPI DDHAL32_VidMemAlloc(lpDD, heap, width, height) */
DWORD WINAPI DDHAL32_VidMemAlloc(void *lpDD, int heap, DWORD dwWidth, DWORD dwHeight)
{
    return 0;
}

/* DirectDraw HAL video memory free.
   DDK: void WINAPI DDHAL32_VidMemFree(lpDD, heap, fpMem) */
void WINAPI DDHAL32_VidMemFree(void *lpDD, int heap, DWORD fpMem)
{
}

/* DirectSound helper.
   DDK: HRESULT DSoundHelp(hWnd, lpWndProc, pid) */
long WINAPI DSoundHelp(void *hWnd, void *lpWndProc, DWORD pid)
{
    return 0;
}

/* Get next mipmap level */
void *WINAPI GetNextMipMap(void *lpDDSurface)
{
    return NULL;
}

/* Heap video memory allocation (aligned).
   DDK: FLATPTR WINAPI HeapVidMemAllocAligned(lpVidMem, width, height, lpAlignment, lpPitch) */
DWORD WINAPI HeapVidMemAllocAligned(void *lpVidMem, DWORD dwWidth, DWORD dwHeight, void *lpAlignment, long *lpPitch)
{
    return 0;
}

/* Internal surface lock.
   DDK: HRESULT InternalLock(lpDDSurface, ppBits, lpRect, dwFlags) */
long WINAPI InternalLock(void *lpDDSurface, void **ppBits, void *lpRect, DWORD dwFlags)
{
    return 0;
}

/* Internal surface unlock.
   DDK: HRESULT InternalUnlock(lpDDSurface, lpSurfaceData, dwFlags) */
long WINAPI InternalUnlock(void *lpDDSurface, void *lpSurfaceData, DWORD dwFlags)
{
    return 0;
}

/* Late surface memory allocation.
   DDK: HRESULT LateAllocateSurfaceMem(lpSurface, allocType, widthOrSize, height) */
long WINAPI LateAllocateSurfaceMem(void *lpSurface, DWORD dwAllocType, DWORD dwWidth, DWORD dwHeight)
{
    return 0;
}

/* Video memory allocation.
   DDK: FLATPTR WINAPI VidMemAlloc(start, size, heap) */
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

/* Video memory heap initialization.
   DDK: LPVMEMHEAP WINAPI VidMemInit(flags, start, end_or_width, height, pitch) */
void *WINAPI VidMemInit(DWORD dwFlags, DWORD fpStart, DWORD fpEnd, DWORD dwHeight, DWORD dwPitch)
{
    return NULL;
}

/* Largest free video memory block */
DWORD WINAPI VidMemLargestFree(void *lpHeap)
{
    return 0;
}

/* --- Standard ddraw.dll exports missing from Wine's @ stub entries --- */

/* Internal surface lock (DD-prefixed name expected by Windows apps).
   DDK: HRESULT DDInternalLock(lpDDSurface, ppBits, lpRect, dwFlags) */
long WINAPI DDInternalLock(void *lpDDSurface, void **ppBits, void *lpRect, DWORD dwFlags)
{
    return 0;
}

/* Internal surface unlock (DD-prefixed name).
   DDK: HRESULT DDInternalUnlock(lpDDSurface, lpSurfaceData, dwFlags) */
long WINAPI DDInternalUnlock(void *lpDDSurface, void *lpSurfaceData, DWORD dwFlags)
{
    return 0;
}

/* Acquire DirectDraw thread lock */
void WINAPI AcquireDDThreadLock(void)
{
}

/* Release DirectDraw thread lock */
void WINAPI ReleaseDDThreadLock(void)
{
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
