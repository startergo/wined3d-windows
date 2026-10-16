/*
 * vkd3d-shader stubs for Wine >= 9 wined3d on Win98.
 *
 * Wine 9's wined3d links the bundled vkd3d-shader library, but only for
 * Direct3D 10+ shaders (shader_sm4.c: DXBC parsing), the Vulkan backend
 * (shader_spirv.c, never linked here - see vk_stubs.c) and shader
 * disassembly in debug traces (shader.c: shader_trace). Direct3D <= 9 shaders
 * (SM1-3 bytecode) are handled by wined3d itself, so instead of porting the
 * whole shader compiler to Win98 these entry points report "not implemented".
 */
#include <stddef.h>
#include <stdint.h>
#include <stdarg.h>
#include "vkd3d_shader.h"

const char *vkd3d_shader_get_version(unsigned int *major, unsigned int *minor)
{
    if (major) *major = 0;
    if (minor) *minor = 0;
    return "vkd3d-shader (Win98 stub: Direct3D 10+ shaders unsupported)";
}

int vkd3d_shader_compile(const struct vkd3d_shader_compile_info *compile_info,
        struct vkd3d_shader_code *out, char **messages)
{
    if (out) { out->code = NULL; out->size = 0; }
    if (messages) *messages = NULL;
    return VKD3D_ERROR_NOT_IMPLEMENTED;
}

int vkd3d_shader_scan(const struct vkd3d_shader_compile_info *compile_info, char **messages)
{
    if (messages) *messages = NULL;
    return VKD3D_ERROR_NOT_IMPLEMENTED;
}

int vkd3d_shader_parse_dxbc(const struct vkd3d_shader_code *dxbc, uint32_t flags,
        struct vkd3d_shader_dxbc_desc *desc, char **messages)
{
    if (desc) { desc->section_count = 0; desc->sections = NULL; }
    if (messages) *messages = NULL;
    return VKD3D_ERROR_NOT_IMPLEMENTED;
}

void vkd3d_shader_free_messages(char *messages) {}
void vkd3d_shader_free_shader_code(struct vkd3d_shader_code *code) {}
void vkd3d_shader_free_scan_descriptor_info(struct vkd3d_shader_scan_descriptor_info *info) {}
void vkd3d_shader_free_dxbc(struct vkd3d_shader_dxbc_desc *dxbc) {}
