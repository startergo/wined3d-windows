#include <stdarg.h>
#include <stddef.h>
struct __wine_debug_channel{unsigned char flags;unsigned char name[15];};
enum __wine_debug_class{__WINE_DBCL_FIXME,__WINE_DBCL_ERR,__WINE_DBCL_WARN,__WINE_DBCL_TRACE};
unsigned char __wine_dbg_get_channel_flags(struct __wine_debug_channel *ch){return 0;}
int __wine_dbg_header(enum __wine_debug_class c,struct __wine_debug_channel *ch,const char *fn){return -1;}
int wine_dbg_log(enum __wine_debug_class c,struct __wine_debug_channel *ch,const char *fn,const char *fmt,...){return 0;}
int wine_dbg_vlog(enum __wine_debug_class c,struct __wine_debug_channel *ch,const char *fn,const char *fmt,va_list ap){return 0;}
int wine_dbg_printf(const char *fmt,...){return 0;}
const char *wine_dbg_sprintf(const char *fmt,...){return "";}
int wine_dbg_vsprintf(char *buf,size_t sz,const char *fmt,va_list ap){if(buf&&sz)buf[0]=0;return 0;}
int wine_dbg_vprintf(const char *fmt,va_list ap){return 0;}
const char *wine_dbgstr_an(const char *s,int n){return s?"":"";}
const char *wine_dbgstr_wn(const wchar_t *s,int n){return s?"":"";}
const char *wine_get_version(void){return "wine-stubs";}
const char *wine_get_config_dir(void){return "";}
const char *wine_get_data_dir(void){return "";}
static unsigned short _cmap[128];
unsigned short *wine_casemap_ascii=_cmap;
unsigned short wine_tolower(unsigned short c){return(c>=65&&c<=90)?c+32:c;}
unsigned short wine_toupper(unsigned short c){return(c>=97&&c<=122)?c-32:c;}
int atexit(void(*f)(void)){return 0;}

/* Wine SEH stub — __wine_setjmpex is used by __TRY/__EXCEPT_PAGE_FAULT in ddraw.
   On Win98 we can't do software SEH — returning 0 means "no exception occurred",
   so the __TRY body always runs normally and the __EXCEPT handler is never entered.
   This is safe: the page-fault __EXCEPT blocks in ddraw just catch bad surface
   pointers, which would crash on Win98 regardless. */
int __cdecl __attribute__((__nothrow__,__returns_twice__))
__wine_setjmpex(void *buf, void *frame)
{
    return 0;
}
