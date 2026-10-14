/*
 * Mock implementations of the Win32 API used by the qemu-3dfx sources, for
 * host unit tests (tests/include/windows.h).  The mock_* globals let each
 * test control behaviour; mock_reset() restores defaults.
 */
#include <string.h>
#include <strings.h>
#include <stdlib.h>
#include "include/windows.h"
#include "mock_win32.h"

/* ── Controllable mock state ─────────────────────────────────────── */

int    mock_qemuchs_accessible = 0;          /* legacy: CreateFileA("\\.\QEMUchs") */
HANDLE mock_opengl32_handle = NULL;          /* GetModuleHandleA("opengl32.dll") */
int    mock_quartz_loaded = 0;               /* GetModuleHandleA("quartz") */

const char *mock_exe_path = "C:\\GAMES\\TEST\\GAME.EXE";
const char *mock_adapter = "QEMU Bochs Compatible VGA";   /* NULL: no device */

struct mock_reg_value mock_reg_def[MOCK_REG_MAX];     /* Software\Wine\Direct3D */
struct mock_reg_value mock_reg_app[MOCK_REG_MAX];     /* AppDefaults\<exe>\Direct3D */
int mock_reg_app_present = 0;

DWORD mock_clock[64];          /* successive GetTickCount() results ... */
int   mock_clock_len = 0;
int   mock_clock_pos = 0;
DWORD mock_clock_step = 1;     /* ... then advance by this much per call */
int   mock_sleep_calls = 0;

int   mock_screen_w = 1024, mock_screen_h = 768;
int   mock_cursor_ok = 1;
CURSORINFO mock_cursor = { sizeof(CURSORINFO), CURSOR_SHOWING, (HCURSOR)0x1234, { 100, 200 } };
RECT  mock_window_rect = { 10, 20, 650, 520 };
RECT  mock_client_rect = { 0, 0, 632, 474 };

int     mock_wgl_3dfx = 1;     /* wglGetProcAddress resolves the qemu-3dfx entry points */
int     mock_set_cursor_calls = 0;
HCURSOR mock_set_cursor_last = NULL;
int     mock_debug_msg_calls = 0;
DWORD   mock_debug_msg_payload = 0;
unsigned mock_debug_msg_args[5];

void mock_reset(void)
{
    mock_qemuchs_accessible = 0;
    mock_opengl32_handle = NULL;
    mock_quartz_loaded = 0;
    mock_exe_path = "C:\\GAMES\\TEST\\GAME.EXE";
    mock_adapter = "QEMU Bochs Compatible VGA";
    memset(mock_reg_def, 0, sizeof(mock_reg_def));
    memset(mock_reg_app, 0, sizeof(mock_reg_app));
    mock_reg_app_present = 0;
    mock_clock_len = mock_clock_pos = 0;
    mock_clock_step = 1;
    mock_sleep_calls = 0;
    mock_screen_w = 1024; mock_screen_h = 768;
    mock_cursor_ok = 1;
    mock_cursor.flags = CURSOR_SHOWING;
    mock_cursor.hCursor = (HCURSOR)0x1234;
    mock_cursor.ptScreenPos.x = 100; mock_cursor.ptScreenPos.y = 200;
    mock_window_rect = (RECT){ 10, 20, 650, 520 };
    mock_client_rect = (RECT){ 0, 0, 632, 474 };
    mock_wgl_3dfx = 1;
    mock_set_cursor_calls = 0; mock_set_cursor_last = NULL;
    mock_debug_msg_calls = 0; mock_debug_msg_payload = 0;
}

static void reg_set(struct mock_reg_value *t, const char *name, DWORD type, const char *s, DWORD d)
{
    int i;
    for (i = 0; i < MOCK_REG_MAX; ++i)
        if (!t[i].name || !strcmp(t[i].name, name))
        {
            t[i].name = name; t[i].type = type; t[i].str = s; t[i].dword = d;
            return;
        }
}
void mock_reg_def_str(const char *n, const char *v)   { reg_set(mock_reg_def, n, REG_SZ, v, 0); }
void mock_reg_def_dword(const char *n, DWORD v)       { reg_set(mock_reg_def, n, REG_DWORD, NULL, v); }
void mock_reg_app_str(const char *n, const char *v)   { mock_reg_app_present = 1; reg_set(mock_reg_app, n, REG_SZ, v, 0); }
void mock_reg_app_dword(const char *n, DWORD v)       { mock_reg_app_present = 1; reg_set(mock_reg_app, n, REG_DWORD, NULL, v); }

/* ── Legacy file/module mocks ────────────────────────────────────── */
HANDLE CreateFileA(LPCSTR name, DWORD access, DWORD share, SECURITY_ATTRIBUTES *sa,
                   DWORD creation, DWORD flags, HANDLE tmpl)
{
    (void)access; (void)share; (void)sa; (void)creation; (void)flags; (void)tmpl;
    if (name && strcmp(name, "\\\\.\\QEMUchs") == 0)
        return mock_qemuchs_accessible ? (HANDLE)1 : INVALID_HANDLE_VALUE;
    return INVALID_HANDLE_VALUE;
}

BOOL CloseHandle(HANDLE h) { (void)h; return TRUE; }

HANDLE GetModuleHandleA(LPCSTR name)
{
    if (name && strcmp(name, "opengl32.dll") == 0)
        return mock_opengl32_handle;
    if (name && (!strcasecmp(name, "quartz") || !strcasecmp(name, "quartz.dll")))
        return mock_quartz_loaded ? (HANDLE)0x7a000000 : NULL;
    return NULL;
}

/* GetProcAddress: NULL unless a test enables a fake export table */
int mock_getprocaddress_ok = 0;
static void mock_export(void) { }
void *GetProcAddress(HANDLE h, LPCSTR name)
{
    (void)h; (void)name;
    return mock_getprocaddress_ok ? (void *)mock_export : NULL;
}

/* ddrawwq.dll (the passthrough target) is not present unless a test says so */
HMODULE mock_loadlibrary_result = NULL;
int     mock_loadlibrary_calls = 0;
HMODULE LoadLibraryA(LPCSTR name) { (void)name; mock_loadlibrary_calls++; return mock_loadlibrary_result; }
BOOL    FreeLibrary(HMODULE m) { (void)m; return TRUE; }

DWORD GetModuleFileNameA(HMODULE module, LPSTR buf, DWORD size)
{
    size_t n = strlen(mock_exe_path);
    (void)module;
    if (n >= size) { memcpy(buf, mock_exe_path, size - 1); buf[size - 1] = 0; return size; }
    memcpy(buf, mock_exe_path, n + 1);
    return (DWORD)n;
}

/* ── Registry ────────────────────────────────────────────────────── */
#define HKEY_DEF          ((HKEY)(uintptr_t)0x1001)
#define HKEY_APPDEFAULTS  ((HKEY)(uintptr_t)0x1002)
#define HKEY_APP          ((HKEY)(uintptr_t)0x1003)

static const char *basename_of(const char *p)
{
    const char *b = p;
    for (; *p; ++p) if (*p == '\\' || *p == '/') b = p + 1;
    return b;
}

LONG RegOpenKeyA(HKEY key, LPCSTR subkey, PHKEY result)
{
    char want[MAX_PATH + 16];
    if (key == HKEY_CURRENT_USER && !strcmp(subkey, "Software\\Wine\\Direct3D"))
        { *result = HKEY_DEF; return ERROR_SUCCESS; }
    if (key == HKEY_CURRENT_USER && !strcmp(subkey, "Software\\Wine\\AppDefaults"))
        { *result = HKEY_APPDEFAULTS; return ERROR_SUCCESS; }
    if (key == HKEY_APPDEFAULTS && mock_reg_app_present)
    {
        strcpy(want, basename_of(mock_exe_path));
        strcat(want, "\\Direct3D");
        if (!strcasecmp(subkey, want)) { *result = HKEY_APP; return ERROR_SUCCESS; }
    }
    return 2;   /* ERROR_FILE_NOT_FOUND */
}

LONG RegQueryValueExA(HKEY key, LPCSTR name, LPDWORD reserved, LPDWORD type, void *data, LPDWORD size)
{
    struct mock_reg_value *t = key == HKEY_DEF ? mock_reg_def : key == HKEY_APP ? mock_reg_app : NULL;
    int i;
    (void)reserved;
    if (!t) return 6;   /* ERROR_INVALID_HANDLE */
    for (i = 0; i < MOCK_REG_MAX && t[i].name; ++i)
    {
        if (strcmp(t[i].name, name)) continue;
        if (type) *type = t[i].type;
        if (t[i].type == REG_DWORD)
        {
            if (*size < 4) return 234;
            memcpy(data, &t[i].dword, 4); *size = 4;
        }
        else
        {
            DWORD n = (DWORD)strlen(t[i].str) + 1;
            if (*size < n) return 234;   /* ERROR_MORE_DATA */
            memcpy(data, t[i].str, n); *size = n;
        }
        return ERROR_SUCCESS;
    }
    return 2;
}

LONG RegCloseKey(HKEY key) { (void)key; return ERROR_SUCCESS; }

/* ── Strings ─────────────────────────────────────────────────────── */
LPSTR lstrcpyA(LPSTR d, LPCSTR s) { return strcpy(d, s); }
LPSTR lstrcatA(LPSTR d, LPCSTR s) { return strcat(d, s); }
int   lstrcmpiA(LPCSTR a, LPCSTR b) { return strcasecmp(a, b); }

/* ── Time ────────────────────────────────────────────────────────── */
DWORD GetTickCount(void)
{
    DWORD t;
    if (mock_clock_pos < mock_clock_len)
        t = mock_clock[mock_clock_pos];
    else
        t = (mock_clock_len ? mock_clock[mock_clock_len - 1] : 1000)
            + (DWORD)(mock_clock_pos - mock_clock_len + 1) * mock_clock_step;
    mock_clock_pos++;
    return t;
}

void Sleep(DWORD ms) { (void)ms; mock_sleep_calls++; }

int MulDiv(int a, int b, int c)
{
    long long r;
    int neg;
    if (!c) return -1;
    r = (long long)a * b;
    neg = (r < 0) != (c < 0);
    r = (llabs(r) + llabs((long long)c) / 2) / llabs((long long)c);
    return (int)(neg ? -r : r);
}

/* ── Display / cursor / windows ──────────────────────────────────── */
BOOL EnumDisplayDevicesA(LPCSTR device, DWORD index, DISPLAY_DEVICEA *dd, DWORD flags)
{
    (void)device; (void)flags;
    if (!mock_adapter || index) return FALSE;
    strncpy(dd->DeviceString, mock_adapter, sizeof(dd->DeviceString) - 1);
    return TRUE;
}

int GetSystemMetrics(int i) { return i == SM_CXSCREEN ? mock_screen_w : i == SM_CYSCREEN ? mock_screen_h : 0; }

BOOL GetCursorInfo(CURSORINFO *ci)
{
    if (!mock_cursor_ok) return FALSE;
    ci->flags = mock_cursor.flags;
    ci->hCursor = mock_cursor.hCursor;
    ci->ptScreenPos = mock_cursor.ptScreenPos;
    return TRUE;
}

BOOL GetWindowRect(HWND h, RECT *r) { (void)h; *r = mock_window_rect; return TRUE; }
BOOL GetClientRect(HWND h, RECT *r) { (void)h; *r = mock_client_rect; return TRUE; }

/* ── WGL: the qemu-3dfx wrapper's entry points ───────────────────── */
static BOOL mock_wglSetDeviceCursor3DFX(HCURSOR c)
{
    mock_set_cursor_calls++; mock_set_cursor_last = c; return TRUE;
}

static void mock_glDebugMessageInsertARB(unsigned src, unsigned type, unsigned id,
                                         unsigned sev, int len, const char *buf)
{
    mock_debug_msg_calls++;
    mock_debug_msg_args[0] = src; mock_debug_msg_args[1] = type; mock_debug_msg_args[2] = id;
    mock_debug_msg_args[3] = sev; mock_debug_msg_args[4] = (unsigned)len;
    memcpy(&mock_debug_msg_payload, buf, 4);
}

PROC wglGetProcAddress(LPCSTR name)
{
    if (!mock_wgl_3dfx) return NULL;
    if (!strcmp(name, "wglSetDeviceCursor3DFX")) return (PROC)(void *)mock_wglSetDeviceCursor3DFX;
    if (!strcmp(name, "glDebugMessageInsertARB")) return (PROC)(void *)mock_glDebugMessageInsertARB;
    return NULL;
}
