/*
 * Minimal DLL entry point for Win9x compatibility.
 * No CRT startup → no HeapCreate → malloc comes from msvcrt.dll.
 * Skips _initterm since these DLLs are pure C (no C++ ctors).
 */
#include <windows.h>

#define DEFAULT_SECURITY_COOKIE 0xBB40E64E

DECLSPEC_SELECTANY UINT_PTR __security_cookie = DEFAULT_SECURITY_COOKIE;
DECLSPEC_SELECTANY UINT_PTR __security_cookie_complement = ~(DEFAULT_SECURITY_COOKIE);

void __cdecl __security_init_cookie(void)
{
}

/* Default DllMain — overriden by DLLs that have their own (wined3d, ddraw).
 * d3d8/d3d9 don't define DllMain so they use this no-op default. */
__attribute__((weak)) BOOL WINAPI DllMain(HINSTANCE hinstDLL, DWORD fdwReason, LPVOID lpvReserved)
{
    return TRUE;
}

static __declspec(noinline) WINBOOL
__DllMainCRTStartup(HANDLE hDllHandle, DWORD dwReason, LPVOID lpReserved)
{
    return DllMain(hDllHandle, dwReason, lpReserved);
}

WINBOOL WINAPI DllMainCRTStartup(HANDLE hDllHandle, DWORD dwReason, LPVOID lpReserved)
{
    if (dwReason == DLL_PROCESS_ATTACH) {
        __security_init_cookie();
    }
    return __DllMainCRTStartup(hDllHandle, dwReason, lpReserved);
}

void _pei386_runtime_relocator(void) {}
void __cdecl _amsg_exit(int code) { for (;;); }
