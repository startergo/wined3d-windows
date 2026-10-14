/*
 * D3DKMT for Win9x/ME — what wined3d needs from gdi32's kernel-mode thunks,
 * implemented on top of plain Win32 GDI.
 *
 * Wine >= 1.9 wined3d calls gdi32's D3DKMT* entry points, which only exist
 * on Vista+ (and in Wine).  The previous version of this file made every one
 * of them return STATUS_UNSUCCESSFUL, assuming wined3d would fall back to an
 * "XP path".  It does not: with Wine 5+ a failing D3DKMTOpenAdapterFromLuid /
 * D3DKMTOpenAdapterFromGdiDisplayName / D3DKMTCreateDevice makes
 * wined3d_adapter_init() / wined3d_output_init() fail, so no Direct3D adapter
 * is created at all; and a failing D3DKMTCreateDCFromMemory breaks every
 * surface/texture GetDC (Wine >= 1.9).
 *
 * This file follows the qemu-3dfx reference wined3d.dll (8.0.2 build at
 * 0x1004f9d6 .. 0x1004fc45; same code in 2.0.5 .. 7.0.2):
 *
 *   - D3DKMTCreateDCFromMemory / D3DKMTDestroyDCFromMemory are real: a GDI
 *     memory DC with a DIB section in the surface's format.  Win9x cannot
 *     wrap caller-owned memory in a DIB, so the surface bits are copied into
 *     the DIB on create and copied back on destroy (the reference keeps the
 *     same bookkeeping list).
 *   - The adapter/device/ownership calls succeed (STATUS_SUCCESS), and
 *     D3DKMTQueryVideoMemoryInfo returns STATUS_NOT_IMPLEMENTED so wined3d
 *     uses its "fake video memory info" fallback — exactly the reference's
 *     return values.
 *
 * Deliberate deviations from the reference (both marked below):
 *   1. The success stubs fill their output handles/LUIDs with fixed fake
 *      values; the reference leaves them uninitialised (stack garbage ends
 *      up in adapter->kmt_adapter, output->kmt_device, the primary LUID...).
 *   2. For P8 surfaces the caller's colour table is copied into the DIB
 *      (as gdi32 does).  The reference ignores pColorTable and builds only a
 *      52-byte BITMAPINFO on the stack, so CreateDIBSection reads its 256
 *      palette entries from whatever lies past that on the stack (shown by
 *      tests/emu/test_d3dkmt.py).  Build with
 *      -DQEMU3DFX_D3DKMT_REFERENCE_PALETTE to drop the palette copy (zeroed
 *      palette); the emulator tests use that build for bit-exact comparison.
 *
 * Verified against the reference with tests/emu (see tests/emu/README.md).
 */

#include <windows.h>
#include <string.h>

typedef LONG NTSTATUS;
typedef UINT D3DKMT_HANDLE;

#define STATUS_SUCCESS          ((NTSTATUS)0x00000000L)
#define STATUS_NOT_IMPLEMENTED  ((NTSTATUS)0xC0000002L)
#define STATUS_FAILURE          ((NTSTATUS)-1)          /* what the reference returns */

/* d3dkmthk.h layouts (32-bit) */
typedef struct
{
    void *pMemory;               /* 0x00 */
    UINT Format;                 /* 0x04  D3DDDIFORMAT */
    UINT Width;                  /* 0x08 */
    UINT Height;                 /* 0x0c */
    UINT Pitch;                  /* 0x10 */
    HDC hDeviceDc;               /* 0x14 */
    PALETTEENTRY *pColorTable;   /* 0x18 */
    HDC hDc;                     /* 0x1c  out */
    HANDLE hBitmap;              /* 0x20  out */
} D3DKMT_CREATEDCFROMMEMORY;

typedef struct
{
    HDC hDc;
    HANDLE hBitmap;
} D3DKMT_DESTROYDCFROMMEMORY;

typedef struct
{
    LUID AdapterLuid;
    D3DKMT_HANDLE hAdapter;      /* out */
} D3DKMT_OPENADAPTERFROMLUID;

typedef struct
{
    WCHAR DeviceName[32];
    D3DKMT_HANDLE hAdapter;      /* out */
    LUID AdapterLuid;            /* out */
    UINT VidPnSourceId;          /* out */
} D3DKMT_OPENADAPTERFROMGDIDISPLAYNAME;

typedef struct
{
    D3DKMT_HANDLE hAdapter;      /* union with void *pAdapter */
    UINT Flags;
    D3DKMT_HANDLE hDevice;       /* out */
    /* command buffer / allocation list fields follow, unused here */
} D3DKMT_CREATEDEVICE;

/* ------------------------------------------------------------------ */
/* DCs from memory                                                     */
/* ------------------------------------------------------------------ */

/* gdi32's format table (reference 8.0.2 @0x100f6ce0): D3DDDIFORMAT,
 * bit count, BI_* compression, palette size, R/G/B masks. */
static const struct
{
    UINT format;
    WORD bit_count;
    DWORD compression;
    UINT palette_size;
    DWORD mask_r, mask_g, mask_b;
}
dc_formats[] =
{
    { 20 /* R8G8B8   */, 24, BI_RGB,       0,   0,      0,     0    },
    { 21 /* A8R8G8B8 */, 32, BI_RGB,       0,   0,      0,     0    },
    { 22 /* X8R8G8B8 */, 32, BI_RGB,       0,   0,      0,     0    },
    { 23 /* R5G6B5   */, 16, BI_BITFIELDS, 0,   0xf800, 0x07e0, 0x001f },
    { 24 /* X1R5G5B5 */, 16, BI_BITFIELDS, 0,   0x7c00, 0x03e0, 0x001f },
    { 25 /* A1R5G5B5 */, 16, BI_BITFIELDS, 0,   0x7c00, 0x03e0, 0x001f },
    { 26 /* A4R4G4B4 */, 16, BI_BITFIELDS, 0,   0x0f00, 0x00f0, 0x000f },
    { 30 /* X4R4G4B4 */, 16, BI_BITFIELDS, 0,   0x0f00, 0x00f0, 0x000f },
    { 41 /* P8       */,  8, BI_RGB,       256, 0,      0,     0    },
};

/* One record per live DC, so destroy can copy the DIB back into the
 * caller's memory (reference: 0x18-byte HeapAlloc'd nodes, list head at
 * 0x101450b0, appended at the tail). */
struct dc_record
{
    struct dc_record *next;
    HDC hdc;
    HBITMAP bitmap;
    SIZE_T size;
    void *memory;      /* caller's surface memory */
    void *bits;        /* DIB section bits */
};

static struct dc_record *dc_records;

NTSTATUS __stdcall D3DKMTCreateDCFromMemory(D3DKMT_CREATEDCFROMMEMORY *desc)
{
    struct
    {
        BITMAPINFOHEADER header;
        RGBQUAD colors[256];
    } bmi;
    struct dc_record *record, *tail;
    DWORD *masks = (DWORD *)bmi.colors;
    WORD bit_count = 0;
    void *bits = NULL;
    unsigned int i;

    memset(&bmi, 0, sizeof(bmi));
    bmi.header.biSize = sizeof(bmi.header);
    bmi.header.biPlanes = 1;

    for (i = 0; i < sizeof(dc_formats) / sizeof(dc_formats[0]); ++i)
    {
        if (dc_formats[i].format != desc->Format)
            continue;
        bit_count = dc_formats[i].bit_count;
        bmi.header.biBitCount = bit_count;
        bmi.header.biCompression = dc_formats[i].compression;
        masks[0] = dc_formats[i].mask_r;
        masks[1] = dc_formats[i].mask_g;
        masks[2] = dc_formats[i].mask_b;
#ifndef QEMU3DFX_D3DKMT_REFERENCE_PALETTE
        /* deviation 2: carry the palette for P8 surfaces */
        if (dc_formats[i].palette_size && desc->pColorTable)
        {
            unsigned int j;
            for (j = 0; j < dc_formats[i].palette_size; ++j)
            {
                bmi.colors[j].rgbRed = desc->pColorTable[j].peRed;
                bmi.colors[j].rgbGreen = desc->pColorTable[j].peGreen;
                bmi.colors[j].rgbBlue = desc->pColorTable[j].peBlue;
                bmi.colors[j].rgbReserved = 0;
            }
            bmi.header.biClrUsed = dc_formats[i].palette_size;
        }
#endif
        break;
    }
    if (!bit_count)
        return STATUS_FAILURE;           /* unknown format (the reference
                                            would divide by zero here) */

    bmi.header.biWidth = desc->Pitch / (bit_count / 8);
    bmi.header.biHeight = -(LONG)desc->Height;          /* top-down */
    bmi.header.biSizeImage = desc->Height * desc->Pitch;

    desc->hDc = CreateCompatibleDC(desc->hDeviceDc);
    desc->hBitmap = CreateDIBSection(desc->hDc, (BITMAPINFO *)&bmi, DIB_RGB_COLORS, &bits, NULL, 0);

    if (!desc->hDc || !desc->hBitmap)
        return STATUS_FAILURE;
    if (!bits)
        return STATUS_FAILURE;

    record = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*record));
    if (!record)
        return STATUS_FAILURE;
    record->hdc = desc->hDc;
    record->bitmap = desc->hBitmap;
    record->size = (SIZE_T)desc->Pitch * desc->Height;
    record->memory = desc->pMemory;
    record->bits = bits;
    if (!dc_records)
        dc_records = record;
    else
    {
        for (tail = dc_records; tail->next; tail = tail->next)
            ;
        tail->next = record;
    }

    memcpy(bits, desc->pMemory, record->size);
    SelectObject(desc->hDc, desc->hBitmap);
    return STATUS_SUCCESS;
}

NTSTATUS __stdcall D3DKMTDestroyDCFromMemory(const D3DKMT_DESTROYDCFROMMEMORY *desc)
{
    struct dc_record *record, *prev = NULL;

    for (record = dc_records; record; prev = record, record = record->next)
    {
        if (record->hdc == desc->hDc && record->bitmap == desc->hBitmap)
            break;
    }
    if (record)
    {
        if (prev)
            prev->next = record->next;
        else
            dc_records = record->next;
        memcpy(record->memory, record->bits, record->size);  /* write back */
        HeapFree(GetProcessHeap(), 0, record);
    }

    DeleteDC(desc->hDc);
    DeleteObject(desc->hBitmap);
    return STATUS_SUCCESS;
}

/* ------------------------------------------------------------------ */
/* Adapter / device / ownership: succeed, like the reference           */
/* ------------------------------------------------------------------ */

/* deviation 1: deterministic outputs instead of uninitialised ones */
#define FAKE_ADAPTER_HANDLE 0x40000001u
#define FAKE_DEVICE_HANDLE  0x40000002u
#define FAKE_LUID_LOW       0x0000a7dfu

NTSTATUS __stdcall D3DKMTOpenAdapterFromLuid(D3DKMT_OPENADAPTERFROMLUID *desc)
{
    desc->hAdapter = FAKE_ADAPTER_HANDLE;
    return STATUS_SUCCESS;
}

NTSTATUS __stdcall D3DKMTOpenAdapterFromGdiDisplayName(D3DKMT_OPENADAPTERFROMGDIDISPLAYNAME *desc)
{
    desc->hAdapter = FAKE_ADAPTER_HANDLE;
    desc->AdapterLuid.LowPart = FAKE_LUID_LOW;
    desc->AdapterLuid.HighPart = 0;
    desc->VidPnSourceId = 0;
    return STATUS_SUCCESS;
}

NTSTATUS __stdcall D3DKMTCloseAdapter(const void *desc)
{
    return STATUS_SUCCESS;
}

NTSTATUS __stdcall D3DKMTCreateDevice(D3DKMT_CREATEDEVICE *desc)
{
    desc->hDevice = FAKE_DEVICE_HANDLE;
    return STATUS_SUCCESS;
}

NTSTATUS __stdcall D3DKMTDestroyDevice(const void *desc)
{
    return STATUS_SUCCESS;
}

NTSTATUS __stdcall D3DKMTSetVidPnSourceOwner(const void *desc)
{
    return STATUS_SUCCESS;
}

/* STATUS_NOT_IMPLEMENTED -> wined3d_adapter_get_video_memory_info() falls
 * back to fake memory info (reference returns exactly this). */
NTSTATUS __stdcall D3DKMTQueryVideoMemoryInfo(void *desc)
{
    return STATUS_NOT_IMPLEMENTED;
}
