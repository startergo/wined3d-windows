/* Stub D3DKMT functions — prevent static imports from gdi32.dll.
   These APIs only exist on Vista+. Returning failure causes wined3d
   to fall back to non-D3DKMT code paths (same as running on XP). */
typedef int NTSTATUS;
#define STATUS_UNSUCCESSFUL ((NTSTATUS)0xC0000001L)
#ifndef __stdcall
#define __stdcall __attribute__((stdcall))
#endif
NTSTATUS __stdcall D3DKMTCloseAdapter(const void *a){return STATUS_UNSUCCESSFUL;}
NTSTATUS __stdcall D3DKMTCreateDCFromMemory(void *a){return STATUS_UNSUCCESSFUL;}
NTSTATUS __stdcall D3DKMTCreateDevice(void *a){return STATUS_UNSUCCESSFUL;}
NTSTATUS __stdcall D3DKMTDestroyDCFromMemory(void *a){return STATUS_UNSUCCESSFUL;}
NTSTATUS __stdcall D3DKMTDestroyDevice(void *a){return STATUS_UNSUCCESSFUL;}
NTSTATUS __stdcall D3DKMTOpenAdapterFromGdiDisplayName(void *a){return STATUS_UNSUCCESSFUL;}
NTSTATUS __stdcall D3DKMTOpenAdapterFromLuid(void *a){return STATUS_UNSUCCESSFUL;}
NTSTATUS __stdcall D3DKMTQueryVideoMemoryInfo(void *a){return STATUS_UNSUCCESSFUL;}
NTSTATUS __stdcall D3DKMTSetVidPnSourceOwner(const void *a){return STATUS_UNSUCCESSFUL;}
