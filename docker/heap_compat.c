/* Heap + CRT compat — provides malloc/free/calloc/realloc/memset/memcpy
   and CRT stubs using kernel32 HeapAlloc/HeapFree, so DLLs don't pull
   CRT startup from msvcrt.dll. Avoids CRT heap initialization issues on Win98. */
#include <stddef.h>

/* These functions ARE memset/memcpy/strlen/...: stop GCC from recognising
 * their loops and replacing them with calls to the same function, which
 * recursed until the stack overflowed (memset and strlen in ddraw.dll crashed
 * 3DMark 99 with an invalid page fault). */
#pragma GCC optimize("no-tree-loop-distribute-patterns")

void *__stdcall GetProcessHeap(void);
void *__stdcall HeapAlloc(void *heap, unsigned long flags, unsigned long size);
int   __stdcall HeapFree(void *heap, unsigned long flags, void *ptr);
void *__stdcall HeapReAlloc(void *heap, unsigned long flags, void *ptr, unsigned long size);

void *malloc(size_t size)
{
    return HeapAlloc(GetProcessHeap(), 0, size);
}

void free(void *ptr)
{
    if (ptr) HeapFree(GetProcessHeap(), 0, ptr);
}

void *calloc(size_t num, size_t size)
{
    size_t total = num * size;
    return HeapAlloc(GetProcessHeap(), 0x00000008, total);
}

void *realloc(void *ptr, size_t size)
{
    if (!ptr) return HeapAlloc(GetProcessHeap(), 0, size);
    if (size == 0) { HeapFree(GetProcessHeap(), 0, ptr); return 0; }
    return HeapReAlloc(GetProcessHeap(), 0, ptr, size);
}

void *memset(void *s, int c, size_t n)
{
    unsigned char *p = (unsigned char *)s;
    while (n--) *p++ = (unsigned char)c;
    return s;
}

void *memcpy(void *dest, const void *src, size_t n)
{
    unsigned char *d = (unsigned char *)dest;
    const unsigned char *s = (const unsigned char *)src;
    while (n--) *d++ = *s++;
    return dest;
}

/* CRT stubs — prevent pulling CRT startup from msvcrt.dll */
static int _fake_errno;
int *__cdecl _errno(void) { return &_fake_errno; }

static unsigned char _fake_iob[3][0x40];
void *__cdecl __p__iob(void) { return _fake_iob; }

void __cdecl __setusermatherr(void *f) { }
void __cdecl _initterm(void *a, void *b) { }
void __cdecl _lock(int n) { }
void __cdecl _unlock(int n) { }
void __cdecl abort(void) { for (;;); }

char *__cdecl _strdup(const char *s)
{
    size_t len = 0;
    const char *p = s;
    while (*p++) len++;
    char *d = (char *)malloc(len + 1);
    if (d) { for (size_t i = 0; i <= len; i++) d[i] = s[i]; }
    return d;
}

int __cdecl bsearch(const void *key, const void *base, size_t nmemb, size_t size,
                    int (*cmp)(const void *, const void *))
{
    const char *lo = (const char *)base;
    const char *hi = lo + nmemb * size;
    while (lo < hi) {
        size_t mid_idx = ((hi - lo) / size) / 2;
        const char *mid = lo + mid_idx * size;
        int r = cmp(key, mid);
        if (r == 0) return (int)(size_t)mid;
        if (r < 0) hi = mid;
        else lo = mid + size;
    }
    return 0;
}

/* String functions — avoid msvcrt dependency */
size_t __cdecl strlen(const char *s)
{
    size_t n = 0;
    while (*s++) n++;
    return n;
}

int __cdecl strcmp(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return (unsigned char)*a - (unsigned char)*b;
}

int __cdecl strncmp(const char *a, const char *b, size_t n)
{
    while (n && *a && *a == *b) { a++; b++; n--; }
    return n ? (unsigned char)*a - (unsigned char)*b : 0;
}

char *__cdecl strcpy(char *d, const char *s)
{
    char *r = d;
    while ((*d++ = *s++));
    return r;
}

char *__cdecl strchr(const char *s, int c)
{
    while (*s) { if (*s == (char)c) return (char *)s; s++; }
    return c == 0 ? (char *)s : 0;
}

size_t __cdecl strcspn(const char *s, const char *reject)
{
    size_t n = 0;
    while (*s) {
        const char *r = reject;
        while (*r) { if (*s == *r) return n; r++; }
        s++; n++;
    }
    return n;
}

int __cdecl memcmp(const void *a, const void *b, size_t n)
{
    const unsigned char *pa = a, *pb = b;
    while (n--) { if (*pa != *pb) return *pa - *pb; pa++; pb++; }
    return 0;
}

void *__cdecl memmove(void *dest, const void *src, size_t n)
{
    unsigned char *d = (unsigned char *)dest;
    const unsigned char *s = (const unsigned char *)src;
    if (d < s) { while (n--) *d++ = *s++; }
    else { d += n; s += n; while (n--) *--d = *--s; }
    return dest;
}

int __cdecl isalpha(int c) { return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'); }
int __cdecl isprint(int c) { return c >= 0x20 && c <= 0x7e; }
int __cdecl isspace(int c) { return c == ' ' || (c >= 9 && c <= 13); }
int __cdecl isupper(int c) { return c >= 'A' && c <= 'Z'; }

/* Minimal sprintf — handles %s, %d, %x, %c, %% */
/* printf family: msvcrt's real _vsnprintf, resolved at runtime.
 * This used to be a hand-written formatter knowing only %s %d %u %x %c %p
 * (no flags, widths, precision or length modifiers; unknown specifiers
 * consumed no argument and shifted the rest) - why the debug log printed
 * "%#x" literally. These DLLs do not link msvcrt, but Win98 always has it. */
#include <stdarg.h>
void *__stdcall LoadLibraryA(const char *name);
void *__stdcall GetProcAddress(void *module, const char *name);

typedef int (__cdecl *vsnprintf_fn)(char *, unsigned int, const char *, va_list);

static vsnprintf_fn crt_vsnprintf(void)
{
    static vsnprintf_fn fn;
    if (!fn)
        fn = (vsnprintf_fn)GetProcAddress(LoadLibraryA("msvcrt.dll"), "_vsnprintf");
    return fn;
}

int __cdecl _vsnprintf(char *buf, unsigned int count, const char *fmt, va_list ap)
{
    vsnprintf_fn fn = crt_vsnprintf();
    if (!fn)
    {
        if (count) buf[0] = 0;
        return -1;
    }
    return fn(buf, count, fmt, ap);
}

int __cdecl vsnprintf(char *buf, unsigned int count, const char *fmt, va_list ap)
{
    return _vsnprintf(buf, count, fmt, ap);
}

int __cdecl sprintf(char *buf, const char *fmt, ...)
{
    va_list ap;
    int n;

    va_start(ap, fmt);
    n = _vsnprintf(buf, 0x7fffffff, fmt, ap);
    va_end(ap);
    return n;
}

/* Stub I/O — Wine ddraw debug output, not needed at runtime */
int __cdecl _write(int fd, const void *buf, unsigned int count) { return count; }
int __cdecl fwrite(const void *ptr, unsigned int size, unsigned int count, void *stream) { return count; }
int __cdecl vfprintf(void *stream, const char *fmt, void *ap) { return 0; }
char *__cdecl getenv(const char *name) { return 0; }

/* Aliases without underscore — compact/debug.c calls these POSIX names directly.
   Without msvcrt, the MinGW name-mangling that maps strdup→_strdup is absent. */
char *__cdecl strdup(const char *s) { return _strdup(s); }
int __cdecl write(int fd, const void *buf, unsigned int count) { return _write(fd, buf, count); }

/* Math — sqrtf without libm/msvcrt */
float __cdecl sqrtf(float x) { __asm__("fsqrt" : "+t"(x)); return x; }

/* _setjmp3 / longjmp — MSVC-compatible for Wine SEH (__TRY/__EXCEPT).
   jmp_buf layout: [EBP, EBX, EDI, ESI, ESP, EIP] = 6 x 4 = 24 bytes.
   Second param (context) ignored — no SEH unwinding needed. */
__asm__("\n"
    ".globl __setjmp3\n"
    "__setjmp3:\n"
    "    movl 4(%esp), %ecx\n"
    "    movl %ebp, (%ecx)\n"
    "    movl %ebx, 4(%ecx)\n"
    "    movl %edi, 8(%ecx)\n"
    "    movl %esi, 12(%ecx)\n"
    "    movl %esp, 16(%ecx)\n"
    "    movl (%esp), %eax\n"
    "    movl %eax, 20(%ecx)\n"
    "    xorl %eax, %eax\n"
    "    ret\n"
    "\n"
    ".globl _longjmp\n"
    "_longjmp:\n"
    "    movl 4(%esp), %ecx\n"
    "    movl 8(%esp), %eax\n"
    "    testl %eax, %eax\n"
    "    jnz 1f\n"
    "    movl $1, %eax\n"
    "1:\n"
    "    movl (%ecx), %ebp\n"
    "    movl 4(%ecx), %ebx\n"
    "    movl 8(%ecx), %edi\n"
    "    movl 12(%ecx), %esi\n"
    "    movl 16(%ecx), %esp\n"
    "    movl 20(%ecx), %edx\n"
    "    movl %edx, (%esp)\n"
    "    ret\n"
);

/* Import stubs — force our implementations to win over msvcrt.dll.
   MinGW headers use __declspec(dllimport) for CRT functions, generating
   __imp_ references. Without these stubs, the linker resolves them from
   msvcrt.dll's import library instead of our definitions. */
__asm__("\n"
    ".section .rdata,\"dr\"\n"
    ".align 4\n"
    ".globl __imp___p__iob\n"
    "__imp___p__iob:\n"
    "    .long ___p__iob\n"
    ".globl __imp___errno\n"
    ".align 4\n"
    "__imp___errno:\n"
    "    .long __errno\n"
    ".globl __imp___strdup\n"
    ".align 4\n"
    "__imp___strdup:\n"
    "    .long __strdup\n"
    ".globl __imp___vsnprintf\n"
    ".align 4\n"
    "__imp___vsnprintf:\n"
    "    .long __vsnprintf\n"
    ".globl __imp___write\n"
    ".align 4\n"
    "__imp___write:\n"
    "    .long __write\n"
    ".globl __imp__isalpha\n"
    ".align 4\n"
    "__imp__isalpha:\n"
    "    .long _isalpha\n"
    ".globl __imp__isprint\n"
    ".align 4\n"
    "__imp__isprint:\n"
    "    .long _isprint\n"
    ".globl __imp__isspace\n"
    ".align 4\n"
    "__imp__isspace:\n"
    "    .long _isspace\n"
    ".globl __imp__isupper\n"
    ".align 4\n"
    "__imp__isupper:\n"
    "    .long _isupper\n"
    ".globl __imp___setjmp3\n"
    ".align 4\n"
    "__imp___setjmp3:\n"
    "    .long __setjmp3\n"
    ".globl __imp__longjmp\n"
    ".align 4\n"
    "__imp__longjmp:\n"
    "    .long _longjmp\n"
    ".text\n"
);
