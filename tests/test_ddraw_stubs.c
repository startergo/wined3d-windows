/*
 * Unit tests for qemu3dfx_ddraw_hooks.c
 *
 * All 14 DirectDraw HAL stubs are no-ops that return 0 or NULL.
 * These tests verify each stub compiles and returns the expected value,
 * providing a baseline safety net against inadvertent future changes.
 *
 * Compile + run:
 *   make tests/run_test_ddraw_stubs && tests/run_test_ddraw_stubs
 */
#include "include/windows.h"
#include <stdio.h>

/* ── Pull in the unit under test ─────────────────────────────────── */
#include "../qemu3dfx_ddraw_hooks.c"

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

/* ── Tests ───────────────────────────────────────────────────────── */

static void test_ddhal32_vidmemalloc(void)
{
    ASSERT(DDHAL32_VidMemAlloc(NULL, 0, 0, 0) == 0,
           "DDHAL32_VidMemAlloc: returns 0");
    /* Non-zero arguments must also yield 0. */
    ASSERT(DDHAL32_VidMemAlloc((void *)1, 1, 640, 480) == 0,
           "DDHAL32_VidMemAlloc: returns 0 for non-zero args");
}

static void test_ddhal32_vidmemfree(void)
{
    /* void function — must not crash. */
    DDHAL32_VidMemFree(NULL, 0, 0);
    ASSERT(1, "DDHAL32_VidMemFree: does not crash with NULLs");
    DDHAL32_VidMemFree((void *)1, 2, 0xDEAD);
    ASSERT(1, "DDHAL32_VidMemFree: does not crash with arbitrary args");
}

static void test_dsoundhelp(void)
{
    ASSERT(DSoundHelp(NULL, NULL, 0) == 0,
           "DSoundHelp: returns 0");
}

static void test_getnextmipmap(void)
{
    ASSERT(GetNextMipMap(NULL) == NULL,
           "GetNextMipMap: returns NULL for NULL surface");
    ASSERT(GetNextMipMap((void *)1) == NULL,
           "GetNextMipMap: returns NULL for non-NULL surface");
}

static void test_heapvidmemallocalgined(void)
{
    ASSERT(HeapVidMemAllocAligned(NULL, 0, 0, NULL, NULL) == 0,
           "HeapVidMemAllocAligned: returns 0");
    ASSERT(HeapVidMemAllocAligned((void *)1, 320, 240, NULL, NULL) == 0,
           "HeapVidMemAllocAligned: returns 0 for non-zero args");
}

static void test_internallock(void)
{
    ASSERT(InternalLock(NULL, NULL, NULL, 0) == 0,
           "InternalLock: returns 0");
}

static void test_internalunlock(void)
{
    ASSERT(InternalUnlock(NULL, NULL, 0) == 0,
           "InternalUnlock: returns 0");
}

static void test_lateallocatesurfacemem(void)
{
    ASSERT(LateAllocateSurfaceMem(NULL, 0, 0, 0) == 0,
           "LateAllocateSurfaceMem: returns 0");
    ASSERT(LateAllocateSurfaceMem((void *)1, 1, 640, 480) == 0,
           "LateAllocateSurfaceMem: returns 0 for non-zero args");
}

static void test_vidmemalloc(void)
{
    ASSERT(VidMemAlloc(0, 0, NULL) == 0,
           "VidMemAlloc: returns 0");
    ASSERT(VidMemAlloc(0x1000, 4096, (void *)1) == 0,
           "VidMemAlloc: returns 0 for non-zero args");
}

static void test_vidmemamountfree(void)
{
    ASSERT(VidMemAmountFree(NULL) == 0,
           "VidMemAmountFree: returns 0 for NULL heap");
    ASSERT(VidMemAmountFree((void *)1) == 0,
           "VidMemAmountFree: returns 0 for non-NULL heap");
}

static void test_vidmemfini(void)
{
    /* void function — must not crash. */
    VidMemFini(NULL);
    ASSERT(1, "VidMemFini: does not crash with NULL");
}

static void test_vidmemfree(void)
{
    ASSERT(VidMemFree(NULL, 0) == 0,
           "VidMemFree: returns 0");
    ASSERT(VidMemFree((void *)1, 0xBEEF) == 0,
           "VidMemFree: returns 0 for non-zero args");
}

static void test_vidmeminit(void)
{
    ASSERT(VidMemInit(0, 0, 0, 0, 0) == NULL,
           "VidMemInit: returns NULL");
    ASSERT(VidMemInit(1, 0x1000, 0x2000, 480, 640) == NULL,
           "VidMemInit: returns NULL for non-zero args");
}

static void test_vidmemlargestfree(void)
{
    ASSERT(VidMemLargestFree(NULL) == 0,
           "VidMemLargestFree: returns 0 for NULL heap");
    ASSERT(VidMemLargestFree((void *)1) == 0,
           "VidMemLargestFree: returns 0 for non-NULL heap");
}

/* ── Main ────────────────────────────────────────────────────────── */
int main(void)
{
    test_ddhal32_vidmemalloc();
    test_ddhal32_vidmemfree();
    test_dsoundhelp();
    test_getnextmipmap();
    test_heapvidmemallocalgined();
    test_internallock();
    test_internalunlock();
    test_lateallocatesurfacemem();
    test_vidmemalloc();
    test_vidmemamountfree();
    test_vidmemfini();
    test_vidmemfree();
    test_vidmeminit();
    test_vidmemlargestfree();

    printf("test_ddraw_stubs: %d passed, %d failed\n",
           g_tests_passed, g_tests_failed);
    return g_tests_failed > 0 ? 1 : 0;
}
