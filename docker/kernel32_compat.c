/* Win98-compatible stubs for Vista+/Win2000+ kernel32/ntdll APIs.
   Each provides the function + __imp__ pointer for __declspec(dllimport).
   Adapted for Docker/Arch build: no __acrt_iob_func, __stdio_common_*,
   _vsnprintf, or __lc_codepage (handled by ucrtcompat.o in libmsvcrt.a). */
#include <string.h>
#include <stddef.h>
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
long __stdcall InterlockedCompareExchange(long *, long, long);
BOOL __stdcall InitOnceExecuteOnce(void *init_once, BOOL_CALL_ONCE *init_fn, void *param, void **context)
{
    long *flag = (long *)init_once;
    if(InterlockedCompareExchange(flag, 1, 0) == 0) {
        if(init_fn) init_fn(param, context ? context : (void **)init_once);
    }
    return 1;
}

/* --- ConditionVariable family (Vista+) --- */
/* Implemented using Win98-compatible manual-reset events. */
typedef struct _CONDITION_VARIABLE { void *Ptr; } CONDITION_VARIABLE;
void __stdcall LeaveCriticalSection(CRITSEC *);
void __stdcall EnterCriticalSection(CRITSEC *);
void *__stdcall CreateEventA(void *, int, int, const char *);
int __stdcall SetEvent(void *);
int __stdcall ResetEvent(void *);
unsigned long __stdcall WaitForSingleObject(void *, unsigned long);
int __stdcall CloseHandle(void *);
void __stdcall InitializeConditionVariable(CONDITION_VARIABLE *cv) { if(cv) cv->Ptr = 0; }
static void *cv_ensure_event(CONDITION_VARIABLE *cv)
{
    void *ev = cv->Ptr;
    if(!ev) {
        ev = CreateEventA((void*)0, 1, 0, (const char*)0);
        if(InterlockedCompareExchange((long *)&cv->Ptr, (long)ev, 0) != 0)
            CloseHandle(ev);
    }
    return cv->Ptr;
}
void __stdcall WakeConditionVariable(CONDITION_VARIABLE *cv)
{
    if(cv && cv->Ptr) SetEvent(cv->Ptr);
}
void __stdcall WakeAllConditionVariable(CONDITION_VARIABLE *cv)
{
    if(cv && cv->Ptr) SetEvent(cv->Ptr);
}
unsigned long __stdcall SleepConditionVariableCS(CONDITION_VARIABLE *cv, CRITSEC *cs, unsigned long ms)
{
    void *ev = cv_ensure_event(cv);
    ResetEvent(ev);
    LeaveCriticalSection(cs);
    WaitForSingleObject(ev, ms ? ms : 0xFFFFFFFFUL);
    EnterCriticalSection(cs);
    return 1;
}

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

/* ── Win98 user32 W-version display function wrappers ────────────────
   EnumDisplayDevicesW, EnumDisplaySettingsW, EnumDisplaySettingsExW,
   GetMonitorInfoW, EnumDisplayMonitors require Windows 2000.
   MonitorFromWindow, MonitorFromPoint also Win2000+ per MSDN.
   Named wine_k32compat_* and redirected via -D preprocessor flags.
   No __imp__ pointers needed — Wine calls these as regular functions,
   not via __declspec(dllimport). Stripping from user32.spec and
   libuser32.a ensures the linker uses our local implementations. */

typedef struct {
    unsigned char dmDeviceName[32];
    unsigned short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
    unsigned long dmFields;
    unsigned long dmPosition_x, dmPosition_y;
    unsigned long dmDisplayOrientation, dmDisplayFixedOutput;
    unsigned short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    unsigned char dmFormName[32];
    unsigned short dmLogPixels;
    unsigned long dmBitsPerPel, dmPelsWidth, dmPelsHeight;
    unsigned long dmDisplayFlags, dmDisplayFrequency;
    unsigned long dmICMMethod, dmICMIntent, dmMediaType, dmDitherType;
    unsigned long dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
} DEVMODEA_LOCAL;

typedef struct {
    unsigned short dmDeviceName[32];
    unsigned short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
    unsigned long dmFields;
    unsigned long dmPosition_x, dmPosition_y;
    unsigned long dmDisplayOrientation, dmDisplayFixedOutput;
    unsigned short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    unsigned short dmFormName[32];
    unsigned short dmLogPixels;
    unsigned long dmBitsPerPel, dmPelsWidth, dmPelsHeight;
    unsigned long dmDisplayFlags, dmDisplayFrequency;
    unsigned long dmICMMethod, dmICMIntent, dmMediaType, dmDitherType;
    unsigned long dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
} DEVMODEW_LOCAL;

static void devmode_a_to_w(const DEVMODEA_LOCAL *a, DEVMODEW_LOCAL *w) {
    int i;
    memset(w, 0, sizeof(*w));
    for(i = 0; i < 31 && a->dmDeviceName[i]; i++) w->dmDeviceName[i] = (unsigned short)a->dmDeviceName[i];
    w->dmSpecVersion = a->dmSpecVersion; w->dmDriverVersion = a->dmDriverVersion;
    w->dmSize = sizeof(*w); w->dmDriverExtra = a->dmDriverExtra; w->dmFields = a->dmFields;
    w->dmPosition_x = a->dmPosition_x; w->dmPosition_y = a->dmPosition_y;
    w->dmDisplayOrientation = a->dmDisplayOrientation; w->dmDisplayFixedOutput = a->dmDisplayFixedOutput;
    w->dmColor = a->dmColor; w->dmDuplex = a->dmDuplex;
    w->dmYResolution = a->dmYResolution; w->dmTTOption = a->dmTTOption; w->dmCollate = a->dmCollate;
    for(i = 0; i < 31 && a->dmFormName[i]; i++) w->dmFormName[i] = (unsigned short)a->dmFormName[i];
    w->dmLogPixels = a->dmLogPixels;
    w->dmBitsPerPel = a->dmBitsPerPel; w->dmPelsWidth = a->dmPelsWidth; w->dmPelsHeight = a->dmPelsHeight;
    w->dmDisplayFlags = a->dmDisplayFlags; w->dmDisplayFrequency = a->dmDisplayFrequency;
    w->dmICMMethod = a->dmICMMethod; w->dmICMIntent = a->dmICMIntent;
    w->dmMediaType = a->dmMediaType; w->dmDitherType = a->dmDitherType;
    w->dmReserved1 = a->dmReserved1; w->dmReserved2 = a->dmReserved2;
    w->dmPanningWidth = a->dmPanningWidth; w->dmPanningHeight = a->dmPanningHeight;
}

int __stdcall EnumDisplaySettingsA(const char *, unsigned long, void *);
int __stdcall wine_k32compat_EDS_W(const unsigned short *dev, unsigned long mode, void *dm_out)
{
    DEVMODEA_LOCAL dma; int i; char devA[64] = {0};
    if(dev) { for(i=0; i<63 && dev[i]; i++) devA[i]=(char)dev[i]; }
    memset(&dma, 0, sizeof(dma)); dma.dmSize = sizeof(dma);
    if(!EnumDisplaySettingsA(dev?devA:NULL, mode, &dma)) return 0;
    devmode_a_to_w(&dma, (DEVMODEW_LOCAL*)dm_out); return 1;
}

int __stdcall EnumDisplaySettingsExA(const char *, unsigned long, void *, unsigned long);
int __stdcall wine_k32compat_EDSE_W(const unsigned short *dev, unsigned long mode, void *dm_out, unsigned long flags)
{
    DEVMODEA_LOCAL dma; int i; char devA[64] = {0};
    if(dev) { for(i=0; i<63 && dev[i]; i++) devA[i]=(char)dev[i]; }
    memset(&dma, 0, sizeof(dma)); dma.dmSize = sizeof(dma);
    if(!EnumDisplaySettingsExA(dev?devA:NULL, mode, &dma, flags)) return 0;
    devmode_a_to_w(&dma, (DEVMODEW_LOCAL*)dm_out); return 1;
}

int __stdcall EnumDisplayDevicesA(const char *, unsigned long, void *, unsigned long);
int __stdcall wine_k32compat_EDD_W(const unsigned short *dev, unsigned long idx, void *dd_out, unsigned long flags)
{
    struct { unsigned long cb; unsigned char dn[32]; unsigned char ds[128]; unsigned long sf;
             unsigned char did[128]; unsigned char dk[128]; } dda;
    int i; char devA[64] = {0};
    unsigned long sf;
    if(dev) { for(i=0; i<63 && dev[i]; i++) devA[i]=(char)dev[i]; }
    memset(&dda, 0, sizeof(dda)); dda.cb = sizeof(dda);
    if(!EnumDisplayDevicesA(dev?devA:NULL, idx, &dda, flags)) return 0;
    sf = dda.sf;
    memset(dd_out, 0, 840); *(unsigned long*)dd_out = 840;
    for(i=0; i<31 && dda.dn[i]; i++) ((unsigned short*)((char*)dd_out+4))[i] = dda.dn[i];
    for(i=0; i<127 && dda.ds[i]; i++) ((unsigned short*)((char*)dd_out+68))[i] = dda.ds[i];
    *(unsigned long*)((char*)dd_out+324) = sf;
    for(i=0; i<127 && dda.did[i]; i++) ((unsigned short*)((char*)dd_out+328))[i] = dda.did[i];
    for(i=0; i<127 && dda.dk[i]; i++) ((unsigned short*)((char*)dd_out+584))[i] = dda.dk[i];
    return 1;
}

unsigned long __stdcall GetSystemMetrics(int);
int __stdcall wine_k32compat_GMI_W(void *hmon, void *lpmi)
{
    unsigned long *mi = (unsigned long*)lpmi;
    if(!mi) return 0;
    memset(mi, 0, 40);
    mi[0] = 40; mi[3] = GetSystemMetrics(0); mi[4] = GetSystemMetrics(1);
    mi[7] = mi[3]; mi[8] = mi[4]; mi[9] = 1;
    return 1;
}

typedef int (__stdcall *MONITORENUMPROC)(void*, void*, unsigned long*, unsigned long);
int __stdcall wine_k32compat_EDM(void *hdc, const unsigned long *lprc, MONITORENUMPROC cb, unsigned long data)
{
    unsigned long rect[4];
    if(!cb) return 0;
    rect[0] = 0; rect[1] = 0; rect[2] = GetSystemMetrics(0); rect[3] = GetSystemMetrics(1);
    cb((void*)1, (void*)0, rect, data); return 1;
}

void * __stdcall wine_k32compat_MFW(void *hwnd, unsigned long flags) { return (void*)1; }
void * __stdcall wine_k32compat_MFP(unsigned long x, unsigned long y, unsigned long flags) { return (void*)1; }

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
