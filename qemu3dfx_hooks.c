/*
 * qemu-3dfx passthrough hooks for Wine wined3d
 *
 * Reverse-engineered from reference qemu-3dfx Wine 1.8.7 DLLs.
 * Provides HAL enumeration, passthrough control, render target override,
 * cooperative level override, and frame rate limiting.
 */

#ifndef _WIN32
#error "This file is for Windows PE targets only"
#endif

#include <windows.h>

/* ── Globals (matching reference .data/.bss layout) ────────────────── */

static DWORD hal_3dfx_result = 0;
static DWORD enum_hal_last_flag = 1;
static DWORD flip_fps_flag = 0;
static DWORD blit_fps_counter = 0;
static DWORD override_trigger = (DWORD)-1;
static DWORD override_counter = (DWORD)-1;
static DWORD passthru_enabled = 0;
static DWORD fps_timestamp = 0;

/* ── Frame rate limiter (matches reference RVA 0x29190) ────────────── */

static void fps_limit(DWORD divisor)
{
    DWORD now, end, target;

    if (divisor == 0) return;

    for (;;)
    {
        now = GetTickCount();
        if (now >= fps_timestamp)
            break;
        Sleep(0);
    }

    end = now;
    target = 1000 / divisor;

    if (end >= (DWORD)~target)
    {
        while (end >= (DWORD)~target)
            end = GetTickCount();
        fps_timestamp = end;
    }

    fps_timestamp = end + target;
}

/* ── QEMU display adapter detection (matches reference RVA 0x2AAFD) ── */

static int str_compare(const char *a, const char *b, int n)
{
    int i;
    for (i = 0; i < n; i++)
    {
        if (a[i] != b[i])
            return 1;
        if (a[i] == '\0' || b[i] == '\0')
            break;
    }
    return 0;
}

static BOOL detect_qemu_bochs(void)
{
    DISPLAY_DEVICEA dd;
    char qemu_bochs[] = { 'Q','E','M','U',' ','B','o','c','h','s','\0' };

    memset(&dd, 0, sizeof(dd));
    dd.cb = sizeof(dd);

    if (!EnumDisplayDevicesA(NULL, 0, &dd, 0))
        return FALSE;

    return str_compare(dd.DeviceString, qemu_bochs, 10) == 0;
}

/* ── Exported hooks ────────────────────────────────────────────────── */

BOOL WINAPI wined3d_enum_hal_last(void)
{
    return enum_hal_last_flag != 0;
}

BOOL WINAPI wined3d_passthru(BOOL *enabled)
{
    if (enabled && *enabled)
        passthru_enabled = 1;
    return passthru_enabled;
}

void WINAPI wined3d_override_cooplevel(DWORD *cooplevel)
{
    DWORD flags, new_flags;

    if (override_counter == (DWORD)-1) return;

    flags = 0;
    if (override_trigger != (DWORD)-1)
        flags = 1;
    flags ^= *cooplevel;
    *cooplevel = flags;

    new_flags = 0;
    if (override_counter == 1)
        new_flags = 1;
    new_flags <<= 4;
    new_flags ^= flags;
    *cooplevel = new_flags;
}

BOOL WINAPI wined3d_hal_3dfx(void)
{
    static const char * const exe_names[] = { "ds9dw.exe", NULL };
    char buf[260];
    const char * const *name;
    DWORD ret;

    if (hal_3dfx_result)
        return TRUE;

    /* Check 1: exe name matches known qemu-3dfx application */
    ret = GetModuleFileNameA(NULL, buf, sizeof(buf));
    if (ret > 0 && ret <= sizeof(buf) - 1)
    {
        for (name = exe_names; *name; name++)
        {
            if (strstr(buf, *name))
            {
                hal_3dfx_result = 1;
                return TRUE;
            }
        }
    }

    /* Check 2: display adapter is QEMU Bochs */
    if (detect_qemu_bochs())
    {
        hal_3dfx_result = 1;
        return TRUE;
    }

    return FALSE;
}

void WINAPI wined3d_override_rendertarget_view(void *view_ptr)
{
    void **view = (void **)view_ptr;
    DWORD *flags;

    if (!view) return;
    if (!view[1]) return;

    flags = (DWORD *)((char *)view[1] + 0x28);
    if (!(*flags & 1))
        *flags |= 1;
}

BOOL WINAPI wined3d_blit_fpslimit(void)
{
    DWORD fps = blit_fps_counter & 0x7f;
    if (fps)
        fps_limit(fps);
    return TRUE;
}

BOOL WINAPI wined3d_flip_fpslimit(void)
{
    if (flip_fps_flag)
        fps_limit(flip_fps_flag);
    return TRUE;
}

/* ── Registry config keys ─────────────────────────────────────────── */

const char qemu3dfx_hal_key[] = "D3D1Hal3Dfx";
const char qemu3dfx_enum_hal_last_key[] = "D3D1EnumHalLast";
