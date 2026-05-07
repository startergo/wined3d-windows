/*
 * Mock implementations of the Windows kernel32 API used by
 * qemu3dfx_hooks.c on Linux.
 *
 * The mock_* globals let individual test functions control the
 * behaviour of each mock without rebuilding.
 */
#include <string.h>
#include "include/windows.h"

/* ── Controllable mock state ─────────────────────────────────────── */

/* Set to 1 to make CreateFileA("\\.\QEMUchs",...) succeed. */
int mock_qemuchs_accessible = 0;

/* Set to a non-NULL value to make GetModuleHandleA("opengl32.dll") succeed. */
HANDLE mock_opengl32_handle = NULL;

/* ── CreateFileA ─────────────────────────────────────────────────── */
HANDLE CreateFileA(LPCSTR name, DWORD access, DWORD share,
                   SECURITY_ATTRIBUTES *sa, DWORD creation,
                   DWORD flags, HANDLE tmpl)
{
    (void)access; (void)share; (void)sa;
    (void)creation; (void)flags; (void)tmpl;

    if (name && strcmp(name, "\\\\.\\QEMUchs") == 0)
        return mock_qemuchs_accessible ? (HANDLE)1 : INVALID_HANDLE_VALUE;

    return INVALID_HANDLE_VALUE;
}

/* ── CloseHandle ─────────────────────────────────────────────────── */
BOOL CloseHandle(HANDLE h)
{
    (void)h;
    return TRUE;
}

/* ── GetModuleHandleA ────────────────────────────────────────────── */
HANDLE GetModuleHandleA(LPCSTR name)
{
    if (name && strcmp(name, "opengl32.dll") == 0)
        return mock_opengl32_handle;

    return NULL;
}

/* ── GetProcAddress ─────────────────────────────────────────────── */
/* Always returns NULL so load_wgl_3dfx_extensions() finds nothing. */
void *GetProcAddress(HANDLE h, LPCSTR name)
{
    (void)h; (void)name;
    return NULL;
}
