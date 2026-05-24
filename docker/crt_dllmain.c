/*
 * DllMainCRTStartup replacement — bypasses MinGW CRT init.
 *
 * MinGW's DllMainCRTStartup calls _initterm/_lock/_unlock which
 * crash on Win98's ancient msvcrt.dll.  This replacement simply
 * forwards to DllMain without any CRT initialization.
 *
 * Based on Wine 8.0.2 dlls/winecrt0/crt_dllmain.c
 * Copyright 2019 Jacek Caban for CodeWeavers
 */

#include <stdarg.h>
#include "windef.h"
#include "winbase.h"

extern BOOL WINAPI DllMain( HINSTANCE inst, DWORD reason, void *reserved );

BOOL WINAPI DllMainCRTStartup( HINSTANCE inst, DWORD reason, void *reserved )
{
    return DllMain( inst, reason, reserved );
}
