#!/usr/bin/env python3
"""qemu3dfx_callsites.py <build-dir> <wine-version>

Insert the calls into the qemu-3dfx module (qemu3dfx_hooks.c) at the places
where the reference qemu-3dfx wined3d.dll makes them.

Every edit is scoped to one function and positioned on an anchor; each must
match exactly once or the build fails, so a Wine version whose source moved
can never silently lose a call site.  The per-site evidence (reference
address, Wine function) is in the comment of each entry and in
tools/re/CALLSITES.md.

Versions without a verified site list are reported and left untouched.
"""
import os, re, sys

INCLUDE = '#include "qemu3dfx.h"\n'

# File-level helpers inserted after the include (only into files that get
# edits).  "Is this texture its swapchain's back or front buffer" is the
# reference's recurring test (texture+0xa8 -> swapchain, swapchain+0x14 ->
# back_buffers[0], swapchain+0x18 -> front_buffer); the NULL checks are ours.
ON_SWAPCHAIN = (
    'static inline BOOL qemu3dfx_texture_on_swapchain(const struct wined3d_texture *texture)\n'
    '{\n'
    '    const struct wined3d_swapchain *swapchain;\n'
    '\n'
    '    if (!texture || !(swapchain = texture->swapchain))\n'
    '        return FALSE;\n'
    '    return (swapchain->back_buffers && swapchain->back_buffers[0] == texture)\n'
    '            || swapchain->front_buffer == texture;\n'
    '}\n')
DDRAW_INCLUDE = '#include "qemu3dfx_ddraw.h"\n'
ENUM_EMULATION = r'''
/* qemu-3dfx: device name/description live in writable static memory (some
 * games modify them).  Ramp then RGB, as the reference d3d3_EnumDevices
 * enumerates them; FALSE when the application stops the enumeration. */
static CHAR qemu3dfx_device_name[64], qemu3dfx_device_description[64];

static BOOL qemu3dfx_enum_emulation_devices(LPD3DENUMDEVICESCALLBACK callback, void *context,
        const D3DDEVICEDESC *device_desc1)
{
    D3DDEVICEDESC hal_desc, hel_desc;

    strcpy(qemu3dfx_device_description, "Ramp Direct3D emulation");
    strcpy(qemu3dfx_device_name, "Ramp Emulation");
    hal_desc = *device_desc1;
    hel_desc = *device_desc1;
    hal_desc.dpcLineCaps.dwTextureCaps &= ~(D3DPTEXTURECAPS_POW2
            | D3DPTEXTURECAPS_NONPOW2CONDITIONAL | D3DPTEXTURECAPS_PERSPECTIVE);
    hal_desc.dpcTriCaps.dwTextureCaps &= ~(D3DPTEXTURECAPS_POW2
            | D3DPTEXTURECAPS_NONPOW2CONDITIONAL | D3DPTEXTURECAPS_PERSPECTIVE);
    hal_desc.dcmColorModel = 0;
    hal_desc.dwFlags = 0;
    if (callback((GUID *)&IID_IDirect3DRampDevice, qemu3dfx_device_description,
            qemu3dfx_device_name, &hal_desc, &hel_desc, context) != D3DENUMRET_OK)
        return FALSE;

    strcpy(qemu3dfx_device_description, "RGB Direct3D emulation");
    strcpy(qemu3dfx_device_name, "RGB Emulation");
    hal_desc = *device_desc1;
    hel_desc = *device_desc1;
    hal_desc.dcmColorModel = 0;
    hal_desc.dpcLineCaps.dwTextureCaps &= ~(D3DPTEXTURECAPS_POW2
            | D3DPTEXTURECAPS_NONPOW2CONDITIONAL | D3DPTEXTURECAPS_PERSPECTIVE);
    hal_desc.dpcTriCaps.dwTextureCaps &= ~(D3DPTEXTURECAPS_POW2
            | D3DPTEXTURECAPS_NONPOW2CONDITIONAL | D3DPTEXTURECAPS_PERSPECTIVE);
    hal_desc.dwDevCaps &= ~(D3DDEVCAPS_HWTRANSFORMANDLIGHT | D3DDEVCAPS_DRAWPRIMITIVES2EX
            | D3DDEVCAPS_HWRASTERIZATION);
    hel_desc.dwDevCaps &= ~(D3DDEVCAPS_HWTRANSFORMANDLIGHT | D3DDEVCAPS_DRAWPRIMITIVES2EX
            | D3DDEVCAPS_HWRASTERIZATION);
    hal_desc.dwFlags = 0;
    return callback((GUID *)&IID_IDirect3DRGBDevice, qemu3dfx_device_description,
            qemu3dfx_device_name, &hal_desc, &hel_desc, context) == D3DENUMRET_OK;
}
'''

PRELUDE = {
    'ddraw.c': ENUM_EMULATION,
    'texture.c': ON_SWAPCHAIN,
    'context_gl.c': ON_SWAPCHAIN +
        '\n'
        'static inline BOOL qemu3dfx_latch1_on_swapchain(void)\n'
        '{\n'
        '    return qemu3dfx_texture_on_swapchain((const struct wined3d_texture *)qemu3dfx_latch1(0));\n'
        '}\n',
}
# 4.12 / 5.0: the quad blitters live in context.c, the FBO blit in surface.c
PRELUDE['context.c'] = PRELUDE['context_gl.c']
PRELUDE['surface.c'] = ON_SWAPCHAIN

# (file, function-definition regex, anchor regex, 'before'|'after', code, versions)
# versions: set of Wine major versions the entry was verified for.
V78 = {7, 8}
V678 = {6, 7, 8}
ALL = {1, 2, 3, 4, 5, 6, 7, 8}
EDITS = [
    # DllMain(DLL_PROCESS_ATTACH): store hInstDLL in latch0 before
    # wined3d_dll_init (ref 8.0.2 0x10089223); load the module config at the
    # same moment the reference reads it (inside wined3d_dll_init).
    ('wined3d_main.c', r'BOOL WINAPI DllMain\(', r'return wined3d_dll_init\(inst\);', 'before',
     'qemu3dfx_latch0((ULONG_PTR)inst);\nqemu3dfx_load_config();', V678),

    # wined3d_device_set_cursor_properties: hand the new cursor to the host
    # right after it replaces the old one (ref 0x100429b1).
    ('device.c', r'HRESULT CDECL wined3d_device_set_cursor_properties\(', r'device->hardwareCursor = cursor;',
     'after', 'qemu3dfx_set_host_cursor(cursor);', V678),

    # wined3d_context_gl_set_current: UseLastContextTid keeps the previous
    # context untouched (ref 0x100207c4).
    ('context_gl.c', r'BOOL wined3d_context_gl_set_current\(', r'if \(old == context_gl\)\s*\{[^{}]*\}',
     'after', 'if (qemu3dfx_use_last_context_tid())\n    old = context_gl;', V678),

    # wined3d_swapchain_gl_get_context: UseLastContextTid reuses the last
    # context instead of creating one per thread (ref 0x1006c583).
    ('swapchain.c', r'struct wined3d_context_gl \*wined3d_swapchain_gl_get_context\(',
     r'/\* Create a new context for the thread\. \*/', 'before',
     'if (qemu3dfx_use_last_context_tid() && swapchain_gl->context_count)\n'
     '    return swapchain_gl->contexts[swapchain_gl->context_count - 1];', {5, 6, 7}),
    ('swapchain.c', r'struct wined3d_context_gl \*wined3d_swapchain_gl_get_context\(',
     r'/\* Create a new context for the thread\. \*/', 'before',
     'if (qemu3dfx_use_last_context_tid() && device->context_count)\n'
     '    return wined3d_context_gl(device->contexts[device->context_count - 1]);', {8}),

    # swapchain_gl_set_swap_interval (inlined into swapchain_gl_present in
    # the reference, 0x1006d091): SwapInterval overrides after the clamp.
    ('swapchain.c', r'static void swapchain_gl_set_swap_interval\(',
     r'swap_interval = swap_interval <= 4 \? swap_interval : 1;', 'after',
     'qemu3dfx_swap_interval((int *)&swap_interval);', V678),

    # swapchain_gl_present: remember the front buffer once it is the drawable
    # (latch1, ref 0x1006d167).
    ('swapchain.c', r'static void swapchain_gl_present\(',
     r'wined3d_texture_validate_location\(swapchain->front_buffer, 0, WINED3D_LOCATION_DRAWABLE\);',
     'after', 'qemu3dfx_latch1((ULONG_PTR)swapchain->front_buffer);', V678),

    # swapchain_blit: latch1 on the presented texture, cursor sync after the
    # blit to the drawable (ref 0x1006e195 / 0x1006e20f).
    ('swapchain.c', r'static void swapchain_blit\(',
     r'wined3d_texture_validate_location\(texture, 0, WINED3D_LOCATION_DRAWABLE\);', 'after',
     'qemu3dfx_latch1((ULONG_PTR)texture);', V678),
    ('swapchain.c', r'static void swapchain_blit\(',
     r'device->blitter->ops->blitter_blit\([^;]*WINED3D_LOCATION_DRAWABLE[^;]*\);', 'after',
     'qemu3dfx_cursor_sync(wined3d_context_gl(context)->window);', V678),

    # wined3d_texture_load_drawable (inlined into wined3d_texture_gl_load_location
    # in the reference, 0x10072767 / 0x100727d7): latch1 once the texture is
    # in TEXTURE_RGB, cursor sync after the blit to the drawable.
    ('texture.c', r'static BOOL wined3d_texture_load_drawable\(',
     r'wined3d_texture_load_location\(texture, sub_resource_idx, context, WINED3D_LOCATION_TEXTURE_RGB\);',
     'after', 'qemu3dfx_latch1((ULONG_PTR)texture);', V678),
    ('texture.c', r'static BOOL wined3d_texture_load_drawable\(',
     r'device->blitter->ops->blitter_blit\([^;]*WINED3D_LOCATION_DRAWABLE[^;]*\);', 'after',
     'qemu3dfx_cursor_sync(wined3d_context_gl(context)->window);', V678),

    # wined3d_texture_gl_load_sysmem: latch2 on a texture read back from the
    # drawable (ref 0x100726d3: the read_from_framebuffer call guarded by
    # !DEPTH_STENCIL && locations & DRAWABLE, passing draw_binding).
    ('texture.c', r'static BOOL wined3d_texture_gl_load_sysmem\(',
     r'texture2d_read_from_framebuffer\([^;]*draw_binding[^;]*\);', 'after',
     'qemu3dfx_latch2((ULONG_PTR)&texture_gl->t);', V678),

    # wined3d_texture_validate_location: Silent Hill 4 video fix, right after
    # the locations update, on sub-resource 0 like the reference (0x1006a7bb).
    ('texture.c', r'void wined3d_texture_validate_location\(', r'sub_resource->locations \|= location;',
     'after', 'qemu3dfx_sysmem_count_quirk(texture->sub_resources[0].locations, '
              '(LONG *)&texture->sysmem_count);', V678),

    # ---- ScaleWindow / DisplayROI / OverrideModeWidth ----------------------

    # struct wined3d_output gains the size the application asked for, which
    # the reference keeps at output+0x2c..0x38 (zero-initialised with the
    # output; written by set_display_mode, read by get_display_mode).
    ('wined3d_private.h', r'struct wined3d_output\n\{', r'enum wined3d_format_id screen_format;', 'after',
     'RECT qemu3dfx_mode_rect;', V678),

    # wined3d_output_set_display_mode (ref 0x1003f985): the "redundant mode"
    # shortcut only applies when OverrideModeWidth leaves the current mode
    # alone; the requested size is recorded; with ScaleWindow the desktop
    # mode (at the requested depth, through OverrideModeWidth) replaces the
    # requested one when the scale window covers it.
    ('directx.c', r'HRESULT CDECL wined3d_output_set_display_mode\(',
     r'else if \(equal_display_mode\(&current_mode, &new_mode\)\)', 'replace',
     'else if (equal_display_mode(&current_mode, &new_mode) && !qemu3dfx_override_mode(&current_mode))', V678),
    ('directx.c', r'HRESULT CDECL wined3d_output_set_display_mode\(',
     r'TRACE\("Skipping redundant mode setting call\.\\n"\);\s*output->screen_format = new_format_id;', 'after',
     'SetRect(&output->qemu3dfx_mode_rect, 0, 0, mode->width, mode->height);', V678),
    ('directx.c', r'HRESULT CDECL wined3d_output_set_display_mode\(',
     r'(?<=\n)    ret = ChangeDisplaySettingsEx[AW]\(', 'before',
     'SetRect(&output->qemu3dfx_mode_rect, 0, 0, mode->width, mode->height);\n'
     '{\n'
     '    RECT qemu3dfx_window;\n'
     '\n'
     '    if (qemu3dfx_scale_window(&qemu3dfx_window, NULL, NULL))\n'
     '    {\n'
     '        current_mode.dmBitsPerPel = new_mode.dmBitsPerPel;\n'
     '        qemu3dfx_override_mode(&current_mode);\n'
     '        if (qemu3dfx_window.right >= output->qemu3dfx_mode_rect.right\n'
     '                && qemu3dfx_window.bottom >= output->qemu3dfx_mode_rect.bottom)\n'
     '            new_mode = current_mode;\n'
     '    }\n'
     '}', V678),

    # wined3d_output_get_display_mode (ref 0x1003e95c): with ScaleWindow,
    # report the size the application asked for (or the scale window's), and
    # record the reported size if nothing was recorded yet.
    ('directx.c', r'HRESULT CDECL wined3d_output_get_display_mode\(',
     r'mode->format_id = pixelformat_for_depth\(m\.dmBitsPerPel\);', 'after',
     '{\n'
     '    struct wined3d_output *qemu3dfx_output = (struct wined3d_output *)output;\n'
     '    RECT qemu3dfx_window;\n'
     '\n'
     '    if (qemu3dfx_scale_window(&qemu3dfx_window, NULL, NULL))\n'
     '    {\n'
     '        if (qemu3dfx_output->qemu3dfx_mode_rect.right && qemu3dfx_output->qemu3dfx_mode_rect.bottom)\n'
     '        {\n'
     '            mode->width = qemu3dfx_output->qemu3dfx_mode_rect.right;\n'
     '            mode->height = qemu3dfx_output->qemu3dfx_mode_rect.bottom;\n'
     '        }\n'
     '        else if (qemu3dfx_window.top & 1)\n'
     '        {\n'
     '            mode->width = qemu3dfx_window.right;\n'
     '            mode->height = qemu3dfx_window.bottom;\n'
     '        }\n'
     '    }\n'
     '    if (!qemu3dfx_output->qemu3dfx_mode_rect.right && !qemu3dfx_output->qemu3dfx_mode_rect.bottom)\n'
     '    {\n'
     '        qemu3dfx_output->qemu3dfx_mode_rect.right = mode->width;\n'
     '        qemu3dfx_output->qemu3dfx_mode_rect.bottom = mode->height;\n'
     '    }\n'
     '}', V678),

    # wined3d_restore_display_modes (ref 0x1003ec37): with ScaleWindow the
    # registry mode is always restored.
    ('directx.c', r'HRESULT CDECL wined3d_restore_display_modes\(',
     r'if \(!equal_display_mode\(&current_mode, &registry_mode\)\)', 'replace',
     'if (qemu3dfx_scale_window_value() != 0xffffffff || !equal_display_mode(&current_mode, &registry_mode))', V678),

    # texture2d_get_blt_info (ref 0x1006a494): with ScaleWindow, texture
    # coordinates come from the blit rectangle passed through DisplayROI.
    ('texture.c', r'void texture2d_get_blt_info\(',
     r'level = sub_resource_idx % texture_gl->t\.level_count;', 'before',
     'RECT qemu3dfx_roi;\n'
     '\n'
     'if (qemu3dfx_scale_window_value() != 0xffffffff)\n'
     '{\n'
     '    qemu3dfx_roi = *rect;\n'
     '    qemu3dfx_display_roi(&qemu3dfx_roi);\n'
     '    rect = &qemu3dfx_roi;\n'
     '}', V678),

    # texture2d_blt_fbo (ref 0x1006e94c / 0x1006e995 / 0x1006ea70): a
    # full-width blit of the presented frame to the top of its swapchain's
    # drawable is stretched to the screen, its source through DisplayROI ...
    ('texture.c', r'static void texture2d_blt_fbo\(',
     r'wined3d_texture_translate_drawable_coords\(dst_texture, context_gl->window, &d\);\s*dst_rect = &d;\s*\}',
     'after',
     'RECT qemu3dfx_window, qemu3dfx_screen, qemu3dfx_src, qemu3dfx_dst;\n'
     'DWORD qemu3dfx_filter = 0;\n'
     '\n'
     'if (!src_rect->left && src_rect->right > src_rect->bottom\n'
     '        && !(dst_location == WINED3D_LOCATION_DRAWABLE ? dst_rect->bottom : dst_rect->top)\n'
     '        && qemu3dfx_texture_on_swapchain(dst_texture)\n'
     '        && qemu3dfx_scale_window(&qemu3dfx_window, &qemu3dfx_screen, &qemu3dfx_filter)\n'
     '        && qemu3dfx_window.right >= src_rect->right && qemu3dfx_window.bottom >= src_rect->bottom)\n'
     '{\n'
     '    qemu3dfx_src = *src_rect;\n'
     '    qemu3dfx_dst = *dst_rect;\n'
     '    qemu3dfx_dst.right = qemu3dfx_screen.right;\n'
     '    if (dst_location == WINED3D_LOCATION_DRAWABLE)\n'
     '    {\n'
     '        qemu3dfx_dst.top = qemu3dfx_screen.bottom;\n'
     '        qemu3dfx_dst.bottom = qemu3dfx_screen.top;\n'
     '    }\n'
     '    else\n'
     '    {\n'
     '        qemu3dfx_dst.top = qemu3dfx_screen.top;\n'
     '        qemu3dfx_dst.bottom = qemu3dfx_screen.bottom;\n'
     '    }\n'
     '    qemu3dfx_display_roi(&qemu3dfx_src);\n'
     '    if (qemu3dfx_filter == 2)\n'
     '        gl_filter = GL_LINEAR;\n'
     '    src_rect = &qemu3dfx_src;\n'
     '    dst_rect = &qemu3dfx_dst;\n'
     '}', V678),
    # ... and with ScaleWindow only that full-frame blit flushes.
    ('texture.c', r'static void texture2d_blt_fbo\(',
     r'if \(dst_location == WINED3D_LOCATION_DRAWABLE && dst_texture->swapchain->front_buffer == dst_texture\)',
     'replace',
     'if (dst_location == WINED3D_LOCATION_DRAWABLE\n'
     '        && (qemu3dfx_scale_window_value() == 0xffffffff || (!src_rect->top && !dst_rect->bottom))\n'
     '        && dst_texture->swapchain->front_buffer == dst_texture)', V678),

    # fbo_blitter_blit (ref 0x1007c0e1): a fallback blit from the texture
    # last read back from the drawable (latch2) is dropped with ScaleWindow
    # or with OffscreenRenderingMode=backbuffer.
    ('texture.c', r'static DWORD fbo_blitter_blit\(',
     r'if \(!\(next = blitter->next\)\)\s*\{[^{}]*\}', 'after',
     'if (src_texture == (struct wined3d_texture *)qemu3dfx_latch2(0)\n'
     '        && (qemu3dfx_scale_window_value() != 0xffffffff\n'
     '        || wined3d_settings.offscreen_rendering_mode == ORM_BACKBUFFER))\n'
     '    return dst_location;', V678),

    # wined3d_context_gl_draw_textured_quad / _draw_shaded_quad (ref
    # 0x10027e6d, 0x1002adb2): a blit of the presented frame from (0,0) is
    # drawn with the viewport stretched to the screen (ScaleWindow can also
    # ask for linear filtering), and the viewport is put back afterwards.
    ('context_gl.c', r'void wined3d_context_gl_draw_textured_quad\(',
     r'texture2d_get_blt_info\(texture_gl, sub_resource_idx, src_rect, &info\);', 'before',
     'if (!src_rect->top && !src_rect->left && qemu3dfx_latch1_on_swapchain())\n'
     '{\n'
     '    RECT qemu3dfx_window, qemu3dfx_screen;\n'
     '\n'
     '    if (qemu3dfx_scale_window(&qemu3dfx_window, &qemu3dfx_screen, (DWORD *)&filter)\n'
     '            && qemu3dfx_window.right >= src_rect->right && qemu3dfx_window.bottom >= src_rect->bottom)\n'
     '        gl_info->gl_ops.gl.p_glViewport(qemu3dfx_screen.left, qemu3dfx_screen.top,\n'
     '                qemu3dfx_screen.right, qemu3dfx_screen.bottom);\n'
     '}', V678),
    ('context_gl.c', r'void wined3d_context_gl_draw_textured_quad\(',
     r'wined3d_context_gl_bind_texture\(context_gl, info\.bind_target, 0\);', 'after',
     'if (!src_rect->top && !src_rect->left && qemu3dfx_latch1_on_swapchain())\n'
     '{\n'
     '    RECT qemu3dfx_window;\n'
     '\n'
     '    if (qemu3dfx_scale_window(&qemu3dfx_window, NULL, NULL)\n'
     '            && qemu3dfx_window.right >= src_rect->right && qemu3dfx_window.bottom >= src_rect->bottom)\n'
     '        gl_info->gl_ops.gl.p_glViewport(src_rect->left, src_rect->top, src_rect->right, src_rect->bottom);\n'
     '}', V678),
    ('context_gl.c', r'void wined3d_context_gl_draw_shaded_quad\(',
     r'texture2d_get_blt_info\(texture_gl, sub_resource_idx, src_rect, &info\);', 'before',
     'if (!src_rect->top && !src_rect->left && qemu3dfx_latch1_on_swapchain())\n'
     '{\n'
     '    RECT qemu3dfx_window, qemu3dfx_screen;\n'
     '\n'
     '    if (qemu3dfx_scale_window(&qemu3dfx_window, &qemu3dfx_screen, (DWORD *)&filter)\n'
     '            && qemu3dfx_window.right >= src_rect->right && qemu3dfx_window.bottom >= src_rect->bottom)\n'
     '        gl_info->gl_ops.gl.p_glViewport(qemu3dfx_screen.left, qemu3dfx_screen.top,\n'
     '                qemu3dfx_screen.right, qemu3dfx_screen.bottom);\n'
     '}', V678),
    ('context_gl.c', r'void wined3d_context_gl_draw_shaded_quad\(',
     r'wined3d_context_gl_bind_texture\(context_gl, info\.bind_target, 0\);', 'after',
     'if (!src_rect->top && !src_rect->left && qemu3dfx_latch1_on_swapchain())\n'
     '{\n'
     '    RECT qemu3dfx_window;\n'
     '\n'
     '    if (qemu3dfx_scale_window(&qemu3dfx_window, NULL, NULL)\n'
     '            && qemu3dfx_window.right >= src_rect->right && qemu3dfx_window.bottom >= src_rect->bottom)\n'
     '        gl_info->gl_ops.gl.p_glViewport(src_rect->left, src_rect->top, src_rect->right, src_rect->bottom);\n'
     '}', V678),

    # ---- ddraw -------------------------------------------------------------

    # The six DirectDraw entry points route through ddthru first, keyed on
    # their caller (ref 8.0.2: 0x1001586a, 0x10009480, 0x10015929, 0x1000f48c,
    # 0x1000f343, 0x1000f26a; qemu3dfx_ddthru.c).
    ('ddraw/main.c', r'HRESULT WINAPI (DECLSPEC_HOTPATCH )?DirectDrawCreate\(GUID', r'TRACE\(', 'before-first',
     'if (qemu3dfx_ddthru(__builtin_return_address(0)))\n    return qemu3dfx_ddthru_DirectDrawCreate(driver_guid, (void **)ddraw, outer);', ALL),
    ('ddraw/main.c', r'HRESULT WINAPI (DECLSPEC_HOTPATCH )?DirectDrawCreateEx\(GUID', r'TRACE\(', 'before-first',
     'if (qemu3dfx_ddthru(__builtin_return_address(0)))\n    return qemu3dfx_ddthru_DirectDrawCreateEx(driver_guid, ddraw, interface_iid, outer);', ALL),
    ('ddraw/ddraw.c', r'HRESULT WINAPI (DECLSPEC_HOTPATCH )?DirectDrawCreateClipper\(DWORD', r'TRACE\(', 'before-first',
     'if (qemu3dfx_ddthru(__builtin_return_address(0)))\n    return qemu3dfx_ddthru_DirectDrawCreateClipper(flags, (void **)clipper, outer_unknown);', ALL),
    ('ddraw/main.c', r'HRESULT WINAPI (DECLSPEC_HOTPATCH )?DirectDrawEnumerateA\(', r'TRACE\(', 'before-first',
     'if (qemu3dfx_ddthru(__builtin_return_address(0)))\n    return qemu3dfx_ddthru_DirectDrawEnumerateA((void *)callback, context);', ALL),
    ('ddraw/main.c', r'HRESULT WINAPI (DECLSPEC_HOTPATCH )?DirectDrawEnumerateExA\(', r'TRACE\(', 'before-first',
     'if (qemu3dfx_ddthru(__builtin_return_address(0)))\n    return qemu3dfx_ddthru_DirectDrawEnumerateExA((void *)callback, context, flags);', ALL),
    ('ddraw/main.c', r'HRESULT WINAPI (DECLSPEC_HOTPATCH )?GetSurfaceFromDC\(HDC', r'TRACE\(', 'before-first',
     'if (qemu3dfx_ddthru(__builtin_return_address(0)))\n    return qemu3dfx_ddthru_GetSurfaceFromDC(dc, (void **)surface, device_dc);', {2, 3, 4, 5, 6, 7, 8}),

    # ddraw_set_cooperative_level (ref 0x10005505): OverrideCoopFullscreen
    # rewrites the level after the device-window teardown, unless called
    # with restore_mode_on_normal.
    ('ddraw/ddraw.c', r'static HRESULT ddraw_set_cooperative_level\(',
     r'if \(\(cooplevel & DDSCL_EXCLUSIVE\) && exclusive_window != window\)', 'before',
     'if (!restore_mode_on_normal)\n    wined3d_override_cooplevel(&cooplevel);', {5, 6, 7, 8}),
    # 1.8.7 .. 4.12.1: inside the fullscreen-change block, before the new
    # fullscreen window is set up (ref 1.8.7 0x10005810).
    ('ddraw/ddraw.c', r'static HRESULT ddraw_set_cooperative_level\(',
     r'if \(cooplevel & DDSCL_FULLSCREEN\)\s*\{\s*struct wined3d_display_mode', 'before',
     'if (!restore_mode_on_normal)\n    wined3d_override_cooplevel(&cooplevel);', {1, 2, 3, 4}),

    # d3d3_EnumDevices (ref 0x10006453): qemu-3dfx enumerates Ramp and RGB
    # emulation devices before the HAL (EnumHalLast, the default, or any
    # Direct3D version but 1) or after it, and the HAL advertises POW2
    # textures when the 3dfx HAL is on.  Whole body replaced.
    ('ddraw/ddraw.c', r'static HRESULT WINAPI d3d3_EnumDevices\(', None, 'body',
     '{\n'
     '    static CHAR wined3d_description[] = "Wine D3DDevice using WineD3D and OpenGL";\n'
     '    struct ddraw *ddraw = impl_from_IDirect3D3(iface);\n'
     '    D3DDEVICEDESC device_desc1, hal_desc, hel_desc;\n'
     '    D3DDEVICEDESC7 device_desc7;\n'
     '    HRESULT hr;\n'
     '\n'
     '    TRACE("iface %p, callback %p, context %p.\\n", iface, callback, context);\n'
     '\n'
     '    if (!callback)\n'
     '        return DDERR_INVALIDPARAMS;\n'
     '\n'
     '    wined3d_mutex_lock();\n'
     '\n'
     '    if (FAILED(hr = ddraw_get_d3dcaps(ddraw, &device_desc7)))\n'
     '    {\n'
     '        wined3d_mutex_unlock();\n'
     '        return hr;\n'
     '    }\n'
     '    ddraw_d3dcaps1_from_7(&device_desc1, &device_desc7);\n'
     '\n'
     '    if ((wined3d_enum_hal_last() == 1 || ddraw->d3dversion != 1)\n'
     '            && !qemu3dfx_enum_emulation_devices(callback, context, &device_desc1))\n'
     '        goto done;\n'
     '\n'
     '    strcpy(qemu3dfx_device_name, "Direct3D HAL");\n'
     '    hal_desc = device_desc1;\n'
     '    hel_desc = device_desc1;\n'
     '    hel_desc.dcmColorModel = 0;\n'
     '    hel_desc.dpcLineCaps.dwTextureCaps &= ~(D3DPTEXTURECAPS_POW2\n'
     '            | D3DPTEXTURECAPS_NONPOW2CONDITIONAL | D3DPTEXTURECAPS_PERSPECTIVE);\n'
     '    hel_desc.dpcTriCaps.dwTextureCaps &= ~(D3DPTEXTURECAPS_POW2\n'
     '            | D3DPTEXTURECAPS_NONPOW2CONDITIONAL | D3DPTEXTURECAPS_PERSPECTIVE);\n'
     '    hel_desc.dwDevCaps &= ~(D3DDEVCAPS_HWTRANSFORMANDLIGHT | D3DDEVCAPS_DRAWPRIMITIVES2EX);\n'
     '    if (wined3d_hal_3dfx())\n'
     '        hal_desc.dpcTriCaps.dwTextureCaps |= D3DPTEXTURECAPS_POW2;\n'
     '    if (callback((GUID *)&IID_IDirect3DHALDevice, wined3d_description,\n'
     '            qemu3dfx_device_name, &hal_desc, &hel_desc, context) != D3DENUMRET_OK)\n'
     '        goto done;\n'
     '\n'
     '    if (!wined3d_enum_hal_last() && ddraw->d3dversion == 1)\n'
     '        qemu3dfx_enum_emulation_devices(callback, context, &device_desc1);\n'
     '\n'
     'done:\n'
     '    wined3d_mutex_unlock();\n'
     '    return D3D_OK;\n'
     '}', ALL),

    # ddraw7_EnumDisplayModes (ref 0x10007e76): with the 3dfx HAL only 16-bit
    # RGB modes are enumerated.
    ('ddraw/ddraw.c', r'static HRESULT WINAPI ddraw7_EnumDisplayModes\(',
     r'ddrawformat_from_wined3dformat\(&pixelformat, mode\.format_id\);', 'after',
     'if (wined3d_hal_3dfx() && (!(pixelformat.dwFlags & DDPF_RGB) || pixelformat.u1.dwRGBBitCount != 16))\n'
     '    continue;', ALL),

    # ddraw_surface1_Unlock (ref 0x10010d2d; the other versions delegate to it): BlitFpsLimit after the unlock.
    ('ddraw/surface.c', r'ddraw_surface1_Unlock\(IDirectDrawSurface \*iface',
     r'wined3d_mutex_unlock\(\);', 'after', 'wined3d_blit_fpslimit();', V678),
    # 1.8.7 .. 5.0.5: ddraw_surface7_Unlock does the work (ref 1.8.7 0x1000f077).
    ('ddraw/surface.c', r'ddraw_surface7_Unlock\(IDirectDrawSurface7 \*iface',
     r'wined3d_mutex_unlock\(\);', 'after', 'wined3d_blit_fpslimit();', {1, 2, 3, 4, 5}),

    # ddraw_surface7_Flip, 1.8.7 .. 3.0.5 (ref 1.8.7 0x10010d5e): FlipFpsLimit
    # after the final unlock.
    ('ddraw/surface.c', r'ddraw_surface7_Flip\(IDirectDrawSurface7 \*iface',
     r'wined3d_mutex_unlock\(\);(?=\s*return hr;\s*\}\s*$)', 'after', 'wined3d_flip_fpslimit();', {1, 2, 3}),

    # d3d_device_init (ref 0x1001518c): the render target's view is made
    # bindable before it is set.
    ('ddraw/device.c', r'static HRESULT d3d_device_init\(',
     r'rtv = ddraw_surface_get_rendertarget_view\(target\);', 'after',
     'wined3d_override_rendertarget_view(rtv);', V78),
    # 1.8.7 .. 6.0.4 pass the view inline (ref 1.8.7 0x1000ac96).
    ('ddraw/device.c', r'static HRESULT d3d_device_init\(',
     r'if \(FAILED\(hr = wined3d_device_set_rendertarget_view\(', 'before',
     'wined3d_override_rendertarget_view(ddraw_surface_get_rendertarget_view(target));', {1, 2, 3, 4, 5, 6}),

    # ddraw_surface_wined3d_object_destroyed (ref 0x10014e9c): DDSurfaceHeap
    # keeps a zeroed 20-byte stub instead of freeing the surface, so stale
    # pointers held by the application read zeros (NULL check is ours).
    ('ddraw/surface.c', r'ddraw_surface_wined3d_object_destroyed\(void \*parent\)',
     r'heap_free\(surface\);', 'replace',
     'if (wined3d_surface_ddheap())\n'
     '{\n'
     '    void *stub = heap_realloc(surface, 0x14);\n'
     '\n'
     '    if (stub)\n'
     '        memset(stub, 0, 0x14);\n'
     '}\n'
     'else\n'
     '    heap_free(surface);', V678),
]


# ---- wined3d 4.12 / 5.0 -----------------------------------------------------
# Reference 4.12.1 / 5.0.5 call the module from the same Wine functions as
# 6.0.4 (CALLSITES.md), which still live under their older names and files.
# Most edits are the 6.0+ ones renamed; the display-mode edits are written
# out because wined3d_set_adapter_display_mode still handles the registry
# restore (mode == NULL) and clips the cursor (ref 5.0.5 0x10033ccd).
V45 = {4, 5}
_RENAME_FUNC = {
    r'HRESULT CDECL wined3d_output_get_display_mode\(': r'HRESULT CDECL wined3d_get_adapter_display_mode\(',
    r'static void texture2d_blt_fbo\(': r'void texture2d_blt_fbo\(',
}
_SKIP_45 = ('swap_interval = swap_interval', 'equal_display_mode', 'Skipping redundant',
            'ChangeDisplaySettingsEx', 'screen_format;', 'Create a new context for the thread',
            'if \\(old == context_gl\\)', 'pixelformat_for_depth')


def _derive_45():
    out = []
    for f, fre, anchor, where, code, vers in EDITS:
        if '/' in f or 6 not in vers or any(k in (anchor or '') for k in _SKIP_45):
            continue
        if f == 'context_gl.c':
            f = 'context.c'
        if f == 'texture.c' and ('texture2d_blt_fbo' in fre or 'fbo_blitter_blit' in fre):
            f = 'surface.c'
        out.append((f, _RENAME_FUNC.get(fre, fre), anchor, where, code, V45))
    return out


EDITS += _derive_45() + [
    # context selection with UseLastContextTid (4.12: context_set_current /
    # swapchain_get_context; 5.0: wined3d_context_gl_set_current, and the
    # lookup shares the 6/7 edit above).
    ('context.c', r'BOOL context_set_current\(', r'if \(old == ctx\)\s*\{[^{}]*\}', 'after',
     'if (qemu3dfx_use_last_context_tid())\n    old = ctx;', {3, 4}),
    ('context.c', r'BOOL wined3d_context_gl_set_current\(', r'if \(old == context_gl\)\s*\{[^{}]*\}', 'after',
     'if (qemu3dfx_use_last_context_tid())\n    old = context_gl;', {5}),
    ('swapchain.c', r'struct wined3d_context \*swapchain_get_context\(',
     r'/\* Create a new context for the thread \*/', 'before',
     'if (qemu3dfx_use_last_context_tid() && swapchain->num_contexts)\n'
     '    return swapchain->context[swapchain->num_contexts - 1];', {3, 4}),

    # struct wined3d_adapter holds the requested mode size (ref 5.0.5
    # adapter+0x37e0).
    ('wined3d_private.h', r'struct wined3d_adapter\n\{', r'enum wined3d_format_id screen_format;', 'after',
     'RECT qemu3dfx_mode_rect;', V45),

    # wined3d_set_adapter_display_mode: OverrideModeWidth is consulted right
    # after the size/depth comparison; the requested size (from new_mode, so
    # the registry restore works too) is recorded; the redundant-mode
    # shortcut clips the cursor to it; ScaleWindow keeps the desktop mode;
    # with ScaleWindow the final clip uses the requested size.
    ('directx.c', r'HRESULT CDECL wined3d_set_adapter_display_mode\(',
     r'&& current_mode\.dmBitsPerPel == new_mode\.dmBitsPerPel', 'after',
     '&& !qemu3dfx_override_mode(&current_mode)', V45),
    ('directx.c', r'HRESULT CDECL wined3d_set_adapter_display_mode\(',
     r'TRACE\("Skipping redundant mode setting call\.\\n"\);(\s*adapter->screen_format = new_format_id;)?', 'after',
     'SetRect(&adapter->qemu3dfx_mode_rect, 0, 0, new_mode.dmPelsWidth, new_mode.dmPelsHeight);\n'
     'ClipCursor(&adapter->qemu3dfx_mode_rect);', V45),
    ('directx.c', r'HRESULT CDECL wined3d_set_adapter_display_mode\(',
     r'(?<=\n)    ret = ChangeDisplaySettingsEx[AW]\(', 'before',
     'SetRect(&adapter->qemu3dfx_mode_rect, 0, 0, new_mode.dmPelsWidth, new_mode.dmPelsHeight);\n'
     '{\n'
     '    RECT qemu3dfx_window;\n'
     '\n'
     '    if (qemu3dfx_scale_window(&qemu3dfx_window, NULL, NULL))\n'
     '    {\n'
     '        current_mode.dmBitsPerPel = new_mode.dmBitsPerPel;\n'
     '        qemu3dfx_override_mode(&current_mode);\n'
     '        if (qemu3dfx_window.right >= adapter->qemu3dfx_mode_rect.right\n'
     '                && qemu3dfx_window.bottom >= adapter->qemu3dfx_mode_rect.bottom)\n'
     '            new_mode = current_mode;\n'
     '    }\n'
     '}', V45),
    ('directx.c', r'HRESULT CDECL wined3d_set_adapter_display_mode\(',
     r'SetRect\(&clip_rc, 0, 0, new_mode\.dmPelsWidth, new_mode\.dmPelsHeight\);', 'replace',
     'if (qemu3dfx_scale_window_value() != 0xffffffff)\n'
     '    SetRect(&clip_rc, 0, 0, adapter->qemu3dfx_mode_rect.right, adapter->qemu3dfx_mode_rect.bottom);\n'
     'else\n'
     '    SetRect(&clip_rc, 0, 0, new_mode.dmPelsWidth, new_mode.dmPelsHeight);', V45),

    # wined3d_get_adapter_display_mode: as 6.0+'s get_display_mode, on the
    # adapter.
    ('directx.c', r'HRESULT CDECL wined3d_get_adapter_display_mode\(',
     r'mode->format_id = pixelformat_for_depth\(m\.dmBitsPerPel\);', 'after',
     '{\n'
     '    struct wined3d_adapter *qemu3dfx_adapter = (struct wined3d_adapter *)adapter;\n'
     '    RECT qemu3dfx_window;\n'
     '\n'
     '    if (qemu3dfx_scale_window(&qemu3dfx_window, NULL, NULL))\n'
     '    {\n'
     '        if (qemu3dfx_adapter->qemu3dfx_mode_rect.right && qemu3dfx_adapter->qemu3dfx_mode_rect.bottom)\n'
     '        {\n'
     '            mode->width = qemu3dfx_adapter->qemu3dfx_mode_rect.right;\n'
     '            mode->height = qemu3dfx_adapter->qemu3dfx_mode_rect.bottom;\n'
     '        }\n'
     '        else if (qemu3dfx_window.top & 1)\n'
     '        {\n'
     '            mode->width = qemu3dfx_window.right;\n'
     '            mode->height = qemu3dfx_window.bottom;\n'
     '        }\n'
     '    }\n'
     '    if (!qemu3dfx_adapter->qemu3dfx_mode_rect.right && !qemu3dfx_adapter->qemu3dfx_mode_rect.bottom)\n'
     '    {\n'
     '        qemu3dfx_adapter->qemu3dfx_mode_rect.right = mode->width;\n'
     '        qemu3dfx_adapter->qemu3dfx_mode_rect.bottom = mode->height;\n'
     '    }\n'
     '}', V45),
]


# ---- wined3d 3.0 ------------------------------------------------------------
# Reference 3.0.5 (CALLSITES.md): Wine 3.0 is surface-based.  latch1 holds
# the last surface blitted to a drawable, latch2 the texture last read back
# from one; the presented-frame test is "latch1's container is its
# swapchain's front buffer" (no back-buffer check in this version).
V3 = {3}
EDITS += [e[:5] + ({3},) for e in EDITS if 4 in e[5] and (
              e[0] in ('wined3d_main.c', 'device.c', 'wined3d_private.h', 'directx.c')
              or 'wined3d_texture_validate_location' in e[1])] + [
    # wined3d_swapchain_update_swap_interval_cs (ref 0x1004a87f): SwapInterval
    # after the present-interval mapping.
    ('swapchain.c', r'static void wined3d_swapchain_update_swap_interval_cs\(',
     r'if \(gl_info->supported\[WGL_EXT_SWAP_CONTROL\]\)', 'before',
     'qemu3dfx_swap_interval(&swap_interval);', V3),

    # wined3d_surface_blt (ref 0x1004d4aa / 0x1004d529): the final blit
    # records its destination surface and syncs the host cursor.
    ('surface.c', r'HRESULT wined3d_surface_blt\(',
     r'valid_locations = device->blitter->ops->blitter_blit\(device->blitter, blit_op, context,', 'before',
     'qemu3dfx_latch1((ULONG_PTR)dst_surface);', V3),
    ('surface.c', r'HRESULT wined3d_surface_blt\(',
     r'valid_locations = device->blitter->ops->blitter_blit\(device->blitter, blit_op, context,[^;]*;', 'after',
     'qemu3dfx_cursor_sync(context->win_handle);', V3),

    # surface_load_drawable (inlined into surface_load_location in the
    # reference, 0x1005028f / 0x100502f6).
    ('surface.c', r'surface_load_drawable\(',
     r'wined3d_texture_load_location\(texture, sub_resource_idx, context, WINED3D_LOCATION_TEXTURE_RGB\);',
     'after', 'qemu3dfx_latch1((ULONG_PTR)surface);', V3),
    ('surface.c', r'surface_load_drawable\(',
     r'device->blitter->ops->blitter_blit\([^;]*WINED3D_TEXF_POINT\);', 'after',
     'qemu3dfx_cursor_sync(context->win_handle);', V3),

    # read_from_framebuffer (ref 0x1005019a): latch2 on the texture read back.
    ('surface.c', r'static void read_from_framebuffer\(',
     r'if \(restore_rt\)\s*context_restore\(context, restore_rt\);(?=\s*\}\s*$)', 'after',
     'qemu3dfx_latch2((ULONG_PTR)surface->container);', V3),

    # draw_textured_quad (ref 0x10046144): viewport stretched to the screen
    # for the presented frame, texture coordinates from the source through
    # DisplayROI, viewport put back afterwards.
    ('surface.c', r'void draw_textured_quad\(',
     r'surface_get_blt_info\(src_surface->texture_target, src_rect,', 'before',
     'RECT qemu3dfx_roi;\n'
     'const RECT *qemu3dfx_src = src_rect;\n'
     '\n'
     'if (!src_rect->top && !src_rect->left && qemu3dfx_latch1_front_buffer())\n'
     '{\n'
     '    RECT qemu3dfx_window, qemu3dfx_screen;\n'
     '\n'
     '    if (qemu3dfx_scale_window(&qemu3dfx_window, &qemu3dfx_screen, (DWORD *)&filter)\n'
     '            && qemu3dfx_window.right >= src_rect->right && qemu3dfx_window.bottom >= src_rect->bottom)\n'
     '        gl_info->gl_ops.gl.p_glViewport(qemu3dfx_screen.left, qemu3dfx_screen.top,\n'
     '                qemu3dfx_screen.right, qemu3dfx_screen.bottom);\n'
     '}\n'
     'if (qemu3dfx_scale_window_value() != 0xffffffff)\n'
     '{\n'
     '    qemu3dfx_roi = *src_rect;\n'
     '    qemu3dfx_display_roi(&qemu3dfx_roi);\n'
     '    qemu3dfx_src = &qemu3dfx_roi;\n'
     '}', V3),
    ('surface.c', r'void draw_textured_quad\(',
     r'surface_get_blt_info\(src_surface->texture_target, src_rect,', 'replace',
     'surface_get_blt_info(src_surface->texture_target, qemu3dfx_src,', V3),
    ('surface.c', r'void draw_textured_quad\(',
     r'context_bind_texture\(context, info\.bind_target, 0\);', 'after',
     'if (!src_rect->top && !src_rect->left && qemu3dfx_latch1_front_buffer())\n'
     '{\n'
     '    RECT qemu3dfx_window;\n'
     '\n'
     '    if (qemu3dfx_scale_window(&qemu3dfx_window, NULL, NULL)\n'
     '            && qemu3dfx_window.right >= src_rect->right && qemu3dfx_window.bottom >= src_rect->bottom)\n'
     '        gl_info->gl_ops.gl.p_glViewport(src_rect->left, src_rect->top, src_rect->right, src_rect->bottom);\n'
     '}', V3),

    # surface_blt_fbo (ref 0x100481e7 / 0x10048237): a full-width blit of the
    # presented frame to the top of the drawable is stretched to the screen,
    # its source through DisplayROI.
    ('surface.c', r'static void surface_blt_fbo\(',
     r'gl_info->gl_ops\.gl\.p_glColorMask\(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE\);', 'before',
     '{\n'
     '    RECT qemu3dfx_window, qemu3dfx_screen;\n'
     '    DWORD qemu3dfx_filter = 0;\n'
     '\n'
     '    if (!src_rect.left && src_rect.right > src_rect.bottom && !dst_rect.bottom\n'
     '            && dst_surface->container->swapchain\n'
     '            && dst_surface->container->swapchain->front_buffer == dst_surface->container\n'
     '            && qemu3dfx_scale_window(&qemu3dfx_window, &qemu3dfx_screen, &qemu3dfx_filter)\n'
     '            && qemu3dfx_window.right >= src_rect.right && qemu3dfx_window.bottom >= src_rect.bottom)\n'
     '    {\n'
     '        dst_rect.right = qemu3dfx_screen.right;\n'
     '        dst_rect.top = qemu3dfx_screen.bottom;\n'
     '        dst_rect.bottom = qemu3dfx_screen.top;\n'
     '        qemu3dfx_display_roi(&src_rect);\n'
     '        if (qemu3dfx_filter == 2)\n'
     '            gl_filter = GL_LINEAR;\n'
     '    }\n'
     '}', V3),

    # fbo_blitter_blit (ref 0x1004c412): no fallback blit from latch2 with
    # ScaleWindow or OffscreenRenderingMode=backbuffer.
    ('surface.c', r'static DWORD fbo_blitter_blit\(', r'if \(\(next = blitter->next\)\)', 'replace',
     'if ((next = blitter->next)\n'
     '        && !(src_surface->container == (struct wined3d_texture *)qemu3dfx_latch2(0)\n'
     '        && (qemu3dfx_scale_window_value() != 0xffffffff\n'
     '        || wined3d_settings.offscreen_rendering_mode == ORM_BACKBUFFER)))', V3),
]
PRELUDE_BY_MAJOR = {3: {'surface.c':
    'static inline BOOL qemu3dfx_latch1_front_buffer(void)\n'
    '{\n'
    '    const struct wined3d_surface *surface = (const struct wined3d_surface *)qemu3dfx_latch1(0);\n'
    '    const struct wined3d_texture *texture;\n'
    '\n'
    '    if (!surface || !(texture = surface->container) || !texture->swapchain)\n'
    '        return FALSE;\n'
    '    return texture->swapchain->front_buffer == texture;\n'
    '}\n'}}


# ---- wined3d 1.8 / 1.9 / 2.0 ------------------------------------------------
# Reference 2.0.5 (CALLSITES.md); 1.8.7 / 1.9.7 have the same profile minus
# the sysmem quirk.  Surface-based like 3.0, but latch2 holds the surface
# read back (not its container), there is no fbo_blitter_blit (its latch2
# rule and a cursor sync sit in wined3d_surface_blt), and surface_depth_blt
# has a third DisplayROI site.
V12 = {1, 2}
EDITS += [e[:5] + (V12,) for e in EDITS if 3 in e[5] and (
              e[0] in ('wined3d_main.c', 'device.c', 'wined3d_private.h', 'directx.c', 'context.c')
              or 'swapchain_get_context' in e[1]
              or 'draw_textured_quad' in e[1] or 'surface_blt_fbo' in e[1])] + [
    # sysmem quirk: 2.0 only (ref 2.0.5 0x10041ecf).
    ('texture.c', r'void wined3d_texture_validate_location\(', r'sub_resource->locations \|= location;',
     'after', 'qemu3dfx_sysmem_count_quirk(texture->sub_resources[0].locations, '
              '(LONG *)&texture->sysmem_count);', {2}),

    # swap interval: swapchain_update_swap_interval in 1.8 and 2.0 (ref 2.0.5
    # 0x10041a8d, 1.8.7 0x100489ea), context_create in 1.9 (ref 1.9.7
    # 0x10011d09).
    ('swapchain.c', r'void swapchain_update_swap_interval\(',
     r'if \(gl_info->supported\[WGL_EXT_SWAP_CONTROL\]\)', 'before',
     'qemu3dfx_swap_interval(&swap_interval);', {'1.8', 2}),
    ('context.c', r'struct wined3d_context \*context_create\(',
     r'if \(gl_info->supported\[WGL_EXT_SWAP_CONTROL\]\)', 'before',
     'qemu3dfx_swap_interval(&swap_interval);', {'1.9'}),

    # surface_load_drawable (ref 2.0.5 0x10046256 / 0x100462aa).
    ('surface.c', r'surface_load_drawable\(',
     r'(?:wined3d_texture_load_location\(texture, sub_resource_idx, context|surface_load_location\(surface, context), WINED3D_LOCATION_TEXTURE_RGB\);',
     'after', 'qemu3dfx_latch1((ULONG_PTR)surface);', V12),
    ('surface.c', r'surface_load_drawable\(',
     r'surface_blt_to_drawable\([^;]*\);', 'after',
     'qemu3dfx_cursor_sync(context->win_handle);', V12),

    # read_from_framebuffer (ref 2.0.5 0x100461d8): latch2 on the surface.
    ('surface.c', r'static void read_from_framebuffer\(',
     r'if \(restore_rt\)\s*context_restore\(context, restore_rt\);(?=\s*\}\s*$)', 'after',
     'qemu3dfx_latch2((ULONG_PTR)surface);', V12),

    # wined3d_surface_blt (ref 2.0.5 0x1004754b-0x10047597, 0x10047661).
    ('surface.c', r'HRESULT (?:CDECL )?wined3d_surface_blt\(',
     r'if \(fbo_blit_supported\(&device->adapter->gl_info, blit_op,', 'before',
     'if (dst_surface == (struct wined3d_surface *)qemu3dfx_latch2(0)\n'
     '        && (qemu3dfx_scale_window_value() != 0xffffffff\n'
     '        || wined3d_settings.offscreen_rendering_mode == ORM_BACKBUFFER))\n'
     '    return WINED3D_OK;\n'
     '{\n'
     '    struct wined3d_context *qemu3dfx_context = context_acquire(device, NULL);\n'
     '\n'
     '    qemu3dfx_cursor_sync(qemu3dfx_context->win_handle);\n'
     '    context_release(qemu3dfx_context);\n'
     '}', V12),
    ('surface.c', r'HRESULT (?:CDECL )?wined3d_surface_blt\(',
     r'blitter = wined3d_select_blitter\(&device->adapter->gl_info, &device->adapter->d3d_info, blit_op,', 'before',
     'qemu3dfx_latch1((ULONG_PTR)dst_surface);', V12),

    # wined3d_device_end_scene (ref 1.8.7 0x1001a3be, 2.0.5 0x1001b43a): no
    # glFlush while DirectDraw calls are passed through.
    ('device.c', r'HRESULT CDECL wined3d_device_end_scene\(',
     r'context->gl_info->gl_ops\.gl\.p_glFlush\(\);', 'replace',
     'if (!qemu3dfx_passthru_active())\n    context->gl_info->gl_ops.gl.p_glFlush();', V12),

    # surface_depth_blt (ref 2.0.5 0x10054192): third DisplayROI site.
    ('surface.c', r'static void surface_depth_blt\(', r'SetRect\(&rect, 0, h, w, 0\);', 'after',
     'if (qemu3dfx_scale_window_value() != 0xffffffff)\n'
     '    qemu3dfx_display_roi(&rect);', V12),
]
PRELUDE_BY_MAJOR[1] = PRELUDE_BY_MAJOR[2] = PRELUDE_BY_MAJOR[3]


# ---- the DLL instance for wined3d's hidden windows (latch0) -----------------
# The "WineD3D fake window"s use the WineD3D_OpenGL class that DllMain
# registers with the DLL's instance; on Win9x a non-global class is only
# found with the instance that registered it, so the reference passes the
# instance stored in latch0 instead of NULL (ref 8.0.2 0x1000b32f; two reads
# in every version up to 7.0.2, one in 8.0.2, where the backup window moved
# to device.c and was left alone).
_CREATE_NULL = r'WS_OVERLAPPEDWINDOW, 10, 10, 10, 10, NULL, NULL, NULL, NULL\)'
_CREATE_INST = 'WS_OVERLAPPEDWINDOW, 10, 10, 10, 10, NULL, NULL, (HINSTANCE)qemu3dfx_latch0(0), NULL)'
EDITS += [
    ('directx.c', r'static BOOL wined3d_caps_gl_ctx_create\(', _CREATE_NULL, 'replace', _CREATE_INST, {1, 2, 3}),
    ('adapter_gl.c', r'static BOOL wined3d_caps_gl_ctx_create\(', _CREATE_NULL, 'replace', _CREATE_INST,
     {4, 5, 6, 7, 8}),
    ('swapchain.c', r'HDC swapchain_get_backup_dc\(', _CREATE_NULL, 'replace', _CREATE_INST, {1, 2, 3, 4}),
    ('swapchain.c', r'HDC wined3d_swapchain_gl_get_backup_dc\(', _CREATE_NULL, 'replace', _CREATE_INST, {5, 6, 7}),
]


# ---- the wined3d announcement to the host (all versions) --------------------
# Reference (all versions; 6.0.4 at 0x1000cefb/0x1004bf84): in
# test_pbo_functionality's "no PBO" early return, wined3d identifies itself
# to qemu-3dfx through the magic glDebugMessageInsertARB channel as
# "Wine-<version> Direct3D build <__TIME__> <__DATE__>" (a 64-byte message).
# Without it the host never sees a Wine D3D client and our adapter set-up
# stopped after the GL capability probe (3DMark 99: "requires a DirectX 6
# compatible 3D-accelerator").
_ANNOUNCE = ('if (!gl_info->supported[ARB_PIXEL_BUFFER_OBJECT])\n'
             '{\n'
             '    if (gl_info->supported[ARB_DEBUG_OUTPUT])\n'
             '    {\n'
             '        char qemu3dfx_id[64] = "Wine-@WINE_VERSION@ Direct3D build " __TIME__ " " __DATE__;\n'
             '\n'
             '        GL_EXTCALL(glDebugMessageInsertARB(0x824b, 0x8251, 0x9148, ~0u, 0x40, qemu3dfx_id));\n'
             '    }\n'
             '    return;\n'
             '}')
EDITS += [
    ('directx.c', r'static void test_pbo_functionality\(',
     r'if \(!gl_info->supported\[ARB_PIXEL_BUFFER_OBJECT\]\) return;', 'replace', _ANNOUNCE, {1, 2, 3}),
    ('adapter_gl.c', r'static void test_pbo_functionality\(',
     r'if \(!gl_info->supported\[ARB_PIXEL_BUFFER_OBJECT\]\) return;', 'replace', _ANNOUNCE, {4, 5, 6, 7, 8}),
]


# ---- the DLL instance for ddraw's hidden windows (all versions) -------------
# Like wined3d's (latch0): ddraw's "Hidden D3D Window" and its device window
# use the class DllMain registers with ddraw's instance; on Win9x a
# non-global class is only found with that instance, and the reference
# passes it (ref 6.0.4 0x100054df/0x100057d6, from DllMain's instance).
# With NULL, CreateWindowExA failed on Win98 and every swapchain with it
# ("Failed to create window" / "Failed to create swapchain"): frames were
# rendered but never presented.
EDITS += [
    ('ddraw/ddraw.c', r'static HRESULT ddraw_attach_d3d_device\(', r'NULL, NULL, NULL, NULL\)', 'replace',
     'NULL, NULL, (HINSTANCE)&__ImageBase, NULL)', ALL),
    ('ddraw/ddraw.c', r'static HRESULT ddraw_set_cooperative_level\(', r'NULL, NULL, NULL, NULL\)', 'replace',
     'NULL, NULL, (HINSTANCE)&__ImageBase, NULL)', ALL),
]


def function_span(src, func_re):
    """(start, end) of the body of the first function whose definition
    matches func_re (start at its opening brace, end after its closing one)."""
    m = re.search(r'^[^\n;]*' + func_re, src, re.M)
    if not m:
        return None
    i = src.index('{', m.end() - 1)
    depth = 0
    for j in range(i, len(src)):
        if src[j] == '{':
            depth += 1
        elif src[j] == '}':
            depth -= 1
            if depth == 0:
                return i, j + 1
    return None


def indent_at(src, pos):
    line_start = src.rfind('\n', 0, pos) + 1
    return re.match(r'[ \t]*', src[line_start:]).group(0)


def main():
    build, version = sys.argv[1], sys.argv[2]
    major = int(version.split('.')[0])
    minor_key = '.'.join(version.split('.')[:2])       # e.g. '1.9': versions may name a minor
    todo = [e for e in EDITS if major in e[5] or minor_key in e[5]]
    # bisecting aids: QEMU3DFX_SKIP_WINED3D=1 drops the wined3d edits;
    # QEMU3DFX_ONLY=<i>:<j> keeps only wined3d edits i..j-1 (in list order)
    wd = [e for e in todo if '/' not in e[0]]
    if os.environ.get('QEMU3DFX_SKIP_WINED3D') == '1':
        todo = [e for e in todo if '/' in e[0]]
        print('qemu3dfx call sites: wined3d edits skipped (QEMU3DFX_SKIP_WINED3D)')
    elif os.environ.get('QEMU3DFX_ONLY'):
        keep = []
        for part in os.environ['QEMU3DFX_ONLY'].split(','):
            i, j = (int(x) for x in part.split(':'))
            keep += wd[i:j]
        todo = [e for e in todo if '/' in e[0] or e in keep]
        print('qemu3dfx call sites: wined3d edits %s of %d only' % (os.environ['QEMU3DFX_ONLY'], len(wd)))
    if not any('/' not in e[0] for e in todo):
        print('qemu3dfx call sites: wined3d sites not mapped for Wine %s yet (module functions stay unused)' % version)
    if not todo:
        return 0
    files = {}
    failed = []
    for fname, func_re, anchor_re, where, code, _ in todo:
        path = os.path.join(build, fname) if '/' in fname else os.path.join(build, 'wined3d', fname)
        src = files.get(path) or open(path).read()
        span = function_span(src, func_re)
        if not span:
            failed.append('%s: function /%s/ not found' % (fname, func_re)); continue
        if where == 'body':
            src = src[:span[0]] + code + src[span[1]:]
            files[path] = src
            continue
        body = src[span[0]:span[1]]
        hits = list(re.finditer(anchor_re, body, re.S))
        if where == 'before-first' and hits:
            hits = hits[:1]
            where = 'before'
        if len(hits) != 1:
            failed.append('%s: anchor /%s/ matched %d times in /%s/' % (fname, anchor_re, len(hits), func_re))
            continue
        h = hits[0]
        code = code.replace('@WINE_VERSION@', version)
        pos = span[0] + (h.start() if where == 'before' else h.end())
        ind = indent_at(src, span[0] + h.start())
        block = ''.join((ind + l if l else '') + '\n' for l in code.split('\n'))
        if where == 'replace':
            first, *rest = code.split('\n')
            text = first + ''.join('\n' + ind + l for l in rest)
            src = src[:span[0] + h.start()] + text + src[span[0] + h.end():]
        elif where == 'before':
            line_start = src.rfind('\n', 0, pos) + 1
            src = src[:line_start] + block + src[line_start:]
        else:
            src = src[:pos] + '\n' + block.rstrip('\n') + src[pos:]
        files[path] = src
    if failed:
        print('qemu3dfx call sites: FAILED for Wine %s:\n  %s' % (version, '\n  '.join(failed)))
        return 1
    for path, src in files.items():
        name = os.path.basename(path)
        ddraw = os.path.basename(os.path.dirname(path)) == 'ddraw'
        inc, priv = (DDRAW_INCLUDE, 'ddraw_private.h') if ddraw else (INCLUDE, 'wined3d_private.h')
        if name.endswith('.c') and inc not in src:
            table = dict(PRELUDE)
            table.update(PRELUDE_BY_MAJOR.get(major, {}))
            extra = ('\n' + table[name]) if name in table and (ddraw == (name == 'ddraw.c')) else ''
            src = src.replace('#include "%s"\n' % priv, '#include "%s"\n' % priv + inc + extra, 1)
        open(path, 'w').write(src)
    print('qemu3dfx call sites: %d inserted for Wine %s in %s' % (
        len(todo), version, ', '.join(sorted(os.path.basename(p) for p in files))))
    return 0


if __name__ == '__main__':
    sys.exit(main())
