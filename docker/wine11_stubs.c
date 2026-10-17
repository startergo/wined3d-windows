/*
 * Stubs for Wine >= 11 wined3d on Win98.
 *
 * decoder.c (the Direct3D 11 video decoding API) and texture_vk.c (Vulkan)
 * are not built - Win98 has neither D3D11 nor Vulkan - but shared code still
 * references a few of their symbols. Those paths only run with a D3D11 video
 * decoder or a Vulkan adapter, neither of which can exist here.
 * Compiled as part of wined3d (Wine's types and flags).
 */
#include "wined3d_private.h"
#include "wined3d_vk.h"

/* The null adapter's decoder ops: no decoder support. */
const struct wined3d_decoder_ops wined3d_null_decoder_ops = {0};

struct wined3d_resource * __cdecl wined3d_decoder_get_buffer(
        struct wined3d_decoder *decoder, enum wined3d_decoder_buffer_type type)
{
    return NULL;
}

void wined3d_vk_swizzle_from_color_fixup(VkComponentMapping *mapping, struct color_fixup_desc fixup)
{
    memset(mapping, 0, sizeof(*mapping));
}

const VkDescriptorImageInfo *wined3d_texture_vk_get_default_image_info(struct wined3d_texture_vk *texture_vk,
        struct wined3d_context_vk *context_vk)
{
    return NULL;
}

BOOL wined3d_texture_vk_prepare_texture(struct wined3d_texture_vk *texture_vk,
        struct wined3d_context_vk *context_vk)
{
    return FALSE;
}
