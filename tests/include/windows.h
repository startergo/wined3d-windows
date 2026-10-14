/*
 * Mock Windows types and API declarations for host (Linux/macOS) unit tests.
 *
 * Replaces the real <windows.h> when compiling the qemu-3dfx C sources on a
 * non-Windows host (via -Itests/include -D_WIN32).  Only the subset used by
 * qemu3dfx_hooks.c, qemu3dfx_ddraw_hooks.c and qemu3dfx_ddraw_passthrough.c
 * is provided; implementations live in tests/mock_win32.c.
 *
 * Integer types use Windows' sizes (DWORD/LONG are 32-bit) so code that
 * relies on 32-bit wrap-around and sign bits behaves as on Win32.
 */
#ifndef MOCK_WINDOWS_H
#define MOCK_WINDOWS_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── Basic types ─────────────────────────────────────────────────── */
typedef int            BOOL;
typedef uint32_t       DWORD;
typedef uint32_t       UINT;
typedef int32_t        LONG;
typedef int32_t        HRESULT;
typedef uint32_t       ULONG;
typedef uintptr_t      ULONG_PTR;
typedef uintptr_t      SIZE_T;
typedef void          *HANDLE;
typedef uint16_t       WORD;
typedef uint8_t        BYTE;
typedef const char    *LPCSTR;
typedef char          *LPSTR;
typedef DWORD         *LPDWORD;
typedef BYTE          *LPBYTE;
typedef HANDLE         HMODULE;
typedef HANDLE         HINSTANCE;
typedef HANDLE         HWND;
typedef HANDLE         HCURSOR;
typedef HANDLE         HDC;
typedef HANDLE         HKEY;
typedef HKEY          *PHKEY;
typedef intptr_t     (*PROC)(void);
typedef intptr_t     (*FARPROC)(void);

/* COM basics used by the ddraw passthrough */
typedef struct _GUID { uint32_t Data1; uint16_t Data2, Data3; uint8_t Data4[8]; } GUID;
typedef GUID IID;
typedef const IID *REFIID;
typedef struct IUnknown IUnknown;

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
#define INVALID_HANDLE_VALUE ((HANDLE)(intptr_t)-1)
#define GENERIC_READ         0x80000000UL
#define GENERIC_WRITE        0x40000000UL
#define OPEN_EXISTING        3
#define MAX_PATH             260
#define HKEY_CURRENT_USER    ((HKEY)(uintptr_t)0x80000001u)
#define REG_SZ               1
#define REG_DWORD            4
#define ERROR_SUCCESS        0
#define SM_CXSCREEN          0
#define SM_CYSCREEN          1
#define CURSOR_SHOWING       0x00000001

/* ── Calling convention ───────────────────────────────────────────── */
/* stdcall does not exist on x86-64 hosts; treat it as a no-op. */
#ifndef WINAPI
#  define WINAPI
#endif
#ifndef __stdcall
#  define __stdcall
#endif

/* ── Structures ───────────────────────────────────────────────────── */
typedef struct _SECURITY_ATTRIBUTES {
    DWORD  nLength;
    void  *lpSecurityDescriptor;
    BOOL   bInheritHandle;
} SECURITY_ATTRIBUTES;

typedef struct tagPOINT { LONG x, y; } POINT;
typedef struct tagRECT { LONG left, top, right, bottom; } RECT;

typedef struct tagCURSORINFO {
    DWORD   cbSize;
    DWORD   flags;
    HCURSOR hCursor;
    POINT   ptScreenPos;
} CURSORINFO;

typedef struct _DISPLAY_DEVICEA {
    DWORD cb;
    char  DeviceName[32];
    char  DeviceString[128];
    DWORD StateFlags;
    char  DeviceID[128];
    char  DeviceKey[128];
} DISPLAY_DEVICEA;

/* only the fields the sources touch, at their real DEVMODEA offsets */
typedef struct _devicemodeA {
    BYTE  dmDeviceName[32];
    WORD  dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
    DWORD dmFields;
    BYTE  dmUnion[16];
    short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    BYTE  dmFormName[32];
    WORD  dmLogPixels;
    DWORD dmBitsPerPel;      /* 0x68 */
    DWORD dmPelsWidth;       /* 0x6c */
    DWORD dmPelsHeight;      /* 0x70 */
    DWORD dmDisplayFlags;
    DWORD dmDisplayFrequency;
} DEVMODEA;

/* ── Windows API declarations ─────────────────────────────────────── */
HANDLE CreateFileA(LPCSTR lpFileName, DWORD dwDesiredAccess, DWORD dwShareMode,
                   SECURITY_ATTRIBUTES *lpSecurityAttributes,
                   DWORD dwCreationDisposition, DWORD dwFlagsAndAttributes,
                   HANDLE hTemplateFile);
BOOL   CloseHandle(HANDLE hObject);
HANDLE GetModuleHandleA(LPCSTR lpModuleName);
void  *GetProcAddress(HANDLE hModule, LPCSTR lpProcName);
HMODULE LoadLibraryA(LPCSTR name);
BOOL   FreeLibrary(HMODULE module);
DWORD  GetModuleFileNameA(HMODULE module, LPSTR buf, DWORD size);

LONG   RegOpenKeyA(HKEY key, LPCSTR subkey, PHKEY result);
LONG   RegQueryValueExA(HKEY key, LPCSTR name, LPDWORD reserved, LPDWORD type,
                        void *data, LPDWORD size);
LONG   RegCloseKey(HKEY key);

LPSTR  lstrcpyA(LPSTR dst, LPCSTR src);
LPSTR  lstrcatA(LPSTR dst, LPCSTR src);
int    lstrcmpiA(LPCSTR a, LPCSTR b);

DWORD  GetTickCount(void);
void   Sleep(DWORD ms);
int    MulDiv(int a, int b, int c);

BOOL   EnumDisplayDevicesA(LPCSTR device, DWORD index, DISPLAY_DEVICEA *dd, DWORD flags);
int    GetSystemMetrics(int index);
BOOL   GetCursorInfo(CURSORINFO *ci);
BOOL   GetWindowRect(HWND hwnd, RECT *rect);
BOOL   GetClientRect(HWND hwnd, RECT *rect);
PROC   wglGetProcAddress(LPCSTR name);

#ifdef __cplusplus
}
#endif

#endif /* MOCK_WINDOWS_H */
