/*
 * d3d9on12.h for Win98 builds of Wine >= 11's d3d9.
 *
 * Wine generates this header from include/d3d9on12.idl with its IDL compiler,
 * which the build does not run. This is the same content written by hand:
 * D3D9ON12_ARGS, Direct3DCreate9On12 and the IDirect3DDevice9On12 interface
 * (uuid e7fda234-b589-4049-940d-8878977531c8). Direct3D 12 types are only
 * used through pointers, so they are forward-declared.
 */
#ifndef __D3D9ON12_H_WIN98__
#define __D3D9ON12_H_WIN98__

#include <d3d9.h>

typedef struct ID3D12CommandQueue ID3D12CommandQueue;
typedef struct ID3D12Fence ID3D12Fence;

#define MAX_D3D9ON12_QUEUES 2

typedef struct D3D9ON12_ARGS
{
    BOOL Enable9On12;
    IUnknown *pD3D12Device;
    IUnknown *ppD3D12Queues[MAX_D3D9ON12_QUEUES];
    UINT NumQueues;
    UINT NodeMask;
} D3D9ON12_ARGS;

typedef IDirect3D9 * (__stdcall *PFN_Direct3DCreate9On12)(UINT sdk_version,
        D3D9ON12_ARGS *d3d9on12_args, UINT d3d9on12_args_count);
IDirect3D9 * __stdcall Direct3DCreate9On12(UINT, D3D9ON12_ARGS *, UINT);

typedef struct IDirect3DDevice9On12 IDirect3DDevice9On12, *LPDIRECT3DDEVICE9ON12, *PDIRECT3DDEVICE9ON12;

typedef struct IDirect3DDevice9On12Vtbl
{
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(IDirect3DDevice9On12 *This, REFIID riid, void **out);
    ULONG (STDMETHODCALLTYPE *AddRef)(IDirect3DDevice9On12 *This);
    ULONG (STDMETHODCALLTYPE *Release)(IDirect3DDevice9On12 *This);
    HRESULT (STDMETHODCALLTYPE *GetD3D12Device)(IDirect3DDevice9On12 *This, REFIID riid, void **out);
    HRESULT (STDMETHODCALLTYPE *UnwrapUnderlyingResource)(IDirect3DDevice9On12 *This,
            IDirect3DResource9 *resource, ID3D12CommandQueue *queue, REFIID riid, void **out);
    HRESULT (STDMETHODCALLTYPE *ReturnUnderlyingResource)(IDirect3DDevice9On12 *This,
            IDirect3DResource9 *resource, UINT fence_count, UINT64 *signal_values, ID3D12Fence **fences);
} IDirect3DDevice9On12Vtbl;

struct IDirect3DDevice9On12
{
    const IDirect3DDevice9On12Vtbl *lpVtbl;
};

/* Defined here (static) rather than in a GUID library the build lacks. */
static const GUID IID_IDirect3DDevice9On12 =
        {0xe7fda234, 0xb589, 0x4049, {0x94, 0x0d, 0x88, 0x78, 0x97, 0x75, 0x31, 0xc8}};

#endif /* __D3D9ON12_H_WIN98__ */
