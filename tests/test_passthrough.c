/*
 * Unit tests for qemu3dfx_ddraw_passthrough.c
 *
 * The passthrough bridge calls into wined3d.dll exports.  This test
 * provides lightweight mock implementations of those exports so the
 * bridge logic can be exercised in complete isolation on Linux.
 *
 * Compile + run:
 *   make tests/run_test_passthrough && tests/run_test_passthrough
 */
#include "include/windows.h"
#include <stdio.h>

/* ── Mock wined3d state (controlled by individual tests) ─────────── */
static int mock_hal_3dfx_result          = 0;
static int mock_passthru_call_count      = 0;
static int mock_enum_hal_last_call_count = 0;
static int mock_surface_ddheap_call_count = 0;
static int mock_blit_call_count          = 0;
static int mock_flip_call_count          = 0;
static int mock_override_cooplevel_count = 0;
static DWORD mock_last_cooplevel         = 0;
static int mock_rtv_call_count           = 0;
static void *mock_last_rtv               = NULL;

/* ── Mock wined3d exports ────────────────────────────────────────── */
/*
 * These definitions satisfy the 'extern … WINAPI' declarations inside
 * qemu3dfx_ddraw_passthrough.c and allow behaviour to be controlled via
 * the mock_* globals above.
 */
BOOL WINAPI wined3d_hal_3dfx(void)
{
    return (BOOL)mock_hal_3dfx_result;
}

BOOL WINAPI wined3d_enum_hal_last(void)
{
    mock_enum_hal_last_call_count++;
    return TRUE;
}

/* Declared as void* in passthrough.c to match the original qemu-3dfx
   ABI; returns NULL (stub). */
void *WINAPI wined3d_surface_ddheap(void)
{
    mock_surface_ddheap_call_count++;
    return NULL;
}

BOOL WINAPI wined3d_passthru(BOOL *enabled)
{
    mock_passthru_call_count++;
    return (enabled && *enabled) ? TRUE : FALSE;
}

void WINAPI wined3d_override_cooplevel(DWORD *cooplevel)
{
    mock_override_cooplevel_count++;
    if (cooplevel)
        mock_last_cooplevel = *cooplevel;
}

void WINAPI wined3d_override_rendertarget_view(void *view)
{
    mock_rtv_call_count++;
    mock_last_rtv = view;
}

BOOL WINAPI wined3d_blit_fpslimit(void)
{
    mock_blit_call_count++;
    return TRUE;
}

BOOL WINAPI wined3d_flip_fpslimit(void)
{
    mock_flip_call_count++;
    return TRUE;
}

/* ── Pull in the unit under test ─────────────────────────────────── */
#include "../qemu3dfx_ddraw_passthrough.c"

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

/* Reset both the bridge's internal state and all mock counters. */
static void reset_state(void)
{
    g_passthru_active                = FALSE;
    mock_hal_3dfx_result             = 0;
    mock_passthru_call_count         = 0;
    mock_enum_hal_last_call_count    = 0;
    mock_surface_ddheap_call_count   = 0;
    mock_blit_call_count             = 0;
    mock_flip_call_count             = 0;
    mock_override_cooplevel_count    = 0;
    mock_last_cooplevel              = 0;
    mock_rtv_call_count              = 0;
    mock_last_rtv                    = NULL;
}

/* ── Tests ───────────────────────────────────────────────────────── */

/* Init — 3dfx not detected ──────────────────────────────────────── */
static void test_init_not_detected(void)
{
    reset_state();
    mock_hal_3dfx_result = 0;

    qemu3dfx_ddraw_passthrough_init();

    ASSERT(g_passthru_active == FALSE,
           "init: g_passthru_active remains FALSE when hal_3dfx=FALSE");
    ASSERT(mock_passthru_call_count == 0,
           "init: wined3d_passthru not called when not detected");
    ASSERT(mock_enum_hal_last_call_count == 0,
           "init: wined3d_enum_hal_last not called when not detected");
    ASSERT(mock_surface_ddheap_call_count == 0,
           "init: wined3d_surface_ddheap not called when not detected");
}

/* Init — 3dfx detected ──────────────────────────────────────────── */
static void test_init_detected(void)
{
    reset_state();
    mock_hal_3dfx_result = 1;

    qemu3dfx_ddraw_passthrough_init();

    ASSERT(g_passthru_active == TRUE,
           "init: g_passthru_active set to TRUE when hal_3dfx=TRUE");
    ASSERT(mock_passthru_call_count == 1,
           "init: wined3d_passthru called once");
    ASSERT(mock_enum_hal_last_call_count == 1,
           "init: wined3d_enum_hal_last called once");
    ASSERT(mock_surface_ddheap_call_count == 1,
           "init: wined3d_surface_ddheap called once");
}

/* Cooperative-level override — inactive ─────────────────────────── */
static void test_cooplevel_inactive(void)
{
    reset_state();
    DWORD level = 0x08;

    qemu3dfx_ddraw_cooplevel(&level);

    ASSERT(mock_override_cooplevel_count == 0,
           "cooplevel: override not called when bridge inactive");
    ASSERT(level == 0x08,
           "cooplevel: value unchanged when bridge inactive");
}

/* Cooperative-level override — active ──────────────────────────── */
static void test_cooplevel_active(void)
{
    reset_state();
    g_passthru_active = TRUE;
    DWORD level = 0x08;

    qemu3dfx_ddraw_cooplevel(&level);

    ASSERT(mock_override_cooplevel_count == 1,
           "cooplevel: wined3d_override_cooplevel called once when active");
    ASSERT(mock_last_cooplevel == 0x08,
           "cooplevel: correct cooplevel value forwarded");
}

/* Cooperative-level override — NULL pointer while active ────────── */
static void test_cooplevel_active_null(void)
{
    reset_state();
    g_passthru_active = TRUE;

    /* The bridge guards against NULL; wined3d override must not be called. */
    qemu3dfx_ddraw_cooplevel(NULL);

    ASSERT(mock_override_cooplevel_count == 0,
           "cooplevel: override not called with NULL pointer");
    ASSERT(1, "cooplevel: NULL pointer does not crash when active");
}

/* Blit — inactive ───────────────────────────────────────────────── */
static void test_blit_inactive(void)
{
    reset_state();
    qemu3dfx_ddraw_blit();
    ASSERT(mock_blit_call_count == 0,
           "blit: wined3d_blit_fpslimit not called when inactive");
}

/* Blit — active ─────────────────────────────────────────────────── */
static void test_blit_active(void)
{
    reset_state();
    g_passthru_active = TRUE;

    qemu3dfx_ddraw_blit();
    ASSERT(mock_blit_call_count == 1,
           "blit: wined3d_blit_fpslimit called once when active");

    qemu3dfx_ddraw_blit();
    ASSERT(mock_blit_call_count == 2,
           "blit: wined3d_blit_fpslimit called on every blit");
}

/* Flip — inactive ───────────────────────────────────────────────── */
static void test_flip_inactive(void)
{
    reset_state();
    qemu3dfx_ddraw_flip();
    ASSERT(mock_flip_call_count == 0,
           "flip: wined3d_flip_fpslimit not called when inactive");
}

/* Flip — active ─────────────────────────────────────────────────── */
static void test_flip_active(void)
{
    reset_state();
    g_passthru_active = TRUE;

    qemu3dfx_ddraw_flip();
    ASSERT(mock_flip_call_count == 1,
           "flip: wined3d_flip_fpslimit called once when active");

    qemu3dfx_ddraw_flip();
    ASSERT(mock_flip_call_count == 2,
           "flip: wined3d_flip_fpslimit called on every flip");
}

/* RTV — inactive ────────────────────────────────────────────────── */
static void test_rtv_inactive(void)
{
    reset_state();
    void *dummy = (void *)0x1234;

    qemu3dfx_ddraw_rtv(dummy);

    ASSERT(mock_rtv_call_count == 0,
           "rtv: override not called when bridge inactive");
}

/* RTV — active, NULL view ───────────────────────────────────────── */
static void test_rtv_active_null_view(void)
{
    reset_state();
    g_passthru_active = TRUE;

    qemu3dfx_ddraw_rtv(NULL);

    ASSERT(mock_rtv_call_count == 0,
           "rtv: override not called with NULL view when active");
}

/* RTV — active, valid view ──────────────────────────────────────── */
static void test_rtv_active_valid_view(void)
{
    reset_state();
    g_passthru_active = TRUE;
    void *dummy = (void *)0x5678;

    qemu3dfx_ddraw_rtv(dummy);

    ASSERT(mock_rtv_call_count == 1,
           "rtv: wined3d_override_rendertarget_view called with valid view");
    ASSERT(mock_last_rtv == dummy,
           "rtv: correct view pointer forwarded");
}

/* ── Main ────────────────────────────────────────────────────────── */
int main(void)
{
    test_init_not_detected();
    test_init_detected();
    test_cooplevel_inactive();
    test_cooplevel_active();
    test_cooplevel_active_null();
    test_blit_inactive();
    test_blit_active();
    test_flip_inactive();
    test_flip_active();
    test_rtv_inactive();
    test_rtv_active_null_view();
    test_rtv_active_valid_view();

    printf("test_passthrough: %d passed, %d failed\n",
           g_tests_passed, g_tests_failed);
    return g_tests_failed > 0 ? 1 : 0;
}
