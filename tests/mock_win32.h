/* Controls for the Win32 mocks in tests/mock_win32.c */
#ifndef MOCK_WIN32_H
#define MOCK_WIN32_H

#include "include/windows.h"

#define MOCK_REG_MAX 32
struct mock_reg_value { const char *name; DWORD type; const char *str; DWORD dword; };

extern int    mock_qemuchs_accessible;
extern HANDLE mock_opengl32_handle;
extern int    mock_quartz_loaded;
extern const char *mock_exe_path;
extern const char *mock_adapter;
extern int    mock_reg_app_present;
extern DWORD  mock_clock[64];
extern int    mock_clock_len, mock_clock_pos;
extern DWORD  mock_clock_step;
extern int    mock_sleep_calls;
extern int    mock_screen_w, mock_screen_h;
extern int    mock_cursor_ok;
extern CURSORINFO mock_cursor;
extern RECT   mock_window_rect, mock_client_rect;
extern int    mock_wgl_3dfx;
extern int    mock_set_cursor_calls;
extern HCURSOR mock_set_cursor_last;
extern int    mock_debug_msg_calls;
extern DWORD  mock_debug_msg_payload;
extern unsigned mock_debug_msg_args[5];

void mock_reset(void);
void mock_reg_def_str(const char *name, const char *value);
void mock_reg_def_dword(const char *name, DWORD value);
void mock_reg_app_str(const char *name, const char *value);
void mock_reg_app_dword(const char *name, DWORD value);

#endif
