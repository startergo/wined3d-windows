/*
 * Minimal DLL entry point for Win9x compatibility.
 * Based on wine9x's nocrt/nocrt_dll.c — skips full CRT startup
 * (HeapCreate, _initterm, etc.) that crashes on Win98 KERNEL32.
 * CRT functions (malloc, free, etc.) still work via msvcrt.dll imports.
 */
#include <windows.h>

/* security cookie = buffer overrun protection */
#ifndef _WIN64
#define DEFAULT_SECURITY_COOKIE 0xBB40E64E
#else
#define DEFAULT_SECURITY_COOKIE 0x00002B992DDFA232ll
#endif

DECLSPEC_SELECTANY UINT_PTR __security_cookie = DEFAULT_SECURITY_COOKIE;
DECLSPEC_SELECTANY UINT_PTR __security_cookie_complement = ~(DEFAULT_SECURITY_COOKIE);

typedef union {
    unsigned __int64 ft_scalar;
    FILETIME ft_struct;
} FT;

void __cdecl __security_init_cookie(void)
{
    UINT_PTR cookie;
    FT systime = { 0, };
    LARGE_INTEGER perfctr;

    if (__security_cookie != DEFAULT_SECURITY_COOKIE) {
        __security_cookie_complement = ~__security_cookie;
        return;
    }

    GetSystemTimeAsFileTime(&systime.ft_struct);
#ifndef _WIN64
    cookie = systime.ft_struct.dwLowDateTime;
    cookie ^= systime.ft_struct.dwHighDateTime;
#else
    cookie = systime.ft_scalar;
#endif

    cookie ^= GetCurrentProcessId();
    cookie ^= GetCurrentThreadId();
    cookie ^= GetTickCount();

    QueryPerformanceCounter(&perfctr);
#ifndef _WIN64
    cookie ^= perfctr.LowPart;
    cookie ^= perfctr.HighPart;
#else
    cookie ^= perfctr.QuadPart;
#endif

#ifndef _WIN64
    if (cookie == DEFAULT_SECURITY_COOKIE)
        cookie = DEFAULT_SECURITY_COOKIE + 1;
#endif
    __security_cookie = cookie;
    __security_cookie_complement = ~cookie;
}

BOOL WINAPI DllMain(HINSTANCE hinstDLL, DWORD fdwReason, LPVOID lpvReserved);

static __declspec(noinline) WINBOOL
__DllMainCRTStartup(HANDLE hDllHandle, DWORD dwReason, LPVOID lpreserved)
{
    return DllMain(hDllHandle, dwReason, lpreserved);
}

WINBOOL WINAPI DllMainCRTStartup(HANDLE hDllHandle, DWORD dwReason, LPVOID lpreserved)
{
    if (dwReason == DLL_PROCESS_ATTACH) {
        __security_init_cookie();
    }
    return __DllMainCRTStartup(hDllHandle, dwReason, lpreserved);
}

/* no-op stubs for CRT internal functions that might be referenced */
void _pei386_runtime_relocator(void) {}
void __cdecl _amsg_exit(int code) { ExitProcess((UINT)code); }
