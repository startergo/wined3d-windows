/*
 * user32 compatibility for Windows 95 (linked into wined3d).
 *
 * wined3d imports the multi-monitor API (Windows 98+) and GetCursorInfo,
 * which Windows 95's user32 lacks, so the DLL would not load there. As with
 * Microsoft's multimon.h stubs, each function uses the real one when user32
 * has it (Windows 98/ME) and otherwise emulates a single primary monitor.
 *
 * Windows 95's EnumDisplaySettingsA also rejects ENUM_CURRENT_SETTINGS (a
 * Windows 98 addition) - the wrapper asks the real function first and only
 * synthesises the current mode when that query fails.
 *
 * The __imp__ pointers at the end make wined3d bind to these wrappers instead
 * of importing the functions from user32.
 */
#ifdef __MINGW32__
#undef _WIN32_WINNT
#undef WINVER
#define _WIN32_WINNT 0x0500
#define WINVER 0x0500
#include <stddef.h>
#include <windows.h>

#define PRIMARY_MONITOR ((HMONITOR)0x12340042)  /* multimon.h's value */

static FARPROC user32_proc(const char *name)
{
    HMODULE user32 = GetModuleHandleA("user32.dll");
    return user32 ? GetProcAddress(user32, name) : NULL;
}

#define REAL(name, type) \
    static __typeof__(type) real; static int looked_up; \
    if (!looked_up) { real = (__typeof__(type))user32_proc(name); looked_up = 1; }

static void primary_rect(RECT *rect)
{
    SetRect(rect, 0, 0, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN));
}

static BOOL current_mode(DEVMODEA *mode)
{
    HDC dc = GetDC(NULL);
    DWORD size = mode->dmSize ? mode->dmSize : sizeof(*mode);

    if (!dc) return FALSE;
    memset(mode, 0, size < sizeof(*mode) ? size : sizeof(*mode));
    mode->dmSize = size;
    mode->dmPelsWidth = GetSystemMetrics(SM_CXSCREEN);
    mode->dmPelsHeight = GetSystemMetrics(SM_CYSCREEN);
    mode->dmBitsPerPel = GetDeviceCaps(dc, BITSPIXEL) * GetDeviceCaps(dc, PLANES);
    mode->dmDisplayFrequency = GetDeviceCaps(dc, VREFRESH);
    if (mode->dmDisplayFrequency <= 1) mode->dmDisplayFrequency = 60;  /* "default" */
    mode->dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_BITSPERPEL | DM_DISPLAYFREQUENCY;
    ReleaseDC(NULL, dc);
    return TRUE;
}

HMONITOR WINAPI compat_MonitorFromWindow(HWND hwnd, DWORD flags)
{
    REAL("MonitorFromWindow", HMONITOR (WINAPI *)(HWND, DWORD))
    return real ? real(hwnd, flags) : PRIMARY_MONITOR;
}

BOOL WINAPI compat_GetMonitorInfoA(HMONITOR monitor, MONITORINFO *info)
{
    REAL("GetMonitorInfoA", BOOL (WINAPI *)(HMONITOR, MONITORINFO *))
    if (real) return real(monitor, info);
    if (monitor != PRIMARY_MONITOR || !info || info->cbSize < sizeof(MONITORINFO)) return FALSE;
    primary_rect(&info->rcMonitor);
    if (!SystemParametersInfoA(SPI_GETWORKAREA, 0, &info->rcWork, 0)) info->rcWork = info->rcMonitor;
    info->dwFlags = MONITORINFOF_PRIMARY;
    if (info->cbSize >= sizeof(MONITORINFOEXA)) lstrcpyA(((MONITORINFOEXA *)info)->szDevice, "DISPLAY");
    return TRUE;
}

BOOL WINAPI compat_EnumDisplayMonitors(HDC dc, const RECT *clip, MONITORENUMPROC proc, LPARAM param)
{
    RECT rect, box;

    REAL("EnumDisplayMonitors", BOOL (WINAPI *)(HDC, const RECT *, MONITORENUMPROC, LPARAM))
    if (real) return real(dc, clip, proc, param);
    if (!proc) return FALSE;
    primary_rect(&rect);
    if (dc && GetClipBox(dc, &box) != ERROR && !IntersectRect(&rect, &rect, &box)) return TRUE;
    if (clip && !IntersectRect(&rect, &rect, clip)) return TRUE;
    proc(PRIMARY_MONITOR, dc, &rect, param);
    return TRUE;
}

BOOL WINAPI compat_EnumDisplayDevicesA(const char *device, DWORD index, DISPLAY_DEVICEA *info, DWORD flags)
{
    REAL("EnumDisplayDevicesA", BOOL (WINAPI *)(const char *, DWORD, DISPLAY_DEVICEA *, DWORD))
    if (real) return real(device, index, info, flags);
    if (device || index || !info || info->cb < offsetof(DISPLAY_DEVICEA, DeviceID)) return FALSE;
    lstrcpyA(info->DeviceName, "DISPLAY");   /* CreateDCA() accepts this name on Windows 95 */
    lstrcpyA(info->DeviceString, "Primary display");
    info->StateFlags = DISPLAY_DEVICE_ATTACHED_TO_DESKTOP | DISPLAY_DEVICE_PRIMARY_DEVICE;
    if (info->cb >= sizeof(DISPLAY_DEVICEA)) info->DeviceID[0] = info->DeviceKey[0] = 0;
    return TRUE;
}

BOOL WINAPI compat_EnumDisplaySettingsA(const char *device, DWORD mode_index, DEVMODEA *mode)
{
    REAL("EnumDisplaySettingsA", BOOL (WINAPI *)(const char *, DWORD, DEVMODEA *))
    if (real && real(device, mode_index, mode)) return TRUE;
    if (real && real(NULL, mode_index, mode)) return TRUE;   /* Windows 95: no device names */
    if (mode && (mode_index == ENUM_CURRENT_SETTINGS || mode_index == ENUM_REGISTRY_SETTINGS))
        return current_mode(mode);
    return FALSE;
}

BOOL WINAPI compat_EnumDisplaySettingsExA(const char *device, DWORD mode_index, DEVMODEA *mode, DWORD flags)
{
    REAL("EnumDisplaySettingsExA", BOOL (WINAPI *)(const char *, DWORD, DEVMODEA *, DWORD))
    if (real) return real(device, mode_index, mode, flags);
    return compat_EnumDisplaySettingsA(device, mode_index, mode);
}

LONG WINAPI compat_ChangeDisplaySettingsExA(const char *device, DEVMODEA *mode, HWND hwnd, DWORD flags, void *param)
{
    REAL("ChangeDisplaySettingsExA", LONG (WINAPI *)(const char *, DEVMODEA *, HWND, DWORD, void *))
    if (real) return real(device, mode, hwnd, flags, param);
    return ChangeDisplaySettingsA(mode, flags);
}

BOOL WINAPI compat_GetCursorInfo(CURSORINFO *info)
{
    REAL("GetCursorInfo", BOOL (WINAPI *)(CURSORINFO *))
    if (real) return real(info);
    if (!info || info->cbSize < sizeof(CURSORINFO)) return FALSE;
    info->flags = CURSOR_SHOWING;
    info->hCursor = GetCursor();
    return GetCursorPos(&info->ptScreenPos);
}

__asm__(
    ".section .rdata,\"dr\"\n"
    ".globl __imp__MonitorFromWindow@8\n"        "__imp__MonitorFromWindow@8:\n"        "    .long _compat_MonitorFromWindow@8\n"
    ".globl __imp__GetMonitorInfoA@8\n"          "__imp__GetMonitorInfoA@8:\n"          "    .long _compat_GetMonitorInfoA@8\n"
    ".globl __imp__EnumDisplayMonitors@16\n"     "__imp__EnumDisplayMonitors@16:\n"     "    .long _compat_EnumDisplayMonitors@16\n"
    ".globl __imp__EnumDisplayDevicesA@16\n"     "__imp__EnumDisplayDevicesA@16:\n"     "    .long _compat_EnumDisplayDevicesA@16\n"
    ".globl __imp__EnumDisplaySettingsA@12\n"    "__imp__EnumDisplaySettingsA@12:\n"    "    .long _compat_EnumDisplaySettingsA@12\n"
    ".globl __imp__EnumDisplaySettingsExA@16\n"  "__imp__EnumDisplaySettingsExA@16:\n"  "    .long _compat_EnumDisplaySettingsExA@16\n"
    ".globl __imp__ChangeDisplaySettingsExA@20\n" "__imp__ChangeDisplaySettingsExA@20:\n" "    .long _compat_ChangeDisplaySettingsExA@20\n"
    ".globl __imp__GetCursorInfo@4\n"            "__imp__GetCursorInfo@4:\n"            "    .long _compat_GetCursorInfo@4\n"
    ".text\n");

#endif /* __MINGW32__ */
