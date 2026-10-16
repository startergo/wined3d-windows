/* InitOnceExecuteOnce for Windows 98 (KERNEL32 has it from Vista on).
 *
 * vkd3d-shader calls it through the import table, so besides the function we
 * provide the __imp_ pointer the call goes through. State lives in the
 * INIT_ONCE pointer: 0 = not run, 1 = running (others yield), 2 = done.
 * lock cmpxchg is inline - no further import. */
typedef int BOOL;
typedef union { void *Ptr; } INIT_ONCE;
typedef BOOL (__attribute__((stdcall)) *PINIT_ONCE_FN)(INIT_ONCE *, void *, void **);
__attribute__((dllimport, stdcall)) void Sleep(unsigned long ms);

__attribute__((stdcall)) BOOL compat_InitOnceExecuteOnce(INIT_ONCE *once, PINIT_ONCE_FN fn,
        void *param, void **context)
{
    volatile long *state = (volatile long *)&once->Ptr;

    for (;;)
    {
        long v = __sync_val_compare_and_swap(state, 0, 1);

        if (v == 0)
        {
            BOOL ok = fn(once, param, context);
            __sync_synchronize();
            *state = ok ? 2 : 0;
            return ok;
        }
        if (v == 2)
            return 1;
        Sleep(0);
    }
}

__asm__(".section .rdata,\"dr\"\n"
        ".align 4\n"
        ".globl __imp__InitOnceExecuteOnce@16\n"
        "__imp__InitOnceExecuteOnce@16:\n"
        "    .long _compat_InitOnceExecuteOnce@16\n"
        ".text\n");
