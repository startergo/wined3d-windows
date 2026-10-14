/*
 * Host unit tests for qemu3dfx_hooks.c (the qemu-3dfx wined3d module).
 *
 * Compiled natively with mock Windows types/APIs (tests/include/windows.h,
 * tests/mock_win32.c), once per behaviour family:
 *   make test        -> tests/run_test_hooks (Wine 8.0 behaviour) and
 *                       tests/run_test_hooks_1_8 (Wine 1.8 behaviour)
 *
 * Expected values are the reference semantics (qemu-3dfx)
 * that tests/emu/test_module.py checks against the original machine code;
 * this suite is the fast, dependency-free regression net for them.
 */
#include "include/windows.h"
#include <stdio.h>
#include <string.h>
#include "mock_win32.h"

#ifndef QEMU3DFX_WINE_MAJOR
#define QEMU3DFX_WINE_MAJOR 8
#define QEMU3DFX_WINE_MINOR 0
#endif

/* ── Pull in the unit under test ─────────────────────────────────── */
#include "../qemu3dfx_hooks.c"

/* ── Minimal test framework ──────────────────────────────────────── */
static int g_passed, g_failed;

#define ASSERT_EQ(actual, expected, msg) do { \
        unsigned long long a_ = (unsigned long long)(actual), e_ = (unsigned long long)(expected); \
        if (a_ == e_) g_passed++; \
        else { fprintf(stderr, "FAIL [%s:%d] %s: got %#llx, expected %#llx\n", \
                       __FILE__, __LINE__, (msg), a_, e_); g_failed++; } \
    } while (0)
#define ASSERT(expr, msg) ASSERT_EQ(!!(expr), 1, msg)

static __typeof__(cfg) cfg_defaults;

/* back to "fresh process": mocks, config, and every module static */
static void reset(void)
{
    mock_reset();
    cfg = cfg_defaults;
    cfg_loaded = 0;
    passthru_flag = 0;
    fps_next_tick = 0;
    memset(latch, 0, sizeof(latch));
    cursor_last_tick = 0;
    cursor_last.x = cursor_last.y = 0;
    cursor_procs_resolved = FALSE;
    p_wglSetDeviceCursor3DFX = NULL;
    p_glDebugMessageInsertARB = NULL;
}

/* ── Configuration ───────────────────────────────────────────────── */

static void test_defaults(void)
{
    reset();
    ASSERT_EQ(wined3d_hal_3dfx(), FALSE, "hal_3dfx default for GAME.EXE");
    ASSERT_EQ(wined3d_enum_hal_last(), TRUE, "enum_hal_last defaults on");
    ASSERT_EQ(wined3d_surface_ddheap(), TRUE, "DDSurfaceHeap defaults on");
    ASSERT_EQ(qemu3dfx_use_last_context_tid(), QEMU3DFX_WINE_MAJOR >= 8,
              "UseLastContextTid default (on from 8.0)");
    ASSERT_EQ(qemu3dfx_scale_window_value(), 0xffffffff, "ScaleWindow unset");
}

static void test_hal_3dfx_exe_list(void)
{
    static const struct { const char *exe; BOOL hal; } cases[] = {
        { "C:\\GAMES\\DS9\\ds9dw.exe", TRUE },
        { "C:\\GAMES\\DS9\\DS9DW.EXE", TRUE },          /* case-insensitive */
        { "C:/WEIRD/ds9dw.exe", TRUE },                  /* forward slashes */
        { "C:\\KONAMI\\Silent Hill 4.exe", FALSE },      /* not in the HAL list */
        { "C:\\GAMES\\ds9dw.exe.bak", FALSE },
    };
    unsigned i;
    for (i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i)
    {
        reset();
        mock_exe_path = cases[i].exe;
        ASSERT_EQ(wined3d_hal_3dfx(), cases[i].hal, cases[i].exe);
    }
}

static void test_registry_strings(void)
{
    reset(); mock_reg_def_str("D3D1Hal3Dfx", "enabled");
    ASSERT_EQ(wined3d_hal_3dfx(), TRUE, "D3D1Hal3Dfx=enabled");

    reset(); mock_reg_def_str("D3D1Hal3Dfx", "Enabled");
    ASSERT_EQ(wined3d_hal_3dfx(), FALSE, "string compare is case-sensitive");

    reset(); mock_reg_def_dword("D3D1Hal3Dfx", 1);
    ASSERT_EQ(wined3d_hal_3dfx(), FALSE, "REG_DWORD ignored for string keys");

    reset(); mock_reg_def_str("D3D1EnumHalLast", "disabled");
    ASSERT_EQ(wined3d_enum_hal_last(), FALSE, "D3D1EnumHalLast=disabled");

    reset(); mock_reg_def_str("DDSurfaceHeap", "disabled");
    ASSERT_EQ(wined3d_surface_ddheap(), QEMU3DFX_WINE_MAJOR >= 6 ? FALSE : TRUE,
              "DDSurfaceHeap=disabled (read from 6.0)");

    reset(); mock_reg_def_str("UseLastContextTid", "enabled");
    ASSERT_EQ(qemu3dfx_use_last_context_tid(), TRUE, "UseLastContextTid=enabled");

    reset(); mock_reg_def_str("UseLastContextTid", "disabled");
    ASSERT_EQ(qemu3dfx_use_last_context_tid(), FALSE, "UseLastContextTid=disabled");
}

static void test_registry_app_overrides(void)
{
    reset();
    mock_reg_def_str("D3D1Hal3Dfx", "enabled");
    mock_reg_def_dword("ScaleWindow", 0x01000100);
    mock_reg_app_str("D3D1Hal3Dfx", "disabled");
    mock_reg_app_dword("ScaleWindow", 0x02800 << 4);
    ASSERT_EQ(wined3d_hal_3dfx(), FALSE, "AppDefaults string wins over global");
    ASSERT_EQ(qemu3dfx_scale_window_value(), 0x02800 << 4, "AppDefaults DWORD wins");

    reset();
    mock_reg_app_str("D3D1Hal3Dfx", "enabled");
    ASSERT_EQ(wined3d_hal_3dfx(), TRUE, "AppDefaults alone");
}

/* ── Exports ─────────────────────────────────────────────────────── */

static void test_passthru(void)
{
    BOOL v;
    reset();
    ASSERT_EQ(wined3d_passthru(NULL), FALSE, "initially off");
    v = TRUE;  ASSERT_EQ(wined3d_passthru(&v), TRUE, "enable");
    ASSERT_EQ(wined3d_passthru(NULL), TRUE, "query keeps state");
    v = FALSE; ASSERT_EQ(wined3d_passthru(&v), FALSE, "disable");
    v = 7;     ASSERT_EQ(wined3d_passthru(&v), TRUE, "non-zero normalised to 1");
    ASSERT_EQ(qemu3dfx_passthru_active(), TRUE, "core accessor");
}

static void test_override_cooplevel(void)
{
    DWORD v;

    reset(); v = 0x8;
    wined3d_override_cooplevel(&v);
    ASSERT_EQ(v, 0x8, "unchanged without OverrideCoopFullscreen");

    reset(); mock_reg_def_dword("OverrideCoopFullscreen", 1); mock_reg_def_dword("ScaleWindow", 0x028001e0);
    v = 0x8; wined3d_override_cooplevel(&v);
    ASSERT_EQ(v, 0x8 ^ 0x11, "Coop=1 + ScaleWindow: toggle FULLSCREEN and NOWINDOWCHANGES");

    reset(); mock_reg_def_dword("OverrideCoopFullscreen", 0); mock_reg_def_dword("ScaleWindow", 0x028001e0);
    v = 0x11; wined3d_override_cooplevel(&v);
    ASSERT_EQ(v, 0x10, "Coop=0 + ScaleWindow: toggle FULLSCREEN only");

    reset(); mock_reg_def_dword("OverrideCoopFullscreen", 1);
    v = 0; wined3d_override_cooplevel(&v);
    ASSERT_EQ(v, 0x10, "Coop=1 without ScaleWindow: toggle NOWINDOWCHANGES only");
}

static void test_override_rendertarget_view(void)
{
    DWORD resource[32];
    char *view[2];
    const unsigned off = RESOURCE_RT_OFFSET / 4;
    const DWORD bit = QEMU3DFX_WINE_MAJOR >= 4 ? 0x20 : 0x1;

    reset();
    wined3d_override_rendertarget_view(NULL);            /* must not crash */

    memset(resource, 0, sizeof(resource));
    view[0] = NULL; view[1] = (char *)resource;
    wined3d_override_rendertarget_view(view);
    ASSERT_EQ(resource[off], bit, "render-target bit set at version offset");
    resource[off] = 0x200;
    wined3d_override_rendertarget_view(view);
    ASSERT_EQ(resource[off], 0x200 | bit, "other bits preserved");
    wined3d_override_rendertarget_view(view);
    ASSERT_EQ(resource[off], 0x200 | bit, "idempotent");
}

static void test_fps_limits(void)
{
    /* BlitFpsLimit uses the low byte, FlipFpsLimit the low 7 bits */
    reset();
    mock_reg_def_dword("BlitFpsLimit", 0x1ff);           /* -> 255 fps -> 3 ms */
    mock_reg_def_dword("FlipFpsLimit", 0xff);            /* -> 127 fps -> 7 ms */
    mock_clock[0] = 1000; mock_clock[1] = 1000; mock_clock_len = 2;
    wined3d_blit_fpslimit();
    ASSERT_EQ(fps_next_tick, 1003, "blit: next slot = now + 1000/255");
    ASSERT_EQ(mock_sleep_calls, 0, "blit: no wait on first frame");

    mock_clock[2] = 1001; mock_clock[3] = 1002; mock_clock[4] = 1003; mock_clock[5] = 1003;
    mock_clock_len = 6;
    wined3d_flip_fpslimit();
    ASSERT_EQ(mock_sleep_calls, 2, "flip: spins until the slot");
    ASSERT_EQ(fps_next_tick, 1003 + 7, "flip: next slot = now + 1000/127");

    reset();
    mock_reg_def_dword("BlitFpsLimit", 0x100);           /* low byte 0 -> off */
    wined3d_blit_fpslimit();
    ASSERT_EQ(mock_clock_pos, 0, "limit 0: clock not even read");
}

/* ── Internal API ────────────────────────────────────────────────── */

static void test_display_roi(void)
{
    RECT r = { 0, 0, 640, 480 };
    reset();
    qemu3dfx_display_roi(&r);
    ASSERT(r.left == 0 && r.top == 0 && r.right == 640 && r.bottom == 480, "ROI unset: unchanged");

    reset(); mock_reg_def_dword("DisplayROI", 0x00100020);  /* x margin 0x10, y margin 0x20 */
    qemu3dfx_display_roi(&r);
    ASSERT(r.left == 16 && r.right == 624 && r.top == 32 && r.bottom == 448, "ROI applied");
}

static void test_override_mode(void)
{
    DEVMODEA dm;
#define MODE(w, h, b) (memset(&dm, 0, sizeof(dm)), dm.dmPelsWidth = (w), dm.dmPelsHeight = (h), dm.dmBitsPerPel = (b))

    reset(); MODE(640, 480, 32);
    ASSERT_EQ(qemu3dfx_override_mode(&dm), FALSE, "unset: no change");

    reset(); mock_reg_def_dword("OverrideModeWidth", 800); MODE(640, 480, 32);
    ASSERT_EQ(qemu3dfx_override_mode(&dm), TRUE, "width only: changed");
    ASSERT(dm.dmPelsWidth == 800 && dm.dmPelsHeight == 600 && dm.dmBitsPerPel == 32, "aspect kept");

    reset(); mock_reg_def_dword("OverrideModeWidth", 0x028001e0); MODE(800, 600, 32);
    ASSERT_EQ(qemu3dfx_override_mode(&dm), TRUE, "packed w:h");
    ASSERT(dm.dmPelsWidth == 640 && dm.dmPelsHeight == 480, "packed w:h applied");

    reset(); mock_reg_def_dword("OverrideModeWidth", 640); MODE(640, 480, 32);
    ASSERT_EQ(qemu3dfx_override_mode(&dm), FALSE, "same size, 32 bpp: no change");

    reset(); mock_reg_def_dword("OverrideModeWidth", 640); MODE(640, 480, 8);
    ASSERT_EQ(qemu3dfx_override_mode(&dm), TRUE, "below 16 bpp forced");
    ASSERT_EQ(dm.dmBitsPerPel, 16, "-> 16 bpp");

    reset(); mock_reg_def_dword("OverrideModeWidth", 0x80000280); MODE(640, 480, 32);
    ASSERT_EQ(qemu3dfx_override_mode(&dm), TRUE, "sign bit forces 16 bpp");
    ASSERT_EQ(dm.dmBitsPerPel, 16, "sign bit -> 16 bpp");
#undef MODE
}

static void test_swap_interval(void)
{
    int v = 1;
    reset(); qemu3dfx_swap_interval(&v);
    ASSERT_EQ(v, 1, "unset: unchanged");
    reset(); mock_reg_def_dword("SwapInterval", 0); qemu3dfx_swap_interval(&v);
    ASSERT_EQ(v, 0, "override to 0");
}

static void test_scale_window(void)
{
    RECT w = { 9, 9, 9, 9 }, s = { 9, 9, 9, 9 };
    DWORD mode = 7;

    reset();
    ASSERT_EQ(qemu3dfx_scale_window(&w, &s, &mode), FALSE, "unset: FALSE");
    ASSERT(w.left == 9 && mode == 7, "unset: untouched");

    reset(); mock_reg_def_dword("ScaleWindow", 0x828001e0);
    ASSERT_EQ(qemu3dfx_scale_window(&w, &s, &mode), TRUE, "set: TRUE");
    ASSERT(w.left == 0 && w.right == 0x280 && w.bottom == 0x01e0, "window size from packed value");
    ASSERT(s.left == 0 && s.top == 0 && s.right == 1024 && s.bottom == 768, "screen rect");
    ASSERT_EQ(mode, 2, "sign bit -> mode 2");
    ASSERT_EQ(qemu3dfx_scale_window(NULL, NULL, NULL), TRUE, "NULL args allowed");
}

static void test_latches(void)
{
    reset();
    ASSERT_EQ(qemu3dfx_latch0(0), 0, "empty");
    ASSERT_EQ(qemu3dfx_latch0(0x10000000), 0x10000000, "store");
    ASSERT_EQ(qemu3dfx_latch0(0), 0x10000000, "0 keeps value");
    ASSERT_EQ(qemu3dfx_latch1(0), 0, "independent");
}

static void test_is_qemu_bochs(void)
{
    static const struct { const char *s; BOOL r; } cases[] = {
        { "QEMU Bochs Compatible VGA", TRUE }, { "QEMU Bochs", TRUE },
        { "QEMU bochs", FALSE }, { "QEMU", FALSE }, { "Standard VGA", FALSE }, { NULL, FALSE },
    };
    unsigned i;
    for (i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i)
    {
        reset(); mock_adapter = cases[i].s;
        ASSERT_EQ(qemu3dfx_is_qemu_bochs(), cases[i].r, cases[i].s ? cases[i].s : "(no adapter)");
    }
}

static void test_cursor_channel(void)
{
    reset();
    qemu3dfx_set_host_cursor((HCURSOR)0xc0ffee);
    ASSERT_EQ(mock_set_cursor_calls, 1, "set_host_cursor on QEMU");
    ASSERT_EQ((uintptr_t)mock_set_cursor_last, 0xc0ffee, "cursor handle passed through");

    reset(); mock_adapter = "Standard VGA";
    qemu3dfx_set_host_cursor((HCURSOR)1);
    ASSERT_EQ(mock_set_cursor_calls, 0, "no host cursor off QEMU");

    /* window (10,20)-(650,520), client 632x474: frame = 500-474 = 26;
       cursor (100,200) -> y 174 -> scaled to 1024x768:
       x = MulDiv(100, 1023, 639) = 160, y = MulDiv(174, 767, 499) = 267 */
    reset();
    mock_clock[0] = 1000; mock_clock_len = 1;
    qemu3dfx_cursor_sync((HWND)1);
    ASSERT_EQ(mock_debug_msg_calls, 1, "position sent on change");
    ASSERT_EQ(mock_debug_msg_payload, (160u << 16) | 267u, "packed x/y");
    ASSERT(mock_debug_msg_args[0] == 0x8247 && mock_debug_msg_args[1] == 0x8251 &&
           mock_debug_msg_args[2] == 0x9148 && mock_debug_msg_args[3] == 0xffffffff &&
           mock_debug_msg_args[4] == 4, "magic glDebugMessageInsertARB arguments");
    ASSERT_EQ(mock_set_cursor_calls, 1, "cursor image sent with position");

    mock_clock[1] = 1005; mock_clock_len = 2;            /* < 16 ms later */
    mock_cursor.ptScreenPos.x = 300;
    qemu3dfx_cursor_sync((HWND)1);
    ASSERT_EQ(mock_debug_msg_calls, 1, "rate-limited to 16 ms");

    mock_clock[2] = 1100; mock_clock_len = 3;
    mock_cursor.flags = 0;                               /* hidden */
    qemu3dfx_cursor_sync((HWND)1);
    ASSERT_EQ(mock_debug_msg_calls, 2, "hide sent");
    ASSERT_EQ(mock_debug_msg_payload, 0, "hidden -> 0,0");
}

static void test_sysmem_quirk(void)
{
    LONG count;

    reset(); mock_quartz_loaded = 1; mock_exe_path = "C:\\KONAMI\\SH4\\Silent Hill 4.exe";
    count = 1; qemu3dfx_sysmem_count_quirk(0x12, &count);
    ASSERT_EQ(count, QEMU3DFX_WINE_MAJOR >= 2 ? 2 : 1, "SH4 + quartz + 0x12 + count 1");

    count = 1; qemu3dfx_sysmem_count_quirk(0x13, &count);
    ASSERT_EQ(count, 1, "other locations untouched");
    count = 2; qemu3dfx_sysmem_count_quirk(0x12, &count);
    ASSERT_EQ(count, 2, "count != 1 untouched");

    reset(); mock_exe_path = "C:\\KONAMI\\SH4\\Silent Hill 4.exe";
    count = 1; qemu3dfx_sysmem_count_quirk(0x12, &count);
    ASSERT_EQ(count, 1, "needs quartz loaded");

    reset(); mock_quartz_loaded = 1;
    count = 1; qemu3dfx_sysmem_count_quirk(0x12, &count);
    ASSERT_EQ(count, 1, "needs Silent Hill 4");
}

int main(void)
{
    cfg_defaults = cfg;

    test_defaults();
    test_hal_3dfx_exe_list();
    test_registry_strings();
    test_registry_app_overrides();
    test_passthru();
    test_override_cooplevel();
    test_override_rendertarget_view();
    test_fps_limits();
    test_display_roi();
    test_override_mode();
    test_swap_interval();
    test_scale_window();
    test_latches();
    test_is_qemu_bochs();
    test_cursor_channel();
    test_sysmem_quirk();

    printf("test_hooks (Wine %d.%d behaviour): %d passed, %d failed\n",
           QEMU3DFX_WINE_MAJOR, QEMU3DFX_WINE_MINOR, g_passed, g_failed);
    return g_failed ? 1 : 0;
}
