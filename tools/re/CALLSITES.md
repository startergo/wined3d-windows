# qemu-3dfx call sites

Where the reference qemu-3dfx DLLs call into the qemu-3dfx module, and where
our build makes the same calls. The modules are `qemu3dfx_hooks.c` (wined3d,
verified by `tests/emu/test_module.py`), `qemu3dfx_ddraw_hooks.c` and
`qemu3dfx_ddthru.c` (ddraw, verified by `tests/emu/test_ddraw.py`). The
calls are inserted into Wine source by `docker/qemu3dfx_callsites.py`: each
edit is scoped to one function, positioned on an anchor, gated by Wine major
version, and must match exactly once or the build fails.

## Status

| | 1.8.7 | 1.9.7 | 2.0.5 | 3.0.5 | 4.12.1 | 5.0.5 | 6.0.4 | 7.0.2 | 8.0.2 |
|---|---|---|---|---|---|---|---|---|---|
| ddraw sites | 11 | 11 | 12 | 12 | 11 | 11 | 12 | 12 | 12 |
| wined3d sites | 24 | 24 | 25 | 24 | 27 | 27 | 28 | 28 | 27 |

The ddraw counts equal the reference's call counts per version. wined3d
4.12.1/5.0.5 have no swap-interval or restore site (the reference has none)
and one extra cursor-clip edit. wined3d 3.0.5 is surface-based (22 sites,
below); 1.8.7–2.0.5 likewise (22–23 sites). Every version's placement was
checked against its reference with `placement.py`.

## Method

1. `tools/re/modsites.py <ref wined3d.dll>` finds the module from the
   qemu-3dfx exports, names its functions by fingerprint against the 1.8.7 /
   8.0.2 internals (latches and `swap_interval` by their fixed offsets from
   `display_roi` / `override_mode`), and lists every external call site.
2. `tools/re/funcmatch.py` / `--named` name the enclosing reference
   functions against a build of ours that kept its COFF symbols
   (`/build/wined3d.dll`, `/build/winedd.dll` in the Docker image).
3. Each site is read in the disassembly (`annot.py`) and aligned with the
   Wine source line; the decoded behaviour is written as the edit.
4. `tools/re/placement.py <symbols.dll> <regex>` checks the result: every
   module call must sit in the same Wine function as in the reference
   (inlining aside).

## wined3d (6.0.4, 7.0.2, 8.0.2)

Reference addresses are 8.0.2.

| Wine function | Call | Ref |
|---|---|---|
| `DllMain` | `latch0(inst)`, `qemu3dfx_load_config()` before `wined3d_dll_init` | `0x10089223` |
| `wined3d_device_set_cursor_properties` | `set_host_cursor(cursor)` after `hardwareCursor = cursor` | `0x100429b1` |
| `wined3d_context_gl_set_current` | `UseLastContextTid` → `old = context_gl` | `0x100207c4` |
| `wined3d_swapchain_gl_get_context` | `UseLastContextTid` → last context instead of a new one | `0x1006c583` |
| `swapchain_gl_set_swap_interval` | `swap_interval(&swap_interval)` after the clamp | `0x1006d091` |
| `swapchain_gl_present` | `latch1(front_buffer)` after validate DRAWABLE | `0x1006d167` |
| `swapchain_blit` | `latch1(texture)`; `cursor_sync(window)` after the blit | `0x1006e195`, `0x1006e20f` |
| `wined3d_texture_load_drawable` | `latch1(texture)` after load TEXTURE_RGB; `cursor_sync` after the blit | `0x10072767`, `0x100727d7` |
| `wined3d_texture_gl_load_sysmem` | `latch2(texture)` after the DRAWABLE read-back | `0x100726d3` |
| `wined3d_texture_validate_location` | Silent Hill 4 sysmem-count quirk | `0x1006a7bb` |
| `struct wined3d_output` | `RECT qemu3dfx_mode_rect` (requested mode size) | output+0x2c |
| `wined3d_output_set_display_mode` | redundant-mode shortcut only if `OverrideModeWidth` leaves the mode alone; record requested size; `ScaleWindow` keeps the desktop mode (at the requested depth, through `OverrideModeWidth`) when the scale window covers the request | `0x1003f985` |
| `wined3d_output_get_display_mode` | `ScaleWindow` reports the requested (or scale-window) size; records the reported size if none yet | `0x1003e95c` |
| `wined3d_restore_display_modes` | `ScaleWindow` → always restore | `0x1003ec37` |
| `texture2d_get_blt_info` | `ScaleWindow` → source rectangle through `DisplayROI` | `0x1006a494` |
| `wined3d_context_gl_draw_textured_quad`, `_draw_shaded_quad` | presented frame from (0,0): `glViewport` to the screen (and linear filter if asked), restored afterwards | `0x10027e6d`, `0x1002adb2` |
| `texture2d_blt_fbo` | full-width blit of the presented frame to the top of the drawable: destination = screen, source through `DisplayROI`, `GL_LINEAR` if asked; with `ScaleWindow` only that blit flushes | `0x1006e252` |
| `fbo_blitter_blit` | fallback blit from latch2 dropped with `ScaleWindow` or `OffscreenRenderingMode=backbuffer` | `0x1007c0e1` |

`gl_info+0x92c` in the reference is `glViewport` (`adapter_gl.c`'s
`glViewport(0, 0, 4, 1)` uses it). Deviations: NULL checks on latch1 and on
`back_buffers` (the reference dereferences them unconditionally).

**Hidden windows (all versions).** The "WineD3D fake window"s are created with
the `WineD3D_OpenGL` class that `DllMain` registers with the DLL's
instance; on Win9x a non-global class is only found with the instance
that registered it, so the reference passes latch0 (the DLL instance)
instead of `NULL` as `CreateWindowA`'s `hInstance`:

| Window | Function | Versions |
|---|---|---|
| GL capability probe | `wined3d_caps_gl_ctx_create` (`directx.c` ≤3.0, `adapter_gl.c` 4.12+; ref 8.0.2 `0x1000b32f`) | all |
| swapchain backup DC | `swapchain_get_backup_dc` (≤4.12), `wined3d_swapchain_gl_get_backup_dc` (5.0–7.0) | 1.8.7–7.0.2 |

8.0.2's reference reads latch0 once: the backup window moved to
`device.c` (`wined3d_device_gl_get_backup_dc`) and was left with `NULL`.

## ddraw (all versions)

Reference addresses are 8.0.2 unless noted.

| Wine function | Call | Versions |
|---|---|---|
| `DirectDrawCreate`, `…CreateEx`, `…CreateClipper`, `…EnumerateA`, `…EnumerateExA` | `qemu3dfx_ddthru(__builtin_return_address(0))` first; forward to `ddrawwq.dll` on passthrough | all |
| `GetSurfaceFromDC` | same | 2.0+ (absent before) |
| `ddraw_set_cooperative_level` | `if (!restore_mode_on_normal) wined3d_override_cooplevel(&cooplevel)`: before the `DDSCL_EXCLUSIVE` block (5.0+, `0x10005505`); inside the fullscreen-change block before the new window is set up (≤4.12, 1.8.7 `0x10005810`) | all |
| `d3d3_EnumDevices` | whole body: Ramp + RGB emulation devices before the HAL (`EnumHalLast` or Direct3D ≠ 1) or after it; HAL advertises POW2 with the 3dfx HAL (`0x10006453`) | all |
| `ddraw7_EnumDisplayModes` | 3dfx HAL → 16-bit RGB modes only (`0x10007e76`) | all |
| `ddraw_surface1_Unlock` / `ddraw_surface7_Unlock` | `wined3d_blit_fpslimit()` after the final unlock (`0x10010d2d`; 1.8.7 `0x1000f077`) | 6.0+ / ≤5.0 |
| `ddraw_surface7_Flip` | `wined3d_flip_fpslimit()` after the final unlock (1.8.7 `0x10010d5e`) | ≤3.0 |
| `d3d_device_init` | `wined3d_override_rendertarget_view(<target's view>)` before it is set (`0x1001518c`; 1.8.7 `0x1000ac96`) | all |
| `ddraw_surface_wined3d_object_destroyed` | `DDSurfaceHeap` → `heap_realloc(surface, 0x14)` + zero instead of `heap_free` (`0x10014e9c`) | 6.0+ |

The six entry points are declared `noinline` (`docker/qemu3dfx_ddraw.h`):
routing keys on their own return address, and an inlined copy inside an
`IDirectDraw` method would see the application as the caller.

## wined3d 1.8.7–5.0.5

Reference call counts per module function (`modsites.py`):

| function | 1.8.7 | 1.9.7 | 2.0.5 | 3.0.5 | 4.12.1 | 5.0.5 | 6.0.4+ |
|---|---|---|---|---|---|---|---|
| cursor_sync | 2 | 2 | 2 | 2 | 2 | 2 | 2 |
| display_roi | 3 | 3 | 3 | 2 | 2 | 2 | 2 |
| latch0 | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
| latch1 | 2 | 2 | 2 | 2 | 3 | 3 | 3 |
| latch2 | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
| override_mode | 2 | 2 | 2 | 2 | 2 | 2 | 2 |
| scale_window | 5 | 5 | 5 | 5 | 7 | 7 | 7 |
| set_host_cursor | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
| swap_interval | 1 | 1 | 1 | 1 | — | — | 1 |
| sysmem_quirk | — | — | 1 | 1 | 1 | 1 | 1 |

Plus direct reads of module globals by the core (`ScaleWindow`,
`UseLastContextTid`, latches; 1.8.7 also reads the passthrough flag,
`qemu3dfx_passthru_active()`).

**4.12.1 / 5.0.5 (inserted, 25 sites)** — same functions as 6.0.4 (5.0.5 sites named against our
6.0.4 symbol build), under older names and files: `context.c`
(`context_set_current` in 4.12, `wined3d_context_gl_set_current` in 5.0,
both quad blitters), `surface.c` (`texture2d_blt_fbo`, `fbo_blitter_blit`),
`wined3d_set_adapter_display_mode` / `wined3d_get_adapter_display_mode`
(directx.c), `struct wined3d_adapter` (holds `screen_format`); no
`wined3d_restore_display_modes`, no swap-interval site.
`wined3d_set_adapter_display_mode` (ref 5.0.5 `0x10033ccd`) differs from 6.0+:
it also handles `mode == NULL` (restore the registry mode), the requested
size is recorded from `new_mode` (adapter+0x37e0), the redundant-mode
shortcut also calls `ClipCursor(&rect)`, and after a successful change the
cursor clip uses the requested size when `ScaleWindow` is set (else the new
mode's).

**3.0.5 (inserted, 22 sites)** — surface-based. latch1 holds the last
surface blitted to a drawable (presented-frame test: its container is its
swapchain's front buffer, no back-buffer check), latch2 the texture last
read back. The display-mode, cursor, quirk, context and `DllMain` edits are
shared with 4.12/5.0; the rest are 3.0's own:

| 3.0.5 function | module calls | later equivalent |
|---|---|---|
| `DllMain` (`0x1005ca5a`) | latch0 | same |
| `wined3d_set_adapter_display_mode` (`0x10023856`) | override_mode ×2, scale_window | same (4.12/5.0) |
| `wined3d_get_adapter_display_mode` (`0x100234c1`) | scale_window | same |
| `wined3d_device_set_cursor_properties` (`0x1001cf9b`) | set_host_cursor | same |
| `wined3d_texture_validate_location` (`0x1004adae`) | sysmem_quirk | same |
| `wined3d_swapchain_update_swap_interval_cs` (`0x1004a64b`) | swap_interval after the interval mapping | `swapchain_gl_present` |
| `wined3d_surface_blt` (`0x1004cef1`) | latch1(dst surface) before, cursor_sync after the final blit | `swapchain_blit` |
| `surface_load_drawable` / `read_from_framebuffer` (inlined into `surface_load_location`, `0x1004efdd`) | latch1 + cursor_sync around the drawable blit; latch2 at the end of the read-back | `wined3d_texture_gl_load_location` |
| `draw_textured_quad` (`0x10046144`) | display_roi, scale_window ×2, reads ScaleWindow | quad blitter + `texture2d_get_blt_info` |
| `surface_blt_fbo` (`0x10047e8c`) | full-frame stretch before `glColorMask` (drawable only, no flush rule) | `texture2d_blt_fbo` |
| `fbo_blitter_blit` (`0x1004c412`) | no fallback blit from latch2 (ScaleWindow / ORM backbuffer) | same |

**1.8.7–2.0.5 (inserted, 22 / 22 / 23 sites)** — 3.0.5's display-mode,
cursor, context, `DllMain`, `draw_textured_quad` and `surface_blt_fbo` edits,
plus:

| Wine function | Call | Ref (2.0.5 unless noted) |
|---|---|---|
| `wined3d_texture_validate_location` | sysmem quirk (2.0 only) | `0x10041ecf` |
| `swapchain_update_swap_interval` (1.8, 2.0) / `context_create` (1.9) | swap_interval before the `WGL_EXT_SWAP_CONTROL` check | `0x10041a8d`; 1.9.7 `0x10011d09` |
| `surface_load_drawable` | latch1(surface) after the TEXTURE_RGB load; cursor_sync after `surface_blt_to_drawable` | `0x10046256`, `0x100462aa` |
| `read_from_framebuffer` | latch2(surface) at the end — the surface, not its container | `0x100461d8` |
| `wined3d_surface_blt` | before the FBO check: return `WINED3D_OK` if the destination is latch2 (ScaleWindow / ORM backbuffer), then acquire a context, cursor_sync, release; latch1(dst) before `wined3d_select_blitter` | `0x1004754b`, `0x10047661` |
| `surface_depth_blt` | third DisplayROI site: the `{0, h, w, 0}` rectangle when ScaleWindow is set | `0x10054192` |
| `wined3d_device_end_scene` | no `glFlush` while DirectDraw calls are passed through (`qemu3dfx_passthru_active()`) | `0x1001b43a`; 1.8.7 `0x1001a3be` |

Version gates can name a minor version (`'1.9'`) where 1.8 and 1.9 differ.
