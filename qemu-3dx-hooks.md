# qemu-3dfx Wine Hooks

Complete reference of all custom code injected into the Wine D3D DLL builds
for qemu-3dfx MESA OpenGL passthrough support.

---

## wined3d.dll Custom Exports (9 functions)

All exported from `qemu3dfx_hooks.c`, injected into `dlls/wined3d/` by `build-ci.sh`.

### 1. `wined3d_hal_3dfx()` — DirectDraw HAL enumeration for 3dfx

Returns TRUE if a 3dfx HAL device is found via the qemu-3dfx passthrough.
On first call, probes `\\.\QEMUchs` device. If found, sets all four globals,
loads WGL 3DFX extensions, and returns TRUE. Subsequent calls return cached result.

```c
static BOOL qemu3dfx_detected;
static BOOL hal_enum_done;
static BOOL ddheap_active;
static BOOL passthru_enabled;

BOOL WINAPI wined3d_hal_3dfx(void)
{
    static BOOL checked = FALSE;
    static BOOL result = FALSE;
    if (checked) return result;
    ensure_detected();               // opens \\.\QEMUchs
    if (!qemu3dfx_detected) {
        checked = TRUE;
        return FALSE;
    }
    result = TRUE;
    checked = TRUE;
    hal_enum_done = TRUE;
    ddheap_active = TRUE;
    passthru_enabled = TRUE;
    load_wgl_3dfx_extensions();      // load WGL extensions from wrapper
    return result;
}
```

### 2. `wined3d_enum_hal_last()` — HAL enumeration complete flag

```c
BOOL WINAPI wined3d_enum_hal_last(void)
{
    return hal_enum_done;
}
```

### 3. `wined3d_surface_ddheap()` — DirectDraw surface heap active

```c
BOOL WINAPI wined3d_surface_ddheap(void)
{
    return ddheap_active;
}
```

### 4. `wined3d_passthru(BOOL *enabled)` — set/get passthrough mode

```c
BOOL WINAPI wined3d_passthru(BOOL *enabled)
{
    if (enabled && *enabled)
        passthru_enabled = TRUE;
    return passthru_enabled;
}
```

### 5. `wined3d_override_cooplevel(DWORD *cooplevel)` — coop level override

XORs `DDSCL_EXCLUSIVE` (0x10) into the cooperative level flags based on
an internal counter/trigger. Used to adjust DirectDraw cooperative level
for passthrough mode.

```c
static DWORD override_counter = (DWORD)-1;
static DWORD override_trigger = (DWORD)-1;

void WINAPI wined3d_override_cooplevel(DWORD *cooplevel)
{
    if (override_counter == (DWORD)-1) return;
    DWORD flags = 0;
    if (override_trigger != (DWORD)-1)
        flags = 0x10;
    if (--override_counter == 0)
        flags = 0x10;
    *cooplevel ^= flags;
}
```

### 6. `wined3d_override_rendertarget_view(void *view_ptr)` — RTV passthrough flag

Sets bit 0x20 in `resource->access_flags` (offset 0x34 in
`struct wined3d_resource` on Wine 4.x–8.x, 32-bit). This marks the
render target for passthrough rendering instead of native OpenGL.

```c
void WINAPI wined3d_override_rendertarget_view(void *view_ptr)
{
    void **view = (void **)view_ptr;
    DWORD *flags;
    if (!view) return;
    if (!view[1]) return;
    flags = (DWORD *)((char *)view[1] + 0x34);
    if (!(*flags & 0x20))
        *flags |= 0x20;
}
```

Struct layout (Wine 8.0.2, 32-bit):
```
struct wined3d_rendertarget_view     struct wined3d_resource
  +0x00  LONG refcount                +0x00  LONG ref
  +0x04  resource *  <- offset 0x4    +0x04  LONG bind_count
                                      ...
                                      +0x34  DWORD access_flags  <- offset 0x34
```

### 7–9. WGL 3DFX Extension Wrappers

Three exported wrappers that forward to WGL 3DFX extensions loaded from
the qemu-3dfx wrapper opengl32.dll. Extensions are loaded automatically
when `wined3d_hal_3dfx()` detects the passthrough.

```c
// Gamma ramp getter — wraps wglGetDeviceGammaRamp3DFX
BOOL WINAPI wined3d_get_gamma_ramp_3dfx(void *hDC, void *ramp);

// Gamma ramp setter — wraps wglSetDeviceGammaRamp3DFX
BOOL WINAPI wined3d_set_gamma_ramp_3dfx(void *hDC, void *ramp);

// Cursor control — wraps wglSetDeviceCursor3DFX
BOOL WINAPI wined3d_set_cursor_3dfx(void *hDC, void *cursor);
```

Extension loading:
```c
static void load_wgl_3dfx_extensions(void)
{
    HMODULE hGL = GetModuleHandleA("opengl32.dll");
    if (!hGL) return;
    wglGetProcAddress_t pGetProc = GetProcAddress(hGL, "wglGetProcAddress");
    if (!pGetProc) return;
    p_wglGetDeviceGammaRamp3DFX = pGetProc("wglGetDeviceGammaRamp3DFX");
    p_wglSetDeviceGammaRamp3DFX = pGetProc("wglSetDeviceGammaRamp3DFX");
    p_wglSetDeviceCursor3DFX     = pGetProc("wglSetDeviceCursor3DFX");
}
```

### Internal: QEMU Device Detection

```c
static BOOL detect_qemu_passthrough(void)
{
    SECURITY_ATTRIBUTES sa;
    HANDLE h;
    sa.nLength = sizeof(sa);
    sa.lpSecurityDescriptor = NULL;
    sa.bInheritHandle = TRUE;
    h = CreateFileA("\\\\.\\QEMUchs",
                     GENERIC_READ | GENERIC_WRITE,
                     0, &sa, OPEN_EXISTING, 0, NULL);
    if (h == INVALID_HANDLE_VALUE)
        return FALSE;
    CloseHandle(h);
    return TRUE;
}
```

---

## Strings Embedded in wined3d.dll

### Registry Config Keys

Queried by Wine D3D initialization to control HAL behavior.

```c
const char qemu3dfx_hal_key[]          = "D3D1Hal3Dfx";
const char qemu3dfx_enum_hal_last_key[] = "D3D1EnumHalLast";
```

### WGL Extension Strings

Used for dynamic extension lookup from the wrapper opengl32.dll.

```c
static const char wgl_3dfx_gamma_control[] = "WGL_3DFX_gamma_control";
```

String references loaded at runtime:
- `wglGetDeviceGammaRamp3DFX` — custom gamma ramp getter
- `wglSetDeviceGammaRamp3DFX` — custom gamma ramp setter
- `wglSetDeviceCursor3DFX` — custom cursor control

### Debug Channel

A `QEMU` debug channel matching the original DLL (offset 0x04eec9).
Uses Wine's `__wine_debug_channel` infrastructure with trace logging
at key points: QEMUchs detection, HAL enumeration, RTV override, and
WGL extension loading.

```c
struct __wine_debug_channel { unsigned char flags; unsigned char name[15]; };
enum __wine_debug_class { __WINE_DBCL_FIXME, __WINE_DBCL_ERR,
                          __WINE_DBCL_WARN, __WINE_DBCL_TRACE };

static struct __wine_debug_channel __qemu3dfx_dbch = { 0, {'Q','U','E','M','U'} };
#define QEMU_DBG(cls, ...) wine_dbg_log(cls, &__qemu3dfx_dbch, __FUNCTION__, __VA_ARGS__)
```

The `wine_dbg_log` stub (in `create_stub_libwine`) returns 0, so these
calls are zero-cost until a real libwine with active debug channels is used.

---

## ddraw.dll Custom Exports (20 functions)

All exported from `qemu3dfx_ddraw_hooks.c`, injected into `dlls/ddraw/`.
These are no-op stubs — the passthrough wrapper handles actual video memory
management. Function signatures verified against NT 4.0 and XP SP1 DDK
source code (`dmemmgr.h`, `ddrawi.h`, `ddrawpr.h`).

Note: Wine's ddraw.spec defines many of these as `@ stub` entries, but
winebuild does not export `@ stub` entries in the PE export table. The
build patches them to `@ stdcall` so they appear as real exports. Standard
Windows ddraw.dll exports (AcquireDDThreadLock, D3DParseUnknownCommand,
etc.) that are not in Wine's spec at all are appended during the build.

### Video Memory Management (from dmemmgr.h)

```c
// DDK: FLATPTR WINAPI VidMemAlloc(LPVMEMHEAP, DWORD width, DWORD height)
DWORD WINAPI VidMemAlloc(DWORD fpStart, DWORD dwSize, void *lpHeap)
{
    return 0;
}

// DDK: void WINAPI VidMemFree(LPVMEMHEAP, FLATPTR)
void WINAPI VidMemFree(void *lpHeap, DWORD fpMem) {}

// DDK: LPVMEMHEAP WINAPI VidMemInit(DWORD flags, FLATPTR start, FLATPTR end, DWORD height, DWORD pitch)
void *WINAPI VidMemInit(DWORD dwFlags, DWORD fpStart, DWORD fpEnd, DWORD dwHeight, DWORD dwPitch)
{
    return NULL;
}

// DDK: void WINAPI VidMemFini(LPVMEMHEAP)
void WINAPI VidMemFini(void *lpHeap) {}

// DDK: DWORD WINAPI VidMemAmountFree(LPVMEMHEAP)
DWORD WINAPI VidMemAmountFree(void *lpHeap) { return 0; }

// DDK: DWORD WINAPI VidMemLargestFree(LPVMEMHEAP)
DWORD WINAPI VidMemLargestFree(void *lpHeap) { return 0; }
```

### DDHAL32 Wrappers (from ddrawi.h)

```c
// DDK: FLATPTR DDAPI DDHAL_VidMemAlloc(LPDDRAWI_DIRECTDRAW_GBL, int heap, DWORD width, DWORD height)
DWORD WINAPI DDHAL32_VidMemAlloc(void *lpDD, int heap, DWORD dwWidth, DWORD dwHeight)
{
    return 0;
}

// DDK: void DDAPI DDHAL_VidMemFree(LPDDRAWI_DIRECTDRAW_GBL, int heap, FLATPTR)
void WINAPI DDHAL32_VidMemFree(void *lpDD, int heap, DWORD fpMem) {}
```

### Heap Aligned Allocation (from NT5 dmemmgr.h)

```c
// DDK: FLATPTR WINAPI HeapVidMemAllocAligned(LPVIDMEM, DWORD width, DWORD height,
//                                            LPSURFACEALIGNMENT, LPLONG lpPitch)
DWORD WINAPI HeapVidMemAllocAligned(void *lpVidMem, DWORD dwWidth, DWORD dwHeight,
                                     void *lpAlignment, long *lpPitch)
{
    return 0;
}
```

### Surface Functions (from ddrawpr.h / ddrawi.h)

```c
// DDK: HRESULT InternalLock(LPDDRAWI_DDRAWSURFACE_LCL, LPVOID*, LPRECT, DWORD)
long WINAPI InternalLock(void *lpDDSurface, void **ppBits, void *lpRect, DWORD dwFlags)
{
    return 0;
}

// DDK: HRESULT InternalUnlock(LPDDRAWI_DDRAWSURFACE_LCL, LPVOID, DWORD)
long WINAPI InternalUnlock(void *lpDDSurface, void *lpSurfaceData, DWORD dwFlags) {}

// DDK: LPDIRECTDRAWSURFACE GetNextMipMap(LPDIRECTDRAWSURFACE)
void *WINAPI GetNextMipMap(void *lpDDSurface) { return NULL; }

// DDK: HRESULT DDAPI LateAllocateSurfaceMem(LPDIRECTDRAWSURFACE, DWORD, DWORD, DWORD)
long WINAPI LateAllocateSurfaceMem(void *lpSurface, DWORD dwAllocType,
                                    DWORD dwWidth, DWORD dwHeight) {}
```

### DirectSound Helper (from NT5 dddefwp.c)

```c
// DDK: HRESULT __stdcall DSoundHelp(HWND, WNDPROC, DWORD pid)
long WINAPI DSoundHelp(void *hWnd, void *lpWndProc, DWORD pid)
{
    return 0;
}
```

### Standard Windows ddraw.dll Exports

These 6 exports are present in the reference ddraw.dll and expected by
applications like 3DMark2000. Wine's spec file defines DDInternalLock/
DDInternalUnlock as `@ stub` (not exported by winebuild) and doesn't
include the other four at all. All are patched to `@ stdcall` or appended
to the spec during the build.

```c
// Internal surface lock (DD-prefixed name expected by Windows).
// Wine's spec also has InternalLock (without DD prefix).
long WINAPI DDInternalLock(void *surface, void **bits, void *rect, DWORD flags)
{
    return 0;
}

// Internal surface unlock (DD-prefixed name).
long WINAPI DDInternalUnlock(void *surface, void *data, DWORD flags)
{
    return 0;
}

// Thread safety — no-op (Wine handles locking internally)
void WINAPI AcquireDDThreadLock(void) { }
void WINAPI ReleaseDDThreadLock(void) { }

// System memory surface creation — no-op
long WINAPI CompleteCreateSysmemSurface(void *surface) { return 0; }

// D3D command parser — returns D3DERR_COMMAND_UNPARSED
long WINAPI D3DParseUnknownCommand(void *cmd, void **ret)
{
    if (ret) *ret = cmd;
    return 0x8876086A; /* D3DERR_COMMAND_UNPARSED */
}
```

---

## d3d9.dll Custom Exports (3 functions)

The original qemu-3dfx d3d9.dll also has three trace stubs at the start
of the text section. These are already `@ stub` in Wine's d3d9.spec and
are not currently overridden by our build.

```
PSGPError           — at RVA 0x1000, trace stub
PSGPSampleTexture   — at RVA 0x1020, trace stub
DebugSetLevel       — at RVA 0x1040, trace stub
```

Each follows the same pattern as the ddraw VidMem trampolines:
pushes a format string and context pointer, calls a common logging helper.

---

## ddraw → wined3d Passthrough Bridge

Injected into `dlls/ddraw/` by `create_ddraw_passthrough()` in `build-ci.sh`.
Source file: `qemu3dfx_ddraw_passthrough.c`. Bridges ddraw.dll to wined3d
passthrough functions at key points in the DirectDraw lifecycle.

### Bridge Functions

```c
extern BOOL WINAPI wined3d_hal_3dfx(void);
extern BOOL WINAPI wined3d_enum_hal_last(void);
extern void *WINAPI wined3d_surface_ddheap(void);
extern BOOL WINAPI wined3d_passthru(BOOL *enabled);
extern void WINAPI wined3d_override_cooplevel(DWORD *cooplevel);
extern void WINAPI wined3d_override_rendertarget_view(void *view_ptr);
extern BOOL WINAPI wined3d_blit_fpslimit(void);
extern BOOL WINAPI wined3d_flip_fpslimit(void);
```

### Init (called from DllMain via sed patch to `main.c`)

```c
static BOOL g_passthru_active;

void qemu3dfx_ddraw_passthrough_init(void)
{
    if (wined3d_hal_3dfx())      // detect qemu-3dfx
    {
        BOOL enable = TRUE;
        wined3d_passthru(&enable);  // enable passthrough
        g_passthru_active = TRUE;
        wined3d_enum_hal_last();    // mark HAL enumeration complete
        wined3d_surface_ddheap();   // activate DD surface heap
    }
}
```

### Hook Injection Points (sed patches)

| Hook | File | Sed Pattern | Wine Versions |
|------|------|-------------|---------------|
| Init | `main.c` | After `DisableThreadLibraryCalls(inst);` | All |
| Cooplevel | `ddraw.c` | After `DDRAW_dump_cooperativelevel(cooplevel);` | All |
| Blit FPS | `surface.c` | Before `return wined3d_texture_blt(dst_surface` | ≤ 6 |
| Blit FPS | `surface.c` | Before `return wined3d_device_context_blt(ddraw` | ≥ 7 |
| Flip FPS | `surface.c` | `DDSCAPS2\? caps = {DDSCAPS_FLIP` | All |
| RTV override | `surface.c` | After `tmp_rtv = ddraw_surface_get_rendertarget_view(dst_impl);` | All |

The Flip sed pattern uses `DDSCAPS2\?` to match both `DDSCAPS2 caps` (Wine ≤ 5)
and `DDSCAPS caps` (Wine ≥ 6). The blit limiter has two patterns: one for
`wined3d_texture_blt` (Wine ≤ 6) and one for `wined3d_device_context_blt` (Wine 7+).

Diagnostic output verifies each patch applied (grep after sed).

---

## Win98 Compatibility Stubs

Injected into ALL four DLLs (wined3d, d3d9, d3d8, ddraw) via
`create_kernel32_compat()` in `build-ci.sh`. Each DLL gets its own copy
so `__declspec(dllimport)` callers resolve via local `__imp__` pointers
instead of importing from kernel32/ntdll/msvcrt which lack these on Win98.

### Vista+ Kernel32 Stubs

#### `wine_k32compat_GMHEW()` — GetModuleHandleExW source-level redirect

Wine 6–8 source code (`ddraw/main.c`, `wined3d/cs.c`) calls
`GetModuleHandleExW` directly. `__declspec(dllimport)` from `<winbase.h>`
forces the linker to create a kernel32.dll import table entry even when
we provide a local stub with `__imp__` pointer.

Fix: the build injects `#define GetModuleHandleExW wine_k32compat_GMHEW`
at the top of Wine source files that call it. This eliminates all
references to the `GetModuleHandleExW` symbol name, so no import table
entry is created. The `__imp__wine_k32compat_GMHEW@12` asm pointer
replaces the old `__imp__GetModuleHandleExW@12`.

```c
BOOL __stdcall wine_k32compat_GMHEW(DWORD flags, LPCWSTR name, HMODULE *module)
{
    if (!module) return 0;
    if (flags & GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS) {
        MBINFO mbi;
        if (VirtualQuery((const void *)name, &mbi, sizeof(mbi)))
            { *module = (HMODULE)mbi.AllocationBase; return 1; }
        return 0;
    }
    if (!name) { *module = (HMODULE)0x400000; return 1; }
    // Wide → narrow ASCII conversion, then GetModuleHandleA
    { char buf[260]; int i; for(i=0; i<259 && name[i]; i++) buf[i]=(char)name[i]; buf[i]=0;
      *module = GetModuleHandleA(buf); }
    return *module != 0;
}
```

Used by: `wined3d/cs.c` (Wine 6–8), `ddraw/main.c` (Wine 6–8).

#### `GlobalMemoryStatusEx()` — Win2000+ → Win95+ fallback

Falls back to `GlobalMemoryStatus` (Win95+), zero-extending 32-bit fields
to `DWORD64`. Extended virtual fields set to 0.

```c
BOOL __stdcall GlobalMemoryStatusEx(MEMSTATUSEX *lpBuffer)
{
    MEMSTATUS ms; ms.dwLength = sizeof(ms);
    GlobalMemoryStatus(&ms);
    lpBuffer->dwLength = sizeof(*lpBuffer);
    lpBuffer->dwMemoryLoad = ms.dwMemoryLoad;
    lpBuffer->ullTotalPhys = ms.dwTotalPhys;
    // ... zero-extend all fields ...
    lpBuffer->ullAvailExtendedVirtual = 0;
    return 1;
}
```

Used by: `wined3d/directx.c` (Wine 4–8).

#### `RtlIsCriticalSectionLockedByThread()` — Vista+ ntdll → local

Checks if the critical section's `OwningThread` matches `GetCurrentThreadId()`
and `RecursionCount > 0`. Provides thread-safe critical section query without
needing Vista+ ntdll.dll.

```c
BOOL __stdcall RtlIsCriticalSectionLockedByThread(CRITSEC *cs)
{
    return cs && cs->OwningThread == (void *)(ULONG_PTR)GetCurrentThreadId()
           && cs->RecursionCount > 0;
}
```

Used by: `wined3d/cs.c` (Wine 3, 6, 7, 8).

#### `InitOnceExecuteOnce()` — Vista+ → immediate init

One-time initialization primitive. Calls the init function immediately
(since we don't have Vista's INIT_ONCE infrastructure). Returns TRUE
on success.

```c
BOOL __stdcall InitOnceExecuteOnce(void *init_once, BOOL_CALL_ONCE *init_fn,
                                   void *param, void **context)
{
    if (init_fn) return init_fn(param, context ? context : (void **)init_once);
    return 1;
}
```

Used by: MinGW C++ runtime (static initialization guards via `__cxa_guard_*`).

### Vista+ Condition Variable Stubs

No-op stubs for Vista+ synchronization APIs. Used by Wine's thread pool
and mutex implementations. `InitializeConditionVariable` zeros the struct;
wake/sleep stubs do nothing (safe because Wine won't use them on Win98).

```c
void __stdcall InitializeConditionVariable(void *cv) { memset(cv, 0, sizeof(void *)); }
void __stdcall WakeConditionVariable(void *cv) { }
void __stdcall WakeAllConditionVariable(void *cv) { }
BOOL __stdcall SleepConditionVariableCS(void *cv, void *cs, DWORD ms) { Sleep(ms); return 1; }
```

### `SetThreadDescription()` — Win10+ → no-op

```c
HRESULT __stdcall SetThreadDescription(void *h, const WCHAR *s) { return 0; }
```

### `_initterm` / `_initterm_e` — CRT startup (not in Win98 msvcrt.dll)

Called by MinGW DLL startup to walk C++ initializer arrays. Win98's
msvcrt.dll lacks `_initterm_e` (added in VS2005+). Without these stubs,
Wine 4–5 builds fail with "missing export MSVCRT.DLL:_initterm_e".

```c
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
```

### `__imp__` Pointer Table

Each stub is accompanied by an inline asm `.rdata` pointer so
`__declspec(dllimport)` callers find the function through the IAT:

```asm
.section .rdata,"dr"
__imp___initterm:                    .long __initterm
__imp___initterm_e:                  .long __initterm_e
__imp__wine_k32compat_GMHEW@12:     .long _wine_k32compat_GMHEW@12
__imp__GlobalMemoryStatusEx@4:       .long _GlobalMemoryStatusEx@4
__imp__RtlIsCriticalSectionLockedByThread@4:
                                     .long _RtlIsCriticalSectionLockedByThread@4
__imp__InitOnceExecuteOnce@16:       .long _InitOnceExecuteOnce@16
__imp__InitializeConditionVariable@4: .long _InitializeConditionVariable@4
__imp__WakeConditionVariable@4:      .long _WakeConditionVariable@4
__imp__WakeAllConditionVariable@4:   .long _WakeAllConditionVariable@4
__imp__SleepConditionVariableCS@12:  .long _SleepConditionVariableCS@12
__imp__SetThreadDescription@8:       .long _SetThreadDescription@8
```

---

## D3DKMT Stubs (9 functions) — wined3d only

Injected into `dlls/wined3d/` via `create_d3dkmt_stubs()`. These are
Vista+ gdi32 APIs that wined3d statically imports. Stubs return
`STATUS_UNSUCCESSFUL` so wined3d falls back to non-D3DKMT code paths.

```c
NTSTATUS __stdcall D3DKMTCloseAdapter(const void *a);
NTSTATUS __stdcall D3DKMTCreateDCFromMemory(void *a);
NTSTATUS __stdcall D3DKMTCreateDevice(void *a);
NTSTATUS __stdcall D3DKMTDestroyDCFromMemory(void *a);
NTSTATUS __stdcall D3DKMTDestroyDevice(void *a);
NTSTATUS __stdcall D3DKMTOpenAdapterFromGdiDisplayName(void *a);
NTSTATUS __stdcall D3DKMTOpenAdapterFromLuid(void *a);
NTSTATUS __stdcall D3DKMTQueryVideoMemoryInfo(void *a);
NTSTATUS __stdcall D3DKMTSetVidPnSourceOwner(const void *a);
```

---

## Stub libwine.a — No Runtime Dependency

Built by `create_stub_libwine()` for Wine 1.x–7.x (legacy mode).
Provides minimal implementations so DLLs don't need `libwine.dll` at runtime.

### Debug Functions (all return 0/empty)

```c
unsigned char __wine_dbg_get_channel_flags(channel) → 0
int __wine_dbg_header(class, channel, func)          → -1
int wine_dbg_log(class, channel, func, fmt, ...)     → 0
int wine_dbg_vlog(class, channel, func, fmt, va)     → 0
int wine_dbg_printf(fmt, ...)                        → 0
const char *wine_dbg_sprintf(fmt, ...)               → ""
int wine_dbg_vsprintf(buf, sz, fmt, va)              → 0
int wine_dbg_vprintf(fmt, va)                        → 0
const char *wine_dbgstr_an(s, n)                     → ""
const char *wine_dbgstr_wn(s, n)                     → ""
```

### Wine Runtime Functions

```c
const char *wine_get_version(void)       → "wine-stubs"
const char *wine_get_config_dir(void)    → ""
const char *wine_get_data_dir(void)      → ""
unsigned short wine_tolower(c)            → ASCII tolower
unsigned short wine_toupper(c)            → ASCII toupper
```

The archive is named `wine-stubs.a` (not `libwine.a`) to bypass winegcc's
auto-conversion of `lib*.a` paths back to `-l` form.

---

## UCRT Compatibility Stubs

Built by `create_ucrtcompat()` for all versions. Redirects UCRT printf
family functions to msvcrt equivalents so Wine code targeting UCRT APIs
links against msvcrt.dll instead of ucrtbase.dll.

### Printf Redirects (injected into `libmsvcrt.a`)

```c
__acrt_iob_func(i)                → __iob_func() + i*32
__stdio_common_vsprintf(...)      → _vsnprintf(...)
__stdio_common_vsprintf_s(...)    → _vsnprintf(...)
__stdio_common_vsprintf_p(...)    → _vsnprintf(...)
__stdio_common_vsnprintf_s(...)   → _vsnprintf(min(c,n), ...)
__stdio_common_vfprintf(...)      → 0 (no-op)
__stdio_common_vfprintf_s(...)    → 0 (no-op)
__stdio_common_vfscanf(...)       → -1 (no-op)
__stdio_common_vsscanf(...)       → -1 (no-op)
__stdio_common_vswprintf(...)     → _vsnwprintf(...)
__stdio_common_vswprintf_s(...)   → _vsnwprintf(...)
__stdio_common_vswprintf_p(...)   → _vsnwprintf(...)
__stdio_common_vsnwprintf_s(...)  → _vsnwprintf(min(c,n), ...)
__stdio_common_vfwprintf(...)     → 0 (no-op)
__stdio_common_vfwprintf_s(...)   → 0 (no-op)
```

### floorf (injected into `libgcc.a`)

Wine 8.x links via `-static-libgcc` which includes `libgcc.a`. If `floorf`
is missing, it causes unresolved symbols. Injected as a separate object to
avoid multiple-definition conflicts with `__acrt_iob_func`.

```c
float __cdecl floorf(float x) { return (float)floor((double)x); }
```

---

## Vista+ Import Stripping

Multi-layer removal of Vista+ APIs so the DLLs never generate import thunks
for functions missing on Win98:

### Layer 1: Spec File Removal

Strips Vista+ API lines from `kernel32.spec` and `ntdll.spec` so winebuild
never generates PE import table entries for them:

| API | Family |
|-----|--------|
| `GetModuleHandleExW` | Module (Vista+) |
| `GlobalMemoryStatusEx` | Memory (Win2000+) |
| `InitOnceBeginInitialize` | Sync (Vista+) |
| `InitOnceComplete` | Sync (Vista+) |
| `InitOnceExecuteOnce` | Sync (Vista+) |
| `InitOnceInitialize` | Sync (Vista+) |
| `InitializeSRWLock` | Sync (Vista+) |
| `AcquireSRWLockExclusive` | Sync (Vista+) |
| `AcquireSRWLockShared` | Sync (Vista+) |
| `ReleaseSRWLockExclusive` | Sync (Vista+) |
| `ReleaseSRWLockShared` | Sync (Vista+) |
| `TryAcquireSRWLockExclusive` | Sync (Vista+) |
| `TryAcquireSRWLockShared` | Sync (Vista+) |
| `InitializeConditionVariable` | Sync (Vista+) |
| `WakeConditionVariable` | Sync (Vista+) |
| `WakeAllConditionVariable` | Sync (Vista+) |
| `SleepConditionVariableCS` | Sync (Vista+) |
| `SleepConditionVariableSRW` | Sync (Vista+) |
| `GetTickCount64` | Time (Vista+) |
| `RtlIsCriticalSectionLockedByThread` | ntdll (Vista+) |

### Layer 2: System Import Lib Stripping

`strip_kernel32_vista_imports()` uses `objcopy --strip-symbol` on MinGW
system archives to remove both `_func@N` code symbols and `__imp__func@N`
data symbols. Also strips `_initterm`/`_initterm_e` from `libmsvcrt.a`.

Target archives:
- `/mingw32/lib/libkernel32.a` — Vista+ kernel32 APIs
- `/mingw32/i686-w64-mingw32/lib/libkernel32.a` — same
- `/mingw32/lib/libmsvcrt.a` — `_initterm`, `_initterm_e`
- `/mingw32/i686-w64-mingw32/lib/libmsvcrt.a` — same

### Layer 3: Wine-Built Import Lib Stripping

`strip_kernel32_vista_imports_wine()` strips from Wine's own import libs
(built by `make tools`). Applied after tools build in both modern and
legacy paths. Targets:

- `dlls/kernel32/libkernel32.a` — Vista+ kernel32 APIs
- `dlls/ntdll/libntdll.a` — Vista+ ntdll + basic CRT (memcpy, strlen, etc.)
- `dlls/msvcrt/libmsvcrt.a` — `_initterm`, `_initterm_e`, `__stdio_common_*`
- `dlls/ucrtbase/libucrtbase.a` — Vista+ APIs + CRT stubs

### Layer 4: Legacy-Specific Import Lib Stripping

For Wine 1.x–7.x (legacy builds), additional stripping from Wine-generated
import libs that happens post-configure:

- `dlls/kernel32/libkernel32.a` — Vista+ APIs (GetModuleHandleExW, etc.)
- `dlls/ntdll/libntdll.a` — CRT functions (sprintf, memcpy, strlen, etc.)
- `dlls/msvcrt/libmsvcrt.a` — UCRT functions (`__stdio_common_*`),
  `_initterm`, `_initterm_e`

### Layer 5: Linker Export Exclusion

`--exclude-symbols` linker flag prevents our local stub implementations
from being exported in the DLL export table (which would cause
"symbol wrong type (4 vs 3)" errors when winebuild processes them).

Applied in three locations:
1. Modern build `LDFLAGS` and `CROSSLDFLAGS`
2. Legacy build `winegcc-filter` wrapper

Excluded symbol families:
- Vista+ API stubs (GetModuleHandleExW, GlobalMemoryStatusEx, etc.)
- CRT stubs (_initterm, _initterm_e)
- Static CRT from libgcc (memcmp, memcpy, memset, strlen, strcpy, etc.)
- UCRT redirects (__stdio_common_*, __acrt_iob_func)
- FP classification stubs (_fdclass, _dclass, _dsign, _fdsign)

---

## Build Patches Applied (Legacy Mode)

The legacy build path (Wine 1.x–7.x) applies these patches:

### Source Patches

| Patch | File | Purpose |
|-------|------|---------|
| Import lib path | `aclocal.m4` | Fix broken symlink: `$ac_name/` → `dlls/$ac_name/` |
| bool keyword | `d3d8/d3d8_main.c` | Rename `bool` → `bool_val` (C keyword conflict) |
| Console output | `winecrt0/debug.c` | `fwrite(stderr)` → `WriteFile()` for native Windows |
| wcstok signature | `corecrt_wstring.h` | 3-arg → 2-arg for MinGW compat (Wine 6.x only) |
| Printf stubs | `msvcrt/wcs.c` | Backport `__stdio_common_*` (Wine 6.x only) |

### Makefile Sweep

- Strip `-fPIC` and `-fstack-protector` (not applicable to Windows PE)
- Replace `-lwine` with `../../libs/wine/wine-stubs.a`
- Strip `wine`/`libwine` from `IMPORTS` lines

### winegcc Wrapper (`winegcc-filter`)

A bash wrapper around `winegcc.exe` that:
1. Replaces `-lwine` with the stub archive path
2. Replaces `-lucrtbase` with `-lmsvcrt`
3. Appends `-mcrtdll=msvcrt` for GCC CRT selection
4. Appends `--exclude-symbols` for all Win98 compat stubs

---

## Architecture Overview

```
Guest Application
    |
    v
ddraw.dll ──── passthrough bridge (qemu3dfx_ddraw_passthrough.c)
    |           ├── DllMain → qemu3dfx_ddraw_passthrough_init()
    |           │     calls wined3d_hal_3dfx, wined3d_passthru,
    |           │     wined3d_enum_hal_last, wined3d_surface_ddheap
    |           ├── SetCooperativeLevel → qemu3dfx_ddraw_cooplevel()
    |           ├── ddraw_surface_blt → qemu3dfx_ddraw_blit()
    |           ├── ddraw_surface_Flip → qemu3dfx_ddraw_flip()
    |           └── RTV setup → qemu3dfx_ddraw_rtv()
    |
    |        ──── VidMem HAL stubs (qemu3dfx_ddraw_hooks.c)
    |           DDHAL32_VidMemAlloc, VidMemFree, VidMemInit, etc.
    |           DDInternalLock, DDInternalUnlock, AcquireDDThreadLock,
    |           ReleaseDDThreadLock, CompleteCreateSysmemSurface,
    |           D3DParseUnknownCommand
    |           (return 0/NULL — passthrough wrapper handles real alloc)
    |
    v
wined3d.dll ─── probes \\.\QEMUchs
    |             sets passthrough globals
    |             overrides RTV access_flags
    |             loads WGL 3DFX extensions
    |             FPS limiters (blit/flip)
    v
opengl32.dll (qemu-3dfx wrapper: WRAPGL32.DLL)
    |
    v
mesapt shared memory → Host GPU (3dfx OpenGL passthrough)
```

1. Guest app loads ddraw.dll
2. DllMain calls passthrough init → detects qemu-3dfx via wined3d_hal_3dfx
3. If detected: enables passthrough, marks HAL enum complete, activates DD heap
4. DirectDraw HAL enumeration finds 3dfx devices via wined3d_hal_3dfx
5. SetCooperativeLevel: passthrough bridge overrides coop level flags
6. Surface blit/flip: FPS limiters throttle frame rate
7. RTV override: marks render targets for passthrough rendering path
8. VidMem HAL stubs: export table entries satisfied, real alloc by wrapper
9. Registry keys `D3D1Hal3Dfx` / `D3D1EnumHalLast` configure HAL behavior
10. All GL calls go through opengl32.dll → WRAPGL32 → mesapt → host GPU

---

## Import Table Comparison (Original vs Our Builds)

### Wine 1.8.7–3.0.5: Missing `wined3d_enum_hal_last`

All three versions were missing the `wined3d_enum_hal_last` import compared
to the originals. This is the root cause of "3DMark doesn't run" — without
this call, HAL enumeration for qemu-3dfx passthrough doesn't complete.

Original imports (Wine 1.8.7 example):
```
wined3d_hal_3dfx          ✓    wined3d_blit_fpslimit    ✓
wined3d_enum_hal_last     ✓    wined3d_flip_fpslimit    ✓
wined3d_passthru          ✓    wined3d_override_cooplevel          ✓
wined3d_override_rendertarget_view   ✓
```

Our build was missing `wined3d_enum_hal_last` because the passthrough
bridge declared it as extern but never called it. Fixed by adding the
call in `qemu3dfx_ddraw_passthrough_init()`.

### Wine 4.12.1–5.0.5: Missing `_initterm_e`

Originals import `_initterm` from msvcrt.dll (Win98 has it). Our builds
also imported `_initterm` from msvcrt.dll. But MinGW CRT startup code
calls `_initterm_e` which Win98's msvcrt.dll lacks. Fixed by adding
local stubs + stripping from import libs.

### Wine 6.0.4–7.0.2: `GetModuleHandleExW` import leak

Originals don't import `GetModuleHandleExW` from kernel32 (it doesn't
exist on Win98). Our builds leaked this import because Wine 6-7's
`ddraw/main.c` and `wined3d/cs.c` call `GetModuleHandleExW` directly.
`__declspec(dllimport)` from `<winbase.h>` forced the linker to create
a kernel32.dll import entry even with local stubs and import lib stripping.

Fixed by source-level redirect: `#define GetModuleHandleExW wine_k32compat_GMHEW`
injected at the top of Wine source files that call it. This eliminates
all references to the `GetModuleHandleExW` symbol name.

### Wine 8.0.2: Crash (page fault in KERNEL32.DLL)

Under investigation. Likely a remaining Vista+ import or incompatible
CRT function leaking through the modern PE build system.

### Missing ddraw.dll Standard Exports (All Versions)

Our builds were missing 6 standard Windows ddraw.dll exports that the
reference DLL provides. Root cause: winebuild does not export `@ stub`
entries from the spec file — only `@ stdcall` entries get exported.

Missing exports and their fix:
- `DDInternalLock` / `DDInternalUnlock` — changed from `@ stub` to `@ stdcall` in spec
- `AcquireDDThreadLock` / `ReleaseDDThreadLock` — appended to spec (not in Wine's spec)
- `CompleteCreateSysmemSurface` — appended to spec
- `D3DParseUnknownCommand` — appended to spec

All are no-op stubs in `qemu3dfx_ddraw_hooks.c`. Without these, 3DMark2000
fails to start because it depends on standard ddraw.dll export ordinals.

### CRT Import Profile Differences (Wine 1–3)

Original DLLs import 35 CRT functions from msvcrt.dll. Our builds import
only 11 — the rest are resolved from static libgcc (`-static-libgcc`).
Functionally equivalent; basic CRT functions (memcpy, strlen, etc.) are
provided by libgcc's optimized implementations.

Kernel32 differences:
- Missing: `GetModuleFileNameA`, `IsDBCSLeadByteEx`, `WideCharToMultiByte`
  (resolved differently by MinGW's headers/libraries)
- Extra: `GetCurrentThreadId`, `GlobalMemoryStatus` (from static linking)

---

## Source References

Function signatures verified against:
- **NT 4.0 DDK** — `private/ntos/w32/ntgdi/direct/ddraw/dmemmgr.h`
  VidMemInit, VidMemFini, VidMemAmountFree, VidMemLargestFree,
  DDHAL32_VidMemAlloc/Free, InternalLock/Unlock
- **XP SP1 DDK** — `Source/XPSP1/NT/public/oak/inc/dmemmgr.h`
  HeapVidMemAllocAligned, VidMemAlloc, VidMemFree
- **XP SP1 DDK** — `Source/XPSP1/NT/public/oak/inc/ddrawi.h`
  GetNextMipMap, LateAllocateSurfaceMem
- **XP SP1 DDK** — `ddraw/dddefwp.c` (NT5 source)
  DSoundHelp(hWnd, lpWndProc, pid)
- **NT 4.0 DDK** — `private/ntos/w32/ntgdi/direct/ddraw/ddrawpr.h`
  InternalLock(thisx, pbits, lpRect, dwFlags)
  InternalUnlock(thisx, lpSurfaceData, dwFlags)
- **Wine 8.0.2** — `dlls/wined3d/wined3d_private.h`
  wined3d_resource.access_flags at offset 0x34
  wined3d_rendertarget_view.resource at offset 0x04
- **Original qemu-3dfx wined3d.dll** — string analysis
  QEMU debug channel, D3D1Hal3Dfx, D3D1EnumHalLast,
  WGL_3DFX_gamma_control, wglGet/SetDeviceGammaRamp3DFX,
  wglSetDeviceCursor3DFX
