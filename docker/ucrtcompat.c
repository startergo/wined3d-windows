/* UCRT compat stubs — these are provided per-DLL via kernel32_compat.c.
   This file only provides functions NOT already covered there. */
typedef unsigned long long _u64;
typedef unsigned int _size;
typedef void *_locale;
typedef char _va_list_tag[4];
typedef void FILE;
typedef unsigned short wchar_t;
int __cdecl _vsnwprintf(wchar_t*,_size,const wchar_t*,...);
int __cdecl __stdio_common_vsprintf_s(_u64 o,char *b,_size n,const char *f,_locale l,_va_list_tag *a){ return 0; }
int __cdecl __stdio_common_vsprintf_p(_u64 o,char *b,_size n,const char *f,_locale l,_va_list_tag *a){ return 0; }
int __cdecl __stdio_common_vsnprintf_s(_u64 o,char *b,_size n,_size c,const char *f,_locale l,_va_list_tag *a){ return 0; }
int __cdecl __stdio_common_vfprintf(_u64 o,FILE *p,const char *f,_locale l,_va_list_tag *a){ return 0; }
int __cdecl __stdio_common_vfprintf_s(_u64 o,FILE *p,const char *f,_locale l,_va_list_tag *a){ return 0; }
int __cdecl __stdio_common_vfscanf(_u64 o,FILE *p,const char *f,_locale l,_va_list_tag *a){ return -1; }
int __cdecl __stdio_common_vsscanf(_u64 o,const char *s,_size n,const char *f,_locale l,_va_list_tag *a){ return -1; }
int __cdecl __stdio_common_vswprintf(_u64 o,wchar_t *b,_size n,const wchar_t *f,_locale l,_va_list_tag *a){ return _vsnwprintf(b,n==((_size)-1)?0x7fffffff:n,f,*(void**)a); }
int __cdecl __stdio_common_vswprintf_s(_u64 o,wchar_t *b,_size n,const wchar_t *f,_locale l,_va_list_tag *a){ return _vsnwprintf(b,n,f,*(void**)a); }
int __cdecl __stdio_common_vswprintf_p(_u64 o,wchar_t *b,_size n,const wchar_t *f,_locale l,_va_list_tag *a){ return _vsnwprintf(b,n,f,*(void**)a); }
int __cdecl __stdio_common_vsnwprintf_s(_u64 o,wchar_t *b,_size n,_size c,const wchar_t *f,_locale l,_va_list_tag *a){ return _vsnwprintf(b,c<n?c:n,f,*(void**)a); }
int __cdecl __stdio_common_vfwprintf(_u64 o,FILE *p,const wchar_t *f,_locale l,_va_list_tag *a){ return 0; }
int __cdecl __stdio_common_vfwprintf_s(_u64 o,FILE *p,const wchar_t *f,_locale l,_va_list_tag *a){ return 0; }
__asm__("\n"
    ".globl __imp____stdio_common_vfprintf\n"
    ".section .rdata,\"dr\"\n"
    ".align 4\n"
    "__imp____stdio_common_vfprintf:\n"
    "    .long ___stdio_common_vfprintf\n"
    ".globl __imp____stdio_common_vsscanf\n"
    ".align 4\n"
    "__imp____stdio_common_vsscanf:\n"
    "    .long ___stdio_common_vsscanf\n"
    ".text\n"
);
