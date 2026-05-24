/*
 * Unit tests for qemu3dfx_hooks.c
 *
 * Compiled on Linux by providing mock Windows types (tests/include/windows.h)
 * and mock kernel32 implementations (tests/mock_win32.c).
 *
 * Compile + run:
 *   make tests/run_test_hooks && tests/run_test_hooks
 *
 * IMPORTANT: test_hal_3dfx_not_detected() MUST run first because
 * wined3d_hal_3dfx() contains unclearable function-local statics.
 */
#include "include/windows.h"
#include <stdio.h>
#include <string.h>

/* External mock state (defined in mock_win32.c) */
extern int    mock_qemuchs_accessible;
extern HANDLE mock_opengl32_handle;

/* ── Pull in the unit under test ─────────────────────────────────── */
#include "../qemu3dfx_hooks.c"

/* ── Minimal test framework ──────────────────────────────────────── */
static int g_tests_passed = 0;
static int g_tests_failed = 0;

#define ASSERT(expr, msg) \
    do { \
        if ((expr)) { \
            g_tests_passed++; \
        } else { \
            fprintf(stderr, "FAIL [%s:%d]: %s\n", __FILE__, __LINE__, (msg)); \
            g_tests_failed++; \
        } \
    } while (0)

/* Reset all module-level globals (does NOT reset function-local statics
 * inside wined3d_hal_3dfx — run that test first with QEMUchs absent). */
static void reset_state(void)
{
    qemu3dfx_detected         = FALSE;
    hal_enum_done             = FALSE;
    ddheap_active             = FALSE;
    passthru_enabled          = FALSE;
    override_counter          = (DWORD)-1;
    override_trigger          = (DWORD)-1;
    blit_frame_count          = 0;
    flip_frame_count          = 0;
    p_wglGetDeviceGammaRamp3DFX = NULL;
    p_wglSetDeviceGammaRamp3DFX = NULL;
    p_wglSetDeviceCursor3DFX    = NULL;
    mock_qemuchs_accessible   = 0;
    mock_opengl32_handle      = NULL;
}

/* ── Tests ───────────────────────────────────────────────────────── */

/* Must run first: exercises wined3d_hal_3dfx() while its local statics
 * are in the initial (unchecked) state. */
static void test_hal_3dfx_not_detected(void)
{
    reset_state();
    mock_qemuchs_accessible = 0;

    ASSERT(wined3d_hal_3dfx() == FALSE,
           "hal_3dfx: returns FALSE when QEMUchs absent");

    /* Second call must return the cached result, not re-probe. */
    ASSERT(wined3d_hal_3dfx() == FALSE,
           "hal_3dfx: subsequent call returns cached FALSE");

    /* Side-effect flags must remain unset when not detected. */
    ASSERT(hal_enum_done    == FALSE, "hal_3dfx: hal_enum_done not set when undetected");
    ASSERT(ddheap_active    == FALSE, "hal_3dfx: ddheap_active not set when undetected");
    ASSERT(passthru_enabled == FALSE, "hal_3dfx: passthru_enabled not set when undetected");
}

static void test_detect_qemu_passthrough(void)
{
    reset_state();

    mock_qemuchs_accessible = 0;
    ASSERT(detect_qemu_passthrough() == FALSE,
           "detect_passthrough: returns FALSE when device absent");

    mock_qemuchs_accessible = 1;
    ASSERT(detect_qemu_passthrough() == TRUE,
           "detect_passthrough: returns TRUE when device present");
}

static void test_ensure_detected(void)
{
    reset_state();
    mock_qemuchs_accessible = 1;

    ensure_detected();
    ASSERT(qemu3dfx_detected == TRUE,
           "ensure_detected: sets qemu3dfx_detected when device present");

    /* Second call: already detected, must not re-probe. */
    mock_qemuchs_accessible = 0;
    ensure_detected();
    ASSERT(qemu3dfx_detected == TRUE,
           "ensure_detected: does not clear flag on second call");
}

static void test_ensure_detected_not_present(void)
{
    reset_state();
    mock_qemuchs_accessible = 0;

    ensure_detected();
    ASSERT(qemu3dfx_detected == FALSE,
           "ensure_detected: qemu3dfx_detected remains FALSE when device absent");
}

static void test_enum_hal_last(void)
{
    reset_state();
    ASSERT(wined3d_enum_hal_last() == FALSE, "enum_hal_last: initially FALSE");

    hal_enum_done = TRUE;
    ASSERT(wined3d_enum_hal_last() == TRUE,  "enum_hal_last: returns TRUE after flag set");
}

static void test_surface_ddheap(void)
{
    reset_state();
    ASSERT(wined3d_surface_ddheap() == FALSE, "surface_ddheap: initially FALSE");

    ddheap_active = TRUE;
    ASSERT(wined3d_surface_ddheap() == TRUE,  "surface_ddheap: returns TRUE after flag set");
}

static void test_passthru(void)
{
    reset_state();

    /* NULL arg — must not set the flag */
    ASSERT(wined3d_passthru(NULL) == FALSE,
           "passthru: NULL arg returns FALSE and does not enable");
    ASSERT(passthru_enabled == FALSE,
           "passthru: flag still FALSE after NULL arg");

    /* FALSE arg — must not set the flag */
    BOOL disable = FALSE;
    ASSERT(wined3d_passthru(&disable) == FALSE,
           "passthru: FALSE arg returns FALSE and does not enable");
    ASSERT(passthru_enabled == FALSE,
           "passthru: flag still FALSE after FALSE arg");

    /* TRUE arg — must set the flag */
    BOOL enable = TRUE;
    ASSERT(wined3d_passthru(&enable) == TRUE,
           "passthru: TRUE arg enables and returns TRUE");
    ASSERT(passthru_enabled == TRUE,
           "passthru: flag is TRUE after TRUE arg");

    /* NULL after enable — must return the current state (TRUE) */
    ASSERT(wined3d_passthru(NULL) == TRUE,
           "passthru: NULL arg after enable returns TRUE");
}

static void test_override_cooplevel_sentinel(void)
{
    reset_state();
    /* override_counter == (DWORD)-1 → must be a no-op */
    DWORD level = 0x08;
    wined3d_override_cooplevel(&level);
    ASSERT(level == 0x08,
           "override_cooplevel: no-op when counter is sentinel");
}

static void test_override_cooplevel_decrement_no_trigger(void)
{
    reset_state();
    override_counter = 3;
    override_trigger = (DWORD)-1;   /* sentinel = no trigger */

    DWORD level = 0x08;
    wined3d_override_cooplevel(&level);

    ASSERT(override_counter == 2,
           "override_cooplevel: counter decremented from 3 to 2");
    ASSERT(level == 0x08,
           "override_cooplevel: level unchanged when trigger is sentinel and counter > 1");
}

static void test_override_cooplevel_reaches_zero(void)
{
    reset_state();
    override_counter = 1;
    override_trigger = (DWORD)-1;

    DWORD level = 0x08;
    wined3d_override_cooplevel(&level);

    ASSERT(override_counter == 0,
           "override_cooplevel: counter decremented to 0");
    ASSERT(level == (0x08 ^ 0x10),
           "override_cooplevel: 0x10 XORed when counter reaches 0");
}

static void test_override_cooplevel_with_trigger(void)
{
    reset_state();
    override_counter = 3;
    override_trigger = 5;   /* not sentinel → flags = 0x10 */

    DWORD level = 0x08;
    wined3d_override_cooplevel(&level);

    ASSERT(override_counter == 2,
           "override_cooplevel: counter decremented with trigger set");
    ASSERT(level == (0x08 ^ 0x10),
           "override_cooplevel: 0x10 XORed when trigger is not sentinel");
}

static void test_override_rendertarget_view_null(void)
{
    reset_state();
    /* Must not crash on NULL. */
    wined3d_override_rendertarget_view(NULL);
    ASSERT(1, "override_rtv: NULL view pointer does not crash");
}

static void test_override_rendertarget_view_null_resource(void)
{
    reset_state();
    /* view[1] (resource ptr) is NULL — must not crash. */
    void *view[2] = { (void *)0xDEADBEEFUL, NULL };
    wined3d_override_rendertarget_view(view);
    ASSERT(1, "override_rtv: NULL resource pointer does not crash");
}

static void test_override_rendertarget_view_sets_flag(void)
{
    reset_state();
    /* Allocate a dummy resource large enough for offset 0x34 + sizeof(DWORD). */
    static unsigned char resource[0x50];
    memset(resource, 0, sizeof(resource));

    void *view[2] = { (void *)0xDEADBEEFUL, resource };
    wined3d_override_rendertarget_view(view);

    DWORD *flags = (DWORD *)(resource + 0x34);
    ASSERT((*flags & 0x20) != 0,
           "override_rtv: bit 0x20 set in resource->access_flags");
}

static void test_override_rendertarget_view_idempotent(void)
{
    reset_state();
    static unsigned char resource[0x50];
    memset(resource, 0, sizeof(resource));

    void *view[2] = { (void *)0xDEADBEEFUL, resource };
    wined3d_override_rendertarget_view(view);

    DWORD *flags   = (DWORD *)(resource + 0x34);
    DWORD before   = *flags;

    wined3d_override_rendertarget_view(view);
    ASSERT(*flags == before,
           "override_rtv: idempotent — second call does not change flags");
}

static void test_blit_fpslimit(void)
{
    reset_state();
    ASSERT(blit_frame_count == 0,
           "blit_fpslimit: counter starts at 0");

    ASSERT(wined3d_blit_fpslimit() == TRUE,
           "blit_fpslimit: returns TRUE");
    ASSERT(blit_frame_count == 1,
           "blit_fpslimit: counter incremented to 1");

    wined3d_blit_fpslimit();
    ASSERT(blit_frame_count == 2,
           "blit_fpslimit: counter incremented to 2 on second call");
}

static void test_flip_fpslimit(void)
{
    reset_state();
    ASSERT(flip_frame_count == 0,
           "flip_fpslimit: counter starts at 0");

    ASSERT(wined3d_flip_fpslimit() == TRUE,
           "flip_fpslimit: returns TRUE");
    ASSERT(flip_frame_count == 1,
           "flip_fpslimit: counter incremented to 1");

    wined3d_flip_fpslimit();
    ASSERT(flip_frame_count == 2,
           "flip_fpslimit: counter incremented to 2 on second call");
}

static void test_gamma_ramp_no_extension(void)
{
    reset_state();
    /* Extension function pointers are NULL → must return FALSE. */
    ASSERT(wined3d_get_gamma_ramp_3dfx(NULL, NULL) == FALSE,
           "get_gamma_ramp_3dfx: returns FALSE without extension loaded");
    ASSERT(wined3d_set_gamma_ramp_3dfx(NULL, NULL) == FALSE,
           "set_gamma_ramp_3dfx: returns FALSE without extension loaded");
    ASSERT(wined3d_set_cursor_3dfx(NULL, NULL) == FALSE,
           "set_cursor_3dfx: returns FALSE without extension loaded");
}

static void test_registry_key_strings(void)
{
    ASSERT(strcmp(qemu3dfx_hal_key,          "D3D1Hal3Dfx")     == 0,
           "registry: qemu3dfx_hal_key == 'D3D1Hal3Dfx'");
    ASSERT(strcmp(qemu3dfx_enum_hal_last_key, "D3D1EnumHalLast") == 0,
           "registry: qemu3dfx_enum_hal_last_key == 'D3D1EnumHalLast'");
}

static void test_wgl_extension_string(void)
{
    ASSERT(strcmp(wgl_3dfx_gamma_control, "WGL_3DFX_gamma_control") == 0,
           "wgl: gamma control extension string is 'WGL_3DFX_gamma_control'");
}

/* ── Main ────────────────────────────────────────────────────────── */
int main(void)
{
    /* hal_3dfx MUST be first — it has unclearable local statics. */
    test_hal_3dfx_not_detected();

    test_detect_qemu_passthrough();
    test_ensure_detected();
    test_ensure_detected_not_present();
    test_enum_hal_last();
    test_surface_ddheap();
    test_passthru();
    test_override_cooplevel_sentinel();
    test_override_cooplevel_decrement_no_trigger();
    test_override_cooplevel_reaches_zero();
    test_override_cooplevel_with_trigger();
    test_override_rendertarget_view_null();
    test_override_rendertarget_view_null_resource();
    test_override_rendertarget_view_sets_flag();
    test_override_rendertarget_view_idempotent();
    test_blit_fpslimit();
    test_flip_fpslimit();
    test_gamma_ramp_no_extension();
    test_registry_key_strings();
    test_wgl_extension_string();

    printf("test_hooks: %d passed, %d failed\n",
           g_tests_passed, g_tests_failed);
    return g_tests_failed > 0 ? 1 : 0;
}
