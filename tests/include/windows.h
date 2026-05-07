/*
 * Mock Windows types and API declarations for Linux unit testing.
 *
 * Replaces the real <windows.h> when compiling the passthrough C sources
 * on a Linux host (via -Itests/include -D_WIN32).  Only the subset of
 * types and declarations actually used by the three source files is
 * provided here.
 */
#ifndef MOCK_WINDOWS_H
#define MOCK_WINDOWS_H

#ifdef __cplusplus
extern "C" {
#endif

/* ── Basic types ─────────────────────────────────────────────────── */
typedef int            BOOL;
typedef unsigned long  DWORD;
typedef void          *HANDLE;
typedef unsigned short WORD;
typedef unsigned char  BYTE;
typedef long           LONG;
typedef const char    *LPCSTR;
typedef char          *LPSTR;
typedef DWORD         *LPDWORD;
typedef HANDLE         HMODULE;

#ifndef TRUE
#  define TRUE  1
#endif
#ifndef FALSE
#  define FALSE 0
#endif
#ifndef NULL
#  define NULL ((void *)0)
#endif

/* ── Constants ────────────────────────────────────────────────────── */
#define INVALID_HANDLE_VALUE ((HANDLE)(long)-1)
#define GENERIC_READ         0x80000000UL
#define GENERIC_WRITE        0x40000000UL
#define OPEN_EXISTING        3

/* ── Calling convention ───────────────────────────────────────────── */
/* stdcall is not a real calling convention on Linux x86-64; treat
   both WINAPI and __stdcall as no-ops so the sources compile cleanly. */
#ifndef WINAPI
#  define WINAPI
#endif
#ifndef __stdcall
#  define __stdcall
#endif

/* ── SECURITY_ATTRIBUTES ─────────────────────────────────────────── */
typedef struct _SECURITY_ATTRIBUTES {
    DWORD  nLength;
    void  *lpSecurityDescriptor;
    BOOL   bInheritHandle;
} SECURITY_ATTRIBUTES;

/* ── Windows API declarations ─────────────────────────────────────── */
HANDLE CreateFileA(LPCSTR lpFileName, DWORD dwDesiredAccess, DWORD dwShareMode,
                   SECURITY_ATTRIBUTES *lpSecurityAttributes,
                   DWORD dwCreationDisposition, DWORD dwFlagsAndAttributes,
                   HANDLE hTemplateFile);
BOOL   CloseHandle(HANDLE hObject);
HANDLE GetModuleHandleA(LPCSTR lpModuleName);
void  *GetProcAddress(HANDLE hModule, LPCSTR lpProcName);

#ifdef __cplusplus
}
#endif

#endif /* MOCK_WINDOWS_H */
