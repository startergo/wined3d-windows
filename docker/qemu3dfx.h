/*
 * Prototypes of the qemu-3dfx module (qemu3dfx_hooks.c) for the Wine source
 * files that docker/qemu3dfx_callsites.py patches.  Kept free of Wine types
 * so it can be included anywhere after <windows.h>.
 */
#ifndef QEMU3DFX_H
#define QEMU3DFX_H

void qemu3dfx_load_config(void);
BOOL qemu3dfx_is_qemu_bochs(void);
BOOL qemu3dfx_use_last_context_tid(void);
BOOL qemu3dfx_passthru_active(void);
DWORD qemu3dfx_scale_window_value(void);
void qemu3dfx_display_roi(RECT *rect);
BOOL qemu3dfx_override_mode(DEVMODEA *dm);
void qemu3dfx_swap_interval(int *interval);
BOOL qemu3dfx_scale_window(RECT *window, RECT *screen, DWORD *mode);
ULONG_PTR qemu3dfx_latch0(ULONG_PTR value);
ULONG_PTR qemu3dfx_latch1(ULONG_PTR value);
ULONG_PTR qemu3dfx_latch2(ULONG_PTR value);
void qemu3dfx_sysmem_count_quirk(DWORD locations, LONG *sysmem_count);
void qemu3dfx_set_host_cursor(HCURSOR cursor);
void qemu3dfx_cursor_sync(HWND window);

#endif /* QEMU3DFX_H */
