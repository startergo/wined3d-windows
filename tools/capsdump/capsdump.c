/* capsdump.exe - dump what the DirectDraw/Direct3D DLLs next to it report,
 * to COM1 (QEMU -serial file:...). Win98-safe: kernel32/user32/ddraw only.
 *
 * For each run: DDCAPS (HAL), the Z-buffer formats of the HAL device, and
 * every IDirect3D3 device's name, GUID and HW/HEL D3DDEVICEDESC as raw
 * dwords, so two runs can be diffed field by field. */
#define INITGUID
#include <windows.h>
#include <ddraw.h>
#include <d3d.h>
#include <stdarg.h>

/* no C runtime (Win98 has no UCRT; this MinGW only ships UCRT startup code) */
#pragma GCC optimize("no-tree-loop-distribute-patterns")
static void zero(void *p, DWORD n) { volatile unsigned char *c = p; while (n--) *c++ = 0; }

static void out(const char *fmt, ...)
{
    char buf[1024];
    DWORD n, w;
    va_list ap;
    HANDLE port;

    va_start(ap, fmt);
    n = (DWORD)wvsprintfA(buf, fmt, ap);
    va_end(ap);
    port = CreateFileA("COM1", GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);
    if (port != INVALID_HANDLE_VALUE)
    {
        WriteFile(port, buf, n, &w, NULL);
        CloseHandle(port);
    }
}

static void dump(const char *tag, const void *p, DWORD size)
{
    const DWORD *d = (const DWORD *)p;
    char line[160];
    DWORD i, n = 0;

    for (i = 0; i < size / 4; ++i)
    {
        if (i % 8 == 0) n = wsprintfA(line, "%s %03lx:", tag, i * 4);
        n += wsprintfA(line + n, " %08lx", d[i]);
        if (i % 8 == 7 || i == size / 4 - 1) out("%s\r\n", line);
    }
}

static HRESULT WINAPI zcb(DDPIXELFORMAT *pf, void *ctx)
{
    out("ZFMT flags=%08lx bits=%lu zmask=%08lx stencil=%08lx\r\n", pf->dwFlags,
        pf->dwZBufferBitDepth, pf->dwZBitMask, pf->dwStencilBitMask);
    return D3DENUMRET_OK;
}

static HRESULT WINAPI devcb(GUID *guid, char *desc, char *name, D3DDEVICEDESC *hw, D3DDEVICEDESC *hel, void *ctx)
{
    out("DEVICE name=\"%s\" desc=\"%s\" guid=%08lx\r\n", name, desc, guid->Data1);
    dump(" HW ", hw, hw->dwSize);
    dump(" HEL", hel, hel->dwSize);
    return D3DENUMRET_OK;
}

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmd, int show)
{
    IDirectDraw *dd = NULL;
    IDirect3D3 *d3d = NULL;
    DDCAPS hal, hel;
    HRESULT hr;

    out("=== capsdump %s ===\r\n", cmd ? cmd : "");
    if (FAILED(hr = DirectDrawCreate(NULL, &dd, NULL)))
    {
        out("DirectDrawCreate failed %08lx\r\n", hr);
        return 1;
    }
    zero(&hal, sizeof(hal)); hal.dwSize = sizeof(hal);
    zero(&hel, sizeof(hel)); hel.dwSize = sizeof(hel);
    hr = IDirectDraw_GetCaps(dd, &hal, &hel);
    out("GetCaps %08lx\r\n", hr);
    dump("DDCAPS", &hal, sizeof(hal));
    if (FAILED(hr = IDirectDraw_QueryInterface(dd, &IID_IDirect3D3, (void **)&d3d)))
    {
        out("QI IDirect3D3 failed %08lx\r\n", hr);
    }
    else
    {
        hr = IDirect3D3_EnumDevices(d3d, devcb, NULL);
        out("EnumDevices %08lx\r\n", hr);
        hr = IDirect3D3_EnumZBufferFormats(d3d, &IID_IDirect3DHALDevice, zcb, NULL);
        out("EnumZBufferFormats(HAL) %08lx\r\n", hr);
        IDirect3D3_Release(d3d);
    }
    IDirectDraw_Release(dd);
    out("=== end ===\r\n");
    return 0;
}

void WINAPI WinMainCRTStartup(void)
{
    char *cmd = GetCommandLineA();

    /* skip the program name */
    if (*cmd == '"') { ++cmd; while (*cmd && *cmd != '"') ++cmd; if (*cmd) ++cmd; }
    else while (*cmd && *cmd != ' ') ++cmd;
    while (*cmd == ' ') ++cmd;
    ExitProcess(WinMain(GetModuleHandleA(NULL), NULL, cmd, SW_SHOWNORMAL));
}
