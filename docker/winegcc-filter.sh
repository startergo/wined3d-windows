#!/bin/bash
SELFDIR="$(cd "$(dirname "$0")" && pwd)"
ROOTDIR="$(cd "$SELFDIR/../.." && pwd)"
STUB="$ROOTDIR/libs/wine/wine-stubs.a"
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
    args+=(-nostartfiles)
    args+=(-mcrtdll=msvcrt)
    args+=(-lmsvcrt)
    args+=(-Wl,-S)
    args+=(-Wl,--kill-at)
    args+=(-Wl,--image-base=0x10000000)
    args+=(-Xlinker --exclude-symbols -Xlinker _wine_k32compat_GMHEW@12,__imp__wine_k32compat_GMHEW@12,_GlobalMemoryStatusEx@4,__imp__GlobalMemoryStatusEx@4,_RtlIsCriticalSectionLockedByThread@4,__imp__RtlIsCriticalSectionLockedByThread@4,_InitOnceExecuteOnce@16,__imp__InitOnceExecuteOnce@16,_InitializeConditionVariable@4,__imp__InitializeConditionVariable@4,_WakeConditionVariable@4,__imp__WakeConditionVariable@4,_WakeAllConditionVariable@4,__imp__WakeAllConditionVariable@4,_SleepConditionVariableCS@12,__imp__SleepConditionVariableCS@12,_SetThreadDescription@8,__imp__SetThreadDescription@8,floor,__imp__floor,floorf,__imp__floorf,_vsnprintf,__imp___vsnprintf,atoi,atol,abs,isprint,isdigit,isalpha,isalnum,isspace,isupper,islower,isxdigit,iscntrl,isgraph,ispunct,__acrt_iob_func,__imp____acrt_iob_func,_fdclass,__imp___fdclass,_dclass,__imp___dclass,_dsign,__imp___dsign,_fdsign,__imp___fdsign,__stdio_common_vsprintf,__imp____stdio_common_vsprintf,__stdio_common_vfprintf,__imp____stdio_common_vfprintf,__stdio_common_vsscanf,__imp____stdio_common_vsscanf,memcmp,__imp__memcmp,memchr,__imp__memchr,memcpy,__imp__memcpy,memset,__imp__memset,memmove,__imp__memmove,strlen,__imp__strlen,strcpy,__imp__strcpy,strcat,__imp__strcat,strcmp,__imp__strcmp,strncmp,__imp__strncmp,strchr,__imp__strchr,strrchr,__imp__strrchr,strstr,__imp__strstr,strcspn,__imp__strcspn,strnlen,__imp__strnlen,exp,__imp__exp,log,__imp__log,pow,__imp__pow,sprintf,__imp__sprintf,fprintf,__imp__fprintf,strtoul,__imp__strtoul,strtoll,strtoull,cosf,logf,powf,expf,sqrtf,getc,__imp__getc,ungetc,__imp__ungetc,__lc_codepage,__imp____lc_codepage,_fstat32,__imp___fstat32)
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
exec "$SELFDIR/winegcc" "${args[@]}"
