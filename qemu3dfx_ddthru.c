/*
 * qemu-3dfx "ddthru": per-call routing of the DirectDraw entry points.
 *
 * The reference ddraw.dll (all versions 1.8.7 .. 8.0.2; 8.0.2 build: router
 * at 0x1000ef6e, entry points 0x1001586a DirectDrawCreate, 0x10009480
 * DirectDrawCreateClipper, 0x10015929 DirectDrawCreateEx, 0x1000f48c
 * DirectDrawEnumerateA, 0x1000f343 DirectDrawEnumerateExA, 0x1000f26a
 * GetSurfaceFromDC) begins each of these six entry points by asking:
 *
 *   - is the caller (by return address) inside ddraw.dll itself?  -> Wine
 *   - is there a file "wined3d.mod" in the current directory?  no -> Wine
 *   - load the system DirectDraw (ddrawwq.dll); unavailable       -> Wine
 *   - each line of wined3d.mod is "module,size[,offset]" (hex): a caller
 *     inside [module + offset, module + offset + size]             -> Wine
 *   - anything else                                               -> system
 *
 * The decision is published with wined3d_passthru() and logged to the host
 * through the magic glDebugMessageInsertARB channel as
 * "[ ddthru <module> <name> ] at <caller> passthru|winecall".
 *
 * Differences from the reference, all deliberate:
 *   - "inside ddraw.dll" uses the real image size from the PE header; the
 *     reference uses a fixed 0x20000, which covered its own code section;
 *   - the file is read with CreateFileA/ReadFile and parsed by hand (this
 *     ddraw.dll is linked without the C runtime); lines are split into the
 *     same 63-character pieces fgets(buf, 64) would return;
 *   - the log message is formatted with wsprintfA.
 */

#ifndef _WIN32
#error "This file is for Windows PE targets only"
#endif

#include <windows.h>

extern BOOL WINAPI wined3d_passthru(BOOL *enabled);
extern void *qemu3dfx_ddrawwq_table(void);      /* qemu3dfx_ddraw_hooks.c */

/* Must match the order of the table in qemu3dfx_ddraw_hooks.c. */
struct ddrawwq_table
{
    HMODULE module;
    HRESULT (WINAPI *DirectDrawCreate)(GUID *, void **, IUnknown *);
    HRESULT (WINAPI *DirectDrawCreateClipper)(DWORD, void **, IUnknown *);
    HRESULT (WINAPI *DirectDrawCreateEx)(GUID *, void **, REFIID, IUnknown *);
    HRESULT (WINAPI *DirectDrawEnumerateA)(void *, void *);
    HRESULT (WINAPI *DirectDrawEnumerateExA)(void *, void *, DWORD);
    HRESULT (WINAPI *GetSurfaceFromDC)(HDC, void **, HDC *);
};

extern IMAGE_DOS_HEADER __ImageBase;

static BOOL caller_in_own_image(ULONG_PTR caller)
{
    ULONG_PTR base = (ULONG_PTR)&__ImageBase;
    const IMAGE_NT_HEADERS *nt = (const IMAGE_NT_HEADERS *)
            (base + ((const IMAGE_DOS_HEADER *)base)->e_lfanew);

    return caller >= base && caller <= base + nt->OptionalHeader.SizeOfImage;
}

static DWORD parse_hex(const char *s)
{
    DWORD v = 0;

    while (*s == ' ' || *s == '\t')
        ++s;
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
        s += 2;
    for (;; ++s)
    {
        if (*s >= '0' && *s <= '9') v = v * 16 + (*s - '0');
        else if (*s >= 'a' && *s <= 'f') v = v * 16 + (*s - 'a' + 10);
        else if (*s >= 'A' && *s <= 'F') v = v * 16 + (*s - 'A' + 10);
        else break;
    }
    return v;
}

static void copy_str(char *dst, const char *src, int size)
{
    int i;

    for (i = 0; i < size - 1 && src[i]; ++i)
        dst[i] = src[i];
    dst[i] = 0;
}

typedef void (WINAPI *PFN_glDebugMessageInsertARB)(unsigned int, unsigned int,
        unsigned int, unsigned int, int, const char *);
typedef BOOL (WINAPI *PFN_GetModuleHandleExA)(DWORD, LPCSTR, HMODULE *);

/* Returns the system DirectDraw table when this call is to be passed
 * through, NULL when Wine handles it (reference 0x1000ef6e). */
static struct ddrawwq_table *ddthru_route(ULONG_PTR caller)
{
    struct ddrawwq_table *table;
    char file[4096], piece[64], module[32], name[64], msg[0xc0 + 64];
    ULONG_PTR matched = (ULONG_PTR)-1;
    PFN_glDebugMessageInsertARB p_glDebugMessageInsertARB;
    PFN_GetModuleHandleExA p_GetModuleHandleExA;
    HANDLE f;
    DWORD len = 0, pos = 0;

    if (caller_in_own_image(caller))
        return NULL;

    f = CreateFileA("wined3d.mod", GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    if (f == INVALID_HANDLE_VALUE)
        return NULL;
    if (!ReadFile(f, file, sizeof(file) - 1, &len, NULL))
        len = 0;
    CloseHandle(f);
    file[len] = 0;

    table = qemu3dfx_ddrawwq_table();
    module[0] = 0;

    while (pos < len)
    {
        int n = 0, comma = -1, i;
        DWORD size, offset = 0;
        const char *rest, *second;
        HMODULE h;

        /* fgets(piece, 64): up to 63 characters, newline included */
        while (pos < len && n < 63)
        {
            piece[n++] = file[pos];
            if (file[pos++] == '\n')
                break;
        }
        piece[n] = 0;

        for (i = 0; i < n; ++i)
            if (piece[i] == ',') { comma = i; break; }
        if (comma < 0)
            continue;

        piece[comma] = 0;
        copy_str(module, piece, sizeof(module));
        rest = piece + comma + 1;
        size = parse_hex(rest);
        for (second = rest; *second && *second != ','; ++second)
            ;
        if (*second == ',')
            offset = parse_hex(second + 1);

        if (!(h = GetModuleHandleA(module)))
        {
            matched = 0;
            continue;
        }
        matched = (ULONG_PTR)h;
        if (caller < (ULONG_PTR)h + offset || (ULONG_PTR)h + offset + size < caller)
            continue;

        table = NULL;       /* caller listed: Wine handles it */
        break;
    }

    p_glDebugMessageInsertARB = (PFN_glDebugMessageInsertARB)(void *)GetProcAddress(
            GetModuleHandleA("opengl32.dll"), "glDebugMessageInsertARB");
    p_GetModuleHandleExA = (PFN_GetModuleHandleExA)(void *)GetProcAddress(
            GetModuleHandleA("kernel32.dll"), "GetModuleHandleExA");
    if (p_glDebugMessageInsertARB)
    {
        HMODULE caller_module;

        copy_str(name, matched ? module : "", sizeof(name));
        if (p_GetModuleHandleExA && p_GetModuleHandleExA(4 /* FROM_ADDRESS */,
                (LPCSTR)caller, &caller_module))
            GetModuleFileNameA(caller_module, name, sizeof(name) - 1);
        wsprintfA(msg, "[ ddthru %08lx %s ] at %08lx %s", (unsigned long)matched, name,
                (unsigned long)caller, table ? "passthru" : "winecall");
        msg[0xc0 - 1] = 0;
        p_glDebugMessageInsertARB(0x824b, 0x8251, 0x9148, 0xffffffff, 0xc0, msg);
    }
    return table;
}

static struct ddrawwq_table *ddthru_table;

/* Called first thing by each of the six entry points with its own return
 * address; TRUE means forward to the matching qemu3dfx_ddthru_* below. */
BOOL qemu3dfx_ddthru(void *caller)
{
    ddthru_table = ddthru_route((ULONG_PTR)caller);
    wined3d_passthru((BOOL *)&ddthru_table);
    return ddthru_table != NULL;
}

HRESULT WINAPI qemu3dfx_ddthru_DirectDrawCreate(GUID *guid, void **ddraw, IUnknown *outer)
{
    return ddthru_table->DirectDrawCreate(guid, ddraw, outer);
}

HRESULT WINAPI qemu3dfx_ddthru_DirectDrawCreateClipper(DWORD flags, void **clipper, IUnknown *outer)
{
    return ddthru_table->DirectDrawCreateClipper(flags, clipper, outer);
}

HRESULT WINAPI qemu3dfx_ddthru_DirectDrawCreateEx(GUID *guid, void **ddraw, REFIID iid, IUnknown *outer)
{
    return ddthru_table->DirectDrawCreateEx(guid, ddraw, iid, outer);
}

HRESULT WINAPI qemu3dfx_ddthru_DirectDrawEnumerateA(void *callback, void *context)
{
    return ddthru_table->DirectDrawEnumerateA(callback, context);
}

HRESULT WINAPI qemu3dfx_ddthru_DirectDrawEnumerateExA(void *callback, void *context, DWORD flags)
{
    return ddthru_table->DirectDrawEnumerateExA(callback, context, flags);
}

HRESULT WINAPI qemu3dfx_ddthru_GetSurfaceFromDC(HDC dc, void **surface, HDC *device_dc)
{
    return ddthru_table->GetSurfaceFromDC(dc, surface, device_dc);
}
