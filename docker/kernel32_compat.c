/* Win98-compatible stubs for XP+ kernel32 APIs used by Wine 1.8.7.
   Overrides CRT security cookie functions via asm to prevent pulling in
   GetCurrentProcessId, GetTickCount, QueryPerformanceCounter,
   TerminateProcess, etc. from the pre-compiled CRT startup. */
#include <string.h>
#include <stddef.h>
#ifndef __cdecl
#define __cdecl
#endif
#ifndef __stdcall
#define __stdcall __attribute__((stdcall))
#endif

#ifdef __MINGW32__

typedef unsigned long DWORD;
typedef unsigned short WCHAR;
typedef const WCHAR *LPCWSTR;
typedef unsigned long ULONG_PTR;
typedef void *HMODULE;
typedef int BOOL;
typedef unsigned int UINT_PTR;

/* --- Security cookie variables --- */
UINT_PTR __security_cookie = 0xBB40E64E;
UINT_PTR __security_cookie_complement = ~0xBB40E64EU;

/* --- Override CRT security functions via asm.
   32-bit cdecl: C name gets leading '_' in symbol table.
   __security_init_cookie → ___security_init_cookie
   _amsg_exit → __amsg_exit
   __pei386_runtime_relocator → ___pei386_runtime_relocator
   __security_check_cookie (fastcall) → @__security_check_cookie@4  */
__asm__("\n"
    ".globl ___security_init_cookie\n"
    "___security_init_cookie:\n"
    "    ret\n"
    ".globl @__security_check_cookie@4\n"
    "@__security_check_cookie@4:\n"
    "    ret $4\n"
    ".globl __amsg_exit\n"
    "__amsg_exit:\n"
    "    ret $4\n"
    ".globl ___pei386_runtime_relocator\n"
    "___pei386_runtime_relocator:\n"
    "    ret\n"
);

/* --- GetSystemTimeAsFileTime (Win2k+, not on Win98) --- */
void __stdcall GetSystemTime(void *st);
int __stdcall SystemTimeToFileTime(const void *st, void *ft);
void __stdcall GetSystemTimeAsFileTime(void *lpFileTime)
{
    char st[16];
    GetSystemTime(st);
    SystemTimeToFileTime(st, lpFileTime);
}

/* --- GetModuleHandleExW (kernel32, XP+ — not on Win98) --- */
#define GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS 0x4
HMODULE __stdcall GetModuleHandleA(const char *);
typedef struct { void *BaseAddress; void *AllocationBase; DWORD Partition; DWORD RegionSize; DWORD State; DWORD Protect; DWORD Type; } MBINFO;
DWORD __stdcall VirtualQuery(const void *, MBINFO *, DWORD);
BOOL __stdcall GetModuleHandleExW(DWORD flags, LPCWSTR name, HMODULE *module)
{
    if(!module) return 0;
    if(flags & GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS) {
        MBINFO mbi;
        if(VirtualQuery((const void *)name, &mbi, sizeof(mbi)))
            { *module = (HMODULE)mbi.AllocationBase; return 1; }
        return 0;
    }
    if(!name) { *module = (HMODULE)0x400000; return 1; }
    { char buf[260]; int i; for(i=0; i<259 && name[i]; i++) buf[i]=(char)name[i]; buf[i]=0;
      *module = GetModuleHandleA(buf); }
    return *module != 0;
}

/* --- HeapCreate stub (returns process heap) --- */
void *__stdcall GetProcessHeap(void);
void *__stdcall HeapCreate(unsigned long flOptions, unsigned long dwInitialSize, unsigned long dwMaximumSize)
{
    return GetProcessHeap();
}

/* --- __imp__ pointers --- */
__asm__("\n"
    ".globl __imp__HeapCreate@12\n"
    ".section .rdata,\"dr\"\n"
    ".align 4\n"
    "__imp__HeapCreate@12:\n"
    "    .long _HeapCreate@12\n"
    ".globl __imp__GetSystemTimeAsFileTime@4\n"
    ".align 4\n"
    "__imp__GetSystemTimeAsFileTime@4:\n"
    "    .long _GetSystemTimeAsFileTime@4\n"
    ".globl __imp__GetModuleHandleExW@12\n"
    ".align 4\n"
    "__imp__GetModuleHandleExW@12:\n"
    "    .long _GetModuleHandleExW@12\n"
    ".text\n"
);

/* --- oldexcepfilter for compact/exception.asm (wine9x-support) --- */
void *oldexcepfilter = 0;

/* --- Wine exception handler stubs (used by __TRY/__EXCEPT_PAGE_FAULT in ddraw) --- */
DWORD __wine_exception_handler_page_fault(void *record, void *frame,
                                           void *context, void **pdispatcher)
{
    return 0;
}
DWORD __wine_exception_handler(void *record, void *frame,
                                void *context, void **pdispatcher)
{
    return 0;
}
DWORD __wine_exception_handler_all(void *record, void *frame,
                                    void *context, void **pdispatcher)
{
    return 0;
}
void __wine_rtl_unwind(void *frame, void *record, void (*target)(void))
{
    if (target) target();
    for (;;);
}

#endif /* __MINGW32__ */
