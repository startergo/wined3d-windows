/*
 * Stubs for Wine .spec entries that have no implementation but are exported
 * by the reference qemu-3dfx DLLs.
 *
 * d3d9:  @ stub DebugSetLevel, PSGPError, PSGPSampleTexture
 * wined3d 7.0.2+: streaming_buffer_map/unmap/upload (backported by qemu-3dfx)
 * wined3d 8.0.2: vkd3d_* functions (Vulkan library, never called on Win98)
 *
 * These are no-op returns — matching the Wine @ stub behavior where
 * the function body would return 0/S_OK and do nothing.
 */

#ifndef _WIN32
#error "This file is for Windows PE targets only"
#endif

#include <windows.h>

/* --- d3d9 stubs (Wine @ stub — never had implementations) --- */

void WINAPI DebugSetLevel(DWORD level) {}
void WINAPI PSGPError(DWORD code) {}
DWORD WINAPI PSGPSampleTexture(void *a, void *b, void *c, void *d) { return 0; }

/* --- wined3d streaming_buffer stubs (backported by qemu-3dfx for 7.0.2+) --- */

HRESULT CDECL wined3d_streaming_buffer_map(void *device, void *buffer,
    unsigned int size, unsigned int stride, unsigned int *ret_pos, void **dst_data)
{
    if (ret_pos) *ret_pos = 0;
    if (dst_data) *dst_data = NULL;
    return 0x80004005; /* E_FAIL */
}

void CDECL wined3d_streaming_buffer_unmap(void *buffer) {}

HRESULT CDECL wined3d_streaming_buffer_upload(void *device, void *buffer,
    const void *data, unsigned int size, unsigned int stride, unsigned int *ret_pos)
{
    if (ret_pos) *ret_pos = 0;
    return 0x80004005; /* E_FAIL */
}

/* --- vkd3d stubs (Vulkan library, never called on Win98) --- */

void *CDECL vkd3d_create_device(void *a, void *b) { return NULL; }
void *CDECL vkd3d_create_image_resource(void *a, void *b) { return NULL; }
void *CDECL vkd3d_create_instance(void *a, void *b) { return NULL; }
void *CDECL vkd3d_create_root_signature_deserializer(void *a, void *b) { return NULL; }
void *CDECL vkd3d_create_versioned_root_signature_deserializer(void *a, void *b) { return NULL; }
void *CDECL vkd3d_get_device_parent(void *a) { return NULL; }
unsigned int CDECL vkd3d_get_dxgi_format(unsigned int f) { return 0; }
void *CDECL vkd3d_get_vk_device(void *a) { return NULL; }
unsigned int CDECL vkd3d_get_vk_format(unsigned int f) { return 0; }
void *CDECL vkd3d_get_vk_physical_device(void *a) { return NULL; }
unsigned int CDECL vkd3d_get_vk_queue_family_index(void *a) { return 0; }
void *CDECL vkd3d_instance_decref(void *a) { return NULL; }
void *CDECL vkd3d_instance_from_device(void *a) { return NULL; }
void *CDECL vkd3d_instance_get_vk_instance(void *a) { return NULL; }
unsigned int CDECL vkd3d_instance_incref(void *a) { return 0; }
void CDECL vkd3d_release_vk_queue(void *a) {}
void *CDECL vkd3d_resource_decref(void *a) { return NULL; }
unsigned int CDECL vkd3d_resource_incref(void *a) { return 0; }
HRESULT CDECL vkd3d_serialize_root_signature(void *a, unsigned int b, void *c, void *d) { return 0; }
HRESULT CDECL vkd3d_serialize_versioned_root_signature(void *a, unsigned int b, void *c, void *d) { return 0; }
HRESULT CDECL vkd3d_shader_compile(void *a, void *b, void *c, void *d, unsigned int e, unsigned int f, unsigned int g, void *h) { return 0; }
HRESULT CDECL vkd3d_shader_convert_root_signature(void *a, unsigned int b, void *c, void *d) { return 0; }
int CDECL vkd3d_shader_find_signature_element(void *a, const char *b, unsigned int c, unsigned int d) { return -1; }
void CDECL vkd3d_shader_free_messages(void *a) {}
void CDECL vkd3d_shader_free_root_signature(void *a) {}
void CDECL vkd3d_shader_free_scan_descriptor_info(void *a) {}
void CDECL vkd3d_shader_free_shader_code(void *a) {}
void CDECL vkd3d_shader_free_shader_signature(void *a) {}
int CDECL vkd3d_shader_get_supported_source_types(unsigned int a, unsigned int b, void *c) { return 0; }
int CDECL vkd3d_shader_get_supported_target_types(unsigned int a, unsigned int b, void *c) { return 0; }
void CDECL vkd3d_shader_get_version(unsigned int *a, unsigned int *b) { if(a) *a = 0; if(b) *b = 0; }
HRESULT CDECL vkd3d_shader_parse_input_signature(void *a, unsigned int b, void *c) { return 0; }
HRESULT CDECL vkd3d_shader_parse_root_signature(void *a, unsigned int b, void *c) { return 0; }
HRESULT CDECL vkd3d_shader_preprocess(void *a, unsigned int b, void *c, void *d, void *e, void *f) { return 0; }
HRESULT CDECL vkd3d_shader_scan(void *a, unsigned int b, void *c, void *d) { return 0; }
HRESULT CDECL vkd3d_shader_serialize_root_signature(void *a, unsigned int b, void *c, void *d) { return 0; }
void CDECL vkd3d_acquire_vk_queue(void *a) {}
