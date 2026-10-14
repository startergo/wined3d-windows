
/* ---- appended by the Dockerfile for Wine 7.x: streaming buffer API ------
 * Backport of the Wine 8.0 declarations (include/wine/wined3d.h); the
 * implementation is docker/qemu3dfx_streaming_buffer.c.  Own guard because
 * this block sits after the header's include guard. */
#ifndef QEMU3DFX_WINED3D_STREAMING_BUFFER
#define QEMU3DFX_WINED3D_STREAMING_BUFFER

#include <string.h>

struct wined3d_streaming_buffer
{
    struct wined3d_buffer *buffer;
    unsigned int pos;
    unsigned int bind_flags;
};

HRESULT __cdecl wined3d_streaming_buffer_map(struct wined3d_device *device,
        struct wined3d_streaming_buffer *buffer, unsigned int size, unsigned int stride,
        unsigned int *ret_pos, void **ret_data);
void __cdecl wined3d_streaming_buffer_unmap(struct wined3d_streaming_buffer *buffer);
HRESULT __cdecl wined3d_streaming_buffer_upload(struct wined3d_device *device, struct wined3d_streaming_buffer *buffer,
        const void *data, unsigned int size, unsigned int stride, unsigned int *ret_pos);

static inline void wined3d_streaming_buffer_init(struct wined3d_streaming_buffer *buffer, unsigned int bind_flags)
{
    memset(buffer, 0, sizeof(*buffer));
    buffer->bind_flags = bind_flags;
}

static inline void wined3d_streaming_buffer_cleanup(struct wined3d_streaming_buffer *buffer)
{
    if (buffer->buffer)
        wined3d_buffer_decref(buffer->buffer);
    buffer->buffer = NULL;
    buffer->pos = 0;
}

#endif /* QEMU3DFX_WINED3D_STREAMING_BUFFER */
