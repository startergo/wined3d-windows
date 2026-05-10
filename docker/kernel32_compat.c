/* Win98-compatible stubs for Vista+/Win2000+ kernel32/ntdll APIs.
   Each provides the function + __imp__ pointer for __declspec(dllimport).
   Adapted for Docker/Arch build: no __acrt_iob_func, __stdio_common_*,
   _vsnprintf, or __lc_codepage (handled by ucrtcompat.o in libmsvcrt.a). */
typedef unsigned long DWORD;
typedef unsigned long long DWORD64;
typedef unsigned short WCHAR;
typedef const WCHAR *LPCWSTR;
typedef unsigned long ULONG_PTR;
typedef void *HMODULE;
typedef int BOOL;
#ifndef __stdcall
#define __stdcall __attribute__((stdcall))
#endif

/* --- wine_k32compat_GMHEW (GetModuleHandleExW redirect) --- */
#define GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS 0x4
HMODULE __stdcall GetModuleHandleA(const char *);
typedef struct { void *BaseAddress; void *AllocationBase; DWORD Partition; DWORD RegionSize; DWORD State; DWORD Protect; DWORD Type; } MBINFO;
DWORD __stdcall VirtualQuery(const void *, MBINFO *, DWORD);
BOOL __stdcall wine_k32compat_GMHEW(DWORD flags, LPCWSTR name, HMODULE *module)
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

/* --- GlobalMemoryStatusEx (Win2000+) --- */
typedef struct { DWORD dwLength; DWORD dwMemoryLoad; DWORD dwTotalPhys; DWORD dwAvailPhys;
  DWORD dwTotalPageFile; DWORD dwAvailPageFile; DWORD dwTotalVirtual; DWORD dwAvailVirtual; } MEMSTATUS;
typedef struct { DWORD dwLength; DWORD dwMemoryLoad; DWORD64 ullTotalPhys; DWORD64 ullAvailPhys;
  DWORD64 ullTotalPageFile; DWORD64 ullAvailPageFile; DWORD64 ullTotalVirtual; DWORD64 ullAvailVirtual;
  DWORD64 ullAvailExtendedVirtual; } MEMSTATUSEX;
void __stdcall GlobalMemoryStatus(MEMSTATUS *);
BOOL __stdcall GlobalMemoryStatusEx(MEMSTATUSEX *lpBuffer)
{
    MEMSTATUS ms; ms.dwLength = sizeof(ms);
    GlobalMemoryStatus(&ms);
    lpBuffer->dwLength = sizeof(*lpBuffer);
    lpBuffer->dwMemoryLoad = ms.dwMemoryLoad;
    lpBuffer->ullTotalPhys = ms.dwTotalPhys;
    lpBuffer->ullAvailPhys = ms.dwAvailPhys;
    lpBuffer->ullTotalPageFile = ms.dwTotalPageFile;
    lpBuffer->ullAvailPageFile = ms.dwAvailPageFile;
    lpBuffer->ullTotalVirtual = ms.dwTotalVirtual;
    lpBuffer->ullAvailVirtual = ms.dwAvailVirtual;
    lpBuffer->ullAvailExtendedVirtual = 0;
    return 1;
}

/* --- RtlIsCriticalSectionLockedByThread (Vista+) --- */
typedef struct _RTL_CRITICAL_SECTION { void *DebugInfo; long LockCount; long RecursionCount; void *OwningThread; void *LockSemaphore; DWORD SpinCount; } CRITSEC;
DWORD __stdcall GetCurrentThreadId(void);
BOOL __stdcall RtlIsCriticalSectionLockedByThread(CRITSEC *cs)
{
    return cs && cs->OwningThread == (void *)(ULONG_PTR)GetCurrentThreadId() && cs->RecursionCount > 0;
}

/* --- InitOnceExecuteOnce (Vista+) --- */
typedef long BOOL_CALL_ONCE(void *, void **);
BOOL __stdcall InitOnceExecuteOnce(void *init_once, BOOL_CALL_ONCE *init_fn, void *param, void **context)
{
    if(init_fn) return init_fn(param, context ? context : (void **)init_once);
    return 1;
}

/* --- ConditionVariable family (Vista+) --- */
typedef struct _CONDITION_VARIABLE { void *Ptr; } CONDITION_VARIABLE;
void __stdcall InitializeConditionVariable(CONDITION_VARIABLE *cv) { if(cv) cv->Ptr = 0; }
void __stdcall WakeConditionVariable(CONDITION_VARIABLE *cv) { }
void __stdcall WakeAllConditionVariable(CONDITION_VARIABLE *cv) { }
unsigned long __stdcall SleepConditionVariableCS(CONDITION_VARIABLE *cv, CRITSEC *cs, unsigned long ms) { return 0; }

/* --- SetThreadDescription (Windows 10+) --- */
typedef long HRESULT;
typedef void *HANDLE;
typedef const unsigned short *PCWSTR;
HRESULT __stdcall SetThreadDescription(HANDLE hThread, PCWSTR lpThreadDescription) { return 0; }

/* --- _copysignf (Win98 msvcrt.dll only has _copysign double) --- */
double __cdecl _copysign(double x, double y);
float __cdecl _copysignf(float x, float y) { return (float)_copysign((double)x, (double)y); }

/* --- floorf (Win98 msvcrt.dll only has floor double) --- */
double __cdecl floor(double);
float __cdecl floorf(float x) { return (float)floor((double)x); }

/* --- _fstat32 (UCRT, not in Win98 msvcrt.dll) --- */
int __cdecl _fstat32(int fd, void *buf) { (void)fd; (void)buf; return -1; }

/* --- _initterm / _initterm_e (CRT startup, not in Win98 msvcrt.dll) --- */
typedef int (*_initfn)(void);
void __cdecl _initterm(_initfn *begin, _initfn *end)
{
    for (; begin < end; begin++)
        if (*begin) (*begin)();
}
int __cdecl _initterm_e(_initfn *begin, _initfn *end)
{
    for (; begin < end; begin++) {
        if (*begin) {
            int ret = (*begin)();
            if (ret) return ret;
        }
    }
    return 0;
}

/* --- strnlen (C11, not in Win98 msvcrt.dll) --- */
unsigned int __cdecl strnlen(const char *s, unsigned int maxlen) {
    unsigned int i = 0;
    while (i < maxlen && s[i]) i++;
    return i;
}

/* --- _isctype (internal CRT helper, not in Win98 msvcrt.dll) --- */
int __cdecl _isctype(int c, int mask) { (void)c; (void)mask; return 0; }

/* --- UCRT-specific floating-point classification (not in msvcrt.dll) --- */
int __cdecl _fdclass(float x) { (void)x; return 0; }
int __cdecl _dclass(double x) { (void)x; return 0; }
int __cdecl _dsign(double x) { (void)x; return 0; }
int __cdecl _fdsign(float x) { (void)x; return 0; }

/* UCRT __acrt_iob_func + __stdio_common_* are provided by ucrtcompat.o
   injected into libmsvcrt.a — do NOT duplicate here. */

/* --- __imp__ pointers for __declspec(dllimport) callers --- */
__asm__("\n"
    ".globl __imp___initterm\n"
    ".section .rdata,\"dr\"\n"
    ".align 4\n"
    "__imp___initterm:\n"
    "    .long __initterm\n"
    ".globl __imp___initterm_e\n"
    ".align 4\n"
    "__imp___initterm_e:\n"
    "    .long __initterm_e\n"
    ".globl __imp__wine_k32compat_GMHEW@12\n"
    ".section .rdata,\"dr\"\n"
    ".align 4\n"
    "__imp__wine_k32compat_GMHEW@12:\n"
    "    .long _wine_k32compat_GMHEW@12\n"
    ".globl __imp__GlobalMemoryStatusEx@4\n"
    ".align 4\n"
    "__imp__GlobalMemoryStatusEx@4:\n"
    "    .long _GlobalMemoryStatusEx@4\n"
    ".globl __imp__RtlIsCriticalSectionLockedByThread@4\n"
    ".align 4\n"
    "__imp__RtlIsCriticalSectionLockedByThread@4:\n"
    "    .long _RtlIsCriticalSectionLockedByThread@4\n"
    ".globl __imp__InitOnceExecuteOnce@16\n"
    ".align 4\n"
    "__imp__InitOnceExecuteOnce@16:\n"
    "    .long _InitOnceExecuteOnce@16\n"
    ".globl __imp__InitializeConditionVariable@4\n"
    ".align 4\n"
    "__imp__InitializeConditionVariable@4:\n"
    "    .long _InitializeConditionVariable@4\n"
    ".globl __imp__WakeConditionVariable@4\n"
    ".align 4\n"
    "__imp__WakeConditionVariable@4:\n"
    "    .long _WakeConditionVariable@4\n"
    ".globl __imp__WakeAllConditionVariable@4\n"
    ".align 4\n"
    "__imp__WakeAllConditionVariable@4:\n"
    "    .long _WakeAllConditionVariable@4\n"
    ".globl __imp__SleepConditionVariableCS@12\n"
    ".align 4\n"
    "__imp__SleepConditionVariableCS@12:\n"
    "    .long _SleepConditionVariableCS@12\n"
    ".globl __imp__SetThreadDescription@8\n"
    ".align 4\n"
    "__imp__SetThreadDescription@8:\n"
    "    .long _SetThreadDescription@8\n"
    ".globl __imp___copysignf\n"
    ".align 4\n"
    "__imp___copysignf:\n"
    "    .long __copysignf\n"
    ".globl __imp___fstat32\n"
    ".align 4\n"
    "__imp___fstat32:\n"
    "    .long __fstat32\n"
    ".globl __imp___fdclass\n"
    ".align 4\n"
    "__imp___fdclass:\n"
    "    .long __fdclass\n"
    ".globl __imp___dclass\n"
    ".align 4\n"
    "__imp___dclass:\n"
    "    .long __dclass\n"
    ".globl __imp___dsign\n"
    ".align 4\n"
    "__imp___dsign:\n"
    "    .long __dsign\n"
    ".globl __imp___fdsign\n"
    ".align 4\n"
    "__imp___fdsign:\n"
    "    .long __fdsign\n"
    ".globl __imp__strnlen\n"
    ".align 4\n"
    "__imp__strnlen:\n"
    "    .long _strnlen\n"
    ".globl __imp___isctype\n"
    ".align 4\n"
    "__imp___isctype:\n"
    "    .long __isctype\n"
    ".text\n"
);
