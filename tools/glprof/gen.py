#!/usr/bin/env python3
"""gen.py exports.txt outdir — generate the GL call profiler (opengl32 proxy).

The proxy forwards every export to the real wrapper (glreal.dll) through a
counting stub, hands out the same stubs from wglGetProcAddress, logs names it
cannot resolve, and on SwapBuffers/wglSwapBuffers writes the frame's
non-zero call counts to COM1 (frames 1-5, then every 50th up to 400)."""
import os, sys

names = [l.strip() for l in open(sys.argv[1]) if l.strip()]
out = sys.argv[2]
N = len(names)

asm = ['.text']
for i, n in enumerate(names):
    if n in ('wglGetProcAddress', 'SwapBuffers', 'wglSwapBuffers'):
        continue
    asm += ['.globl _stub_%d' % i, '_stub_%d:' % i,
            '    incl _counts+%d' % (4 * i),
            '    jmp *_real+%d' % (4 * i)]
open(os.path.join(out, 'stubs.s'), 'w').write('\n'.join(asm) + '\n')

c = ['#include <windows.h>',
     '#define N %d' % N,
     'unsigned long counts[N];',
     'void *real[N];',
     'static const char *const names[N] = {']
c += ['    "%s",' % n for n in names]
c += ['};']
c += ['static const unsigned short idx_wglGetProcAddress = %d, idx_SwapBuffers = %d, idx_wglSwapBuffers = %d;'
      % (names.index('wglGetProcAddress'), names.index('SwapBuffers'), names.index('wglSwapBuffers'))]
c += ['extern void %s(void);' % ('stub_%d' % i) for i, n in enumerate(names)
      if n not in ('wglGetProcAddress', 'SwapBuffers', 'wglSwapBuffers')]
order = sorted(range(N), key=lambda i: names[i].encode())
c += ['static const unsigned short sorted[N] = {' + ','.join(str(i) for i in order) + '};']
c += ['static void *const stubs[N] = {']
c += ['    %s,' % ('(void *)stub_%d' % i if n not in ('wglGetProcAddress', 'SwapBuffers', 'wglSwapBuffers') else '0')
      for i, n in enumerate(names)]
c += ['};']
c += [r'''
#pragma GCC optimize("no-tree-loop-distribute-patterns")
static HMODULE real_dll;
static unsigned long frame;

static void com1(const char *s, DWORD n)
{
    DWORD w;
    HANDLE h = CreateFileA("COM1", GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);
    if (h != INVALID_HANDLE_VALUE) { WriteFile(h, s, n, &w, NULL); CloseHandle(h); }
}

static int my_strcmp(const char *a, const char *b)
{
    while (*a && *a == *b) { ++a; ++b; }
    return (unsigned char)*a - (unsigned char)*b;
}

static void dump(void)
{
    static char buf[8192];
    int n = 0, i;

    ++frame;
    if (frame <= 5 || (frame % 50 == 0 && frame <= 400))
    {
        n = wsprintfA(buf, "FRAME %lu:", frame);
        for (i = 0; i < N; ++i)
        {
            if (!counts[i]) continue;
            if (n > (int)sizeof(buf) - 80) { com1(buf, n); n = 0; }
            n += wsprintfA(buf + n, " %s=%lu", names[i], counts[i]);
        }
        buf[n++] = '\r'; buf[n++] = '\n';
        com1(buf, n);
    }
    for (i = 0; i < N; ++i) counts[i] = 0;
}

typedef PROC (WINAPI *gpa_t)(LPCSTR);
typedef BOOL (WINAPI *swap_t)(HDC);

PROC WINAPI my_wglGetProcAddress(LPCSTR name)
{
    PROC p = ((gpa_t)real[idx_wglGetProcAddress])(name);
    int i;
    char buf[160];

    {   /* binary search in the sorted index */
        int lo = 0, hi = N - 1;
        while (lo <= hi)
        {
            int mid = (lo + hi) / 2, c = my_strcmp(names[sorted[mid]], name);
            if (!c) { i = sorted[mid]; return stubs[i] ? (p ? (PROC)stubs[i] : NULL) : p; }
            if (c < 0) lo = mid + 1; else hi = mid - 1;
        }
    }
    com1(buf, wsprintfA(buf, "GPA %s -> %s (not exported)\r\n", name, p ? "ptr" : "NULL"));
    return p;
}

BOOL WINAPI my_SwapBuffers(HDC dc)
{
    ++counts[idx_SwapBuffers];
    dump();
    return ((swap_t)real[idx_SwapBuffers])(dc);
}

BOOL WINAPI my_wglSwapBuffers(HDC dc)
{
    ++counts[idx_wglSwapBuffers];
    dump();
    return ((swap_t)real[idx_wglSwapBuffers])(dc);
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, void *reserved)
{
    int i;
    if (reason == DLL_PROCESS_ATTACH)
    {
        char path[MAX_PATH], *s, buf[128];
        GetModuleFileNameA(inst, path, sizeof(path));
        for (s = path + lstrlenA(path); s > path && s[-1] != '\\'; --s) ;
        lstrcpyA(s, "glreal.dll");
        if (!(real_dll = LoadLibraryA(path))) { com1("glprof: glreal.dll not found\r\n", 31); return FALSE; }
        for (i = 0; i < N; ++i) real[i] = (void *)GetProcAddress(real_dll, names[i]);
        com1(buf, wsprintfA(buf, "glprof: %d exports forwarded\r\n", N));
    }
    return TRUE;
}
''']
open(os.path.join(out, 'glprof.c'), 'w').write('\n'.join(c))

d = ['LIBRARY opengl32', 'EXPORTS']
for i, n in enumerate(names):
    if n == 'wglGetProcAddress': d.append('    %s=my_wglGetProcAddress@4' % n)
    elif n == 'SwapBuffers': d.append('    %s=my_SwapBuffers@4' % n)
    elif n == 'wglSwapBuffers': d.append('    %s=my_wglSwapBuffers@4' % n)
    else: d.append('    %s=stub_%d' % (n, i))
open(os.path.join(out, 'glprof.def'), 'w').write('\n'.join(d) + '\n')
print('generated %d stubs' % N)
