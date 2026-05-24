
/* __stdio_common_* stubs for Wine 6.x */
int CDECL __stdio_common_vsprintf(unsigned __int64 o,
    char *s, size_t n, const char *f, _locale_t l, __ms_va_list a)
{ return _vsnprintf(s, n==(size_t)-1?0x7fffffff:n, f, a); }
int CDECL __stdio_common_vsprintf_s(unsigned __int64 o,
    char *s, size_t n, const char *f, _locale_t l, __ms_va_list a)
{ return _vsnprintf(s, n, f, a); }
int CDECL __stdio_common_vsprintf_p(unsigned __int64 o,
    char *s, size_t n, const char *f, _locale_t l, __ms_va_list a)
{ return _vsnprintf(s, n, f, a); }
int CDECL __stdio_common_vsnprintf_s(unsigned __int64 o,
    char *s, size_t n, size_t c, const char *f, _locale_t l, __ms_va_list a)
{ return _vsnprintf(s, c<n?c:n, f, a); }
int CDECL __stdio_common_vfprintf(unsigned __int64 o,
    FILE *fp, const char *f, _locale_t l, __ms_va_list a)
{ return _vsnprintf(NULL,0,f,a); }
int CDECL __stdio_common_vfprintf_s(unsigned __int64 o,
    FILE *fp, const char *f, _locale_t l, __ms_va_list a)
{ return _vsnprintf(NULL,0,f,a); }
int CDECL __stdio_common_vswprintf(unsigned __int64 o,
    wchar_t *s, size_t n, const wchar_t *f, _locale_t l, __ms_va_list a)
{ return _vsnwprintf(s, n==(size_t)-1?0x7fffffff:n, f, a); }
int CDECL __stdio_common_vswprintf_s(unsigned __int64 o,
    wchar_t *s, size_t n, const wchar_t *f, _locale_t l, __ms_va_list a)
{ return _vsnwprintf(s, n, f, a); }
int CDECL __stdio_common_vswprintf_p(unsigned __int64 o,
    wchar_t *s, size_t n, const wchar_t *f, _locale_t l, __ms_va_list a)
{ return _vsnwprintf(s, n, f, a); }
int CDECL __stdio_common_vsnwprintf_s(unsigned __int64 o,
    wchar_t *s, size_t n, size_t c, const wchar_t *f, _locale_t l, __ms_va_list a)
{ return _vsnwprintf(s, c<n?c:n, f, a); }
int CDECL __stdio_common_vfwprintf(unsigned __int64 o,
    FILE *fp, const wchar_t *f, _locale_t l, __ms_va_list a)
{ return _vsnwprintf(NULL,0,f,a); }
int CDECL __stdio_common_vfwprintf_s(unsigned __int64 o,
    FILE *fp, const wchar_t *f, _locale_t l, __ms_va_list a)
{ return _vsnwprintf(NULL,0,f,a); }
