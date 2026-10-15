/*
 * mingw_matherr_stubs.c — no-op stubs for MinGW internal CRT symbols
 *
 * When linking wined3d.dll with -nostdlib -nodefaultlibs, MinGW's libmsvcrt.a
 * math wrappers (cos, pow, sqrtf etc.) reference __mingw_raise_matherr from
 * libmingwex.a, which in turn pulls in _vsnprintf/_vscprintf from msvcrt,
 * creating a circular dependency that cannot be resolved with -nostdlib.
 *
 * Solution: provide no-op stubs here so the linker resolves these symbols
 * from this object file instead, breaking the circular dependency entirely.
 * wined3d on Win98 never triggers math error handling, so these are safe.
 */

#include <stdarg.h>

/* Called by MinGW math wrappers on domain/range errors — not needed on Win98 */
void __mingw_raise_matherr(int type, const char *name,
                            double arg1, double arg2, double retval)
{
    (void)type; (void)name; (void)arg1; (void)arg2; (void)retval;
}

/* _vsnprintf / _vscprintf / __ms_vsnprintf — the real thing.
 *
 * These used to be stubs returning 0 without writing anything. wined3d
 * builds its GLSL shader source and uniform names with vsnprintf, so every
 * shader came out empty or garbled and 3D rendered black (the reference
 * imports msvcrt's _vsnprintf). Resolve msvcrt's _vsnprintf at runtime -
 * keeps the -nostdlib link free of the libmingwex/msvcrt cycle this file
 * exists to break, and works in DLLs that do not link msvcrt at all. */
#include <windows.h>

typedef int (__cdecl *vsnprintf_fn)(char *, unsigned int, const char *, va_list);

static vsnprintf_fn msvcrt_vsnprintf(void)
{
    static vsnprintf_fn fn;
    if (!fn)
        fn = (vsnprintf_fn)GetProcAddress(LoadLibraryA("msvcrt.dll"), "_vsnprintf");
    return fn;
}

int _vsnprintf(char *buf, unsigned int size, const char *fmt, va_list ap)
{
    vsnprintf_fn fn = msvcrt_vsnprintf();
    if (!fn)
    {
        if (size) buf[0] = 0;
        return -1;
    }
    return fn(buf, size, fmt, ap);
}

/* Length of the formatted text (msvcrt 6 on Win98 has no _vscprintf). */
int _vscprintf(const char *fmt, va_list ap)
{
    unsigned int size = 512;
    for (;;)
    {
        char *buf = HeapAlloc(GetProcessHeap(), 0, size);
        int n;
        va_list copy;

        if (!buf) return -1;
        va_copy(copy, ap);
        n = _vsnprintf(buf, size, fmt, copy);
        va_end(copy);
        HeapFree(GetProcessHeap(), 0, buf);
        if (n >= 0 && (unsigned int)n < size) return n;
        if (size >= 64 * 1024 * 1024) return -1;
        size *= 2;
    }
}

/* __logl_internal — called by MinGW's log() wrapper in libmsvcrt.a.
 * Uses x87 FPU directly to avoid depending on msvcrt's log(). */
double __logl_internal(double x)
{
    __asm__("fldln2; fxch; fyl2x" : "+t"(x));
    return x;
}

/* __ms_vsnprintf — what MinGW's vsnprintf wrapper in libmsvcrt.a calls */
int __ms_vsnprintf(char *buf, unsigned int size, const char *fmt, va_list ap)
{
    return _vsnprintf(buf, size, fmt, ap);
}
