#!/bin/bash
SELFDIR="$(cd "$(dirname "$0")" && pwd)"
ROOTDIR="$(cd "$SELFDIR/../.." && pwd)"
STUB="$ROOTDIR/lib/libwine.a"
args=()
compile_only=0
for arg in "$@"; do
    case "$arg" in
        -c)           compile_only=1; args+=("$arg") ;;
        -E|-S)        compile_only=1; args+=("$arg") ;;
        -lwine)       args+=("$STUB") ;;
        -lucrtbase)   args+=("-lmsvcrt") ;;
        *)            args+=("$arg") ;;
    esac
done
if [ $compile_only -eq 0 ]; then
    args+=(-mcrtdll=msvcrt)
    args+=(-Xlinker --exclude-symbols -Xlinker _wine_k32compat_GMHEW@12,__imp__wine_k32compat_GMHEW@12,_GlobalMemoryStatusEx@4,__imp__GlobalMemoryStatusEx@4,_RtlIsCriticalSectionLockedByThread@4,__imp__RtlIsCriticalSectionLockedByThread@4,_InitOnceExecuteOnce@16,__imp__InitOnceExecuteOnce@16,_InitializeConditionVariable@4,__imp__InitializeConditionVariable@4,_WakeConditionVariable@4,__imp__WakeConditionVariable@4,_WakeAllConditionVariable@4,__imp__WakeAllConditionVariable@4,_SleepConditionVariableCS@12,__imp__SleepConditionVariableCS@12,_SetThreadDescription@8,__imp__SetThreadDescription@8,_copysignf,__imp___copysignf,floor,__imp__floor,floorf,__imp__floorf,_fdclass,__imp___fdclass,_dclass,__imp___dclass,_dsign,__imp___dsign,_fdsign,__imp___fdsign,__acrt_iob_func,__imp____acrt_iob_func,__stdio_common_vsprintf,__imp____stdio_common_vsprintf,__stdio_common_vfprintf,__imp____stdio_common_vfprintf,__stdio_common_vsscanf,__imp____stdio_common_vsscanf,atoi,atol,abs,isprint,isdigit,isalpha,isalnum,isspace,isupper,islower,isxdigit,iscntrl,isgraph,ispunct,memcmp,__imp__memcmp,memchr,__imp__memchr,memcpy,__imp__memcpy,memset,__imp__memset,memmove,__imp__memmove,strlen,__imp__strlen,strcpy,__imp__strcpy,strcat,__imp__strcat,strcmp,__imp__strcmp,strncmp,__imp__strncmp,strchr,__imp__strchr,strrchr,__imp__strrchr,strstr,__imp__strstr,strcspn,__imp__strcspn,strnlen,__imp__strnlen,exp,__imp__exp,log,__imp__log,pow,__imp__pow,sprintf,__imp__sprintf,fprintf,__imp__fprintf,strtoul,__imp__strtoul,getc,__imp__getc,ungetc,__imp__ungetc,__lc_codepage,__imp____lc_codepage,_fstat32,__imp___fstat32,_initterm,__imp___initterm,_initterm_e,__imp___initterm_e,_wine_k32compat_EDD_W@16,__imp__wine_k32compat_EDD_W@16,_wine_k32compat_EDS_W@12,__imp__wine_k32compat_EDS_W@12,_wine_k32compat_EDSE_W@16,__imp__wine_k32compat_EDSE_W@16,_wine_k32compat_GMI_W@8,__imp__wine_k32compat_GMI_W@8,_wine_k32compat_EDM@16,__imp__wine_k32compat_EDM@16,_wine_k32compat_MFW@8,__imp__wine_k32compat_MFW@8,_wine_k32compat_MFP@12,__imp__wine_k32compat_MFP@12,_wine_k32compat_CDSE_W@20,__imp__wine_k32compat_CDSE_W@20,_wine_k32compat_IBSP_W@8,__imp__wine_k32compat_IBSP_W@8,_wine_k32compat_FLAET@8,__imp__wine_k32compat_FLAET@8)
    # Belt-and-suspenders: force static linking for any remaining -lwine
    new_args=()
    for a in "${args[@]}"; do
        if [ "$a" = "-lwine" ]; then
            new_args+=(-Wl,-Bstatic "$STUB" -Wl,-Bdynamic)
        else
            new_args+=("$a")
        fi
    done
    args=("${new_args[@]}")
fi
exec "$SELFDIR/winegcc.bin" "${args[@]}"
