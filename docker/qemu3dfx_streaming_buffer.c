/*
 * wined3d streaming buffers for Wine 7.0.x — backport from Wine 8.0.
 *
 * Wine 8.0 added wined3d_streaming_buffer_{map,unmap,upload} (a growable
 * dynamic buffer written ring-style with NOOVERWRITE/DISCARD maps) and the
 * qemu-3dfx reference wined3d.dll 7.0.2 (exports at 0x1001fe54
 * / 0x1001ff92 / 0x1001ffb0) carries exactly this code: same
 * 512 KiB minimum, WINED3DUSAGE_DYNAMIC, GPU|MAP_W access and
 * WRITE|NOOVERWRITE / WRITE|DISCARD map flags.  Wine 7.0.2 has every API it
 * needs with unchanged signatures.  Built into wined3d for Wine 7.x only
 * (8.0+ has it natively); the matching struct and prototypes are added to
 * include/wine/wined3d.h by the Dockerfile.
 *
 * The functions below are verbatim from Wine 8.0.2 dlls/wined3d/buffer.c:
 *
 * Copyright 2002-2005 Jason Edmeades
 * Copyright 2002-2005 Raphael Junqueira
 * Copyright 2004 Christian Costa
 * Copyright 2005 Oliver Stieber
 * Copyright 2007-2011, 2013-2014 Stefan Dösinger for CodeWeavers
 * Copyright 2009-2010 Henri Verbeet for CodeWeavers
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA
 */

#include "wined3d_private.h"

WINE_DEFAULT_DEBUG_CHANNEL(d3d);

#define SB_MIN_SIZE (512 * 1024)    /* Minimum size of an allocated streaming buffer. */

static HRESULT wined3d_streaming_buffer_prepare(struct wined3d_device *device,
        struct wined3d_streaming_buffer *buffer, unsigned int min_size)
{
    struct wined3d_buffer *wined3d_buffer;
    struct wined3d_buffer_desc desc;
    unsigned int old_size = 0;
    unsigned int size;
    HRESULT hr;

    if (buffer->buffer)
    {
        old_size = buffer->buffer->resource.size;
        if (old_size >= min_size)
            return S_OK;
    }

    size = max(SB_MIN_SIZE, max(old_size * 2, min_size));
    TRACE("Growing buffer to %u bytes.\n", size);

    desc.byte_width = size;
    desc.usage = WINED3DUSAGE_DYNAMIC;
    desc.bind_flags = buffer->bind_flags;
    desc.access = WINED3D_RESOURCE_ACCESS_GPU | WINED3D_RESOURCE_ACCESS_MAP_W;
    desc.misc_flags = 0;
    desc.structure_byte_stride = 0;

    if (SUCCEEDED(hr = wined3d_buffer_create(device, &desc, NULL, NULL, &wined3d_null_parent_ops, &wined3d_buffer)))
    {
        if (buffer->buffer)
            wined3d_buffer_decref(buffer->buffer);
        buffer->buffer = wined3d_buffer;
        buffer->pos = 0;
    }
    return hr;
}

HRESULT CDECL wined3d_streaming_buffer_map(struct wined3d_device *device,
        struct wined3d_streaming_buffer *buffer, unsigned int size, unsigned int stride,
        unsigned int *ret_pos, void **ret_data)
{
    unsigned int map_flags = WINED3D_MAP_WRITE;
    struct wined3d_resource *resource;
    struct wined3d_map_desc map_desc;
    unsigned int pos, align;
    struct wined3d_box box;
    HRESULT hr;

    TRACE("device %p, buffer %p, size %u, stride %u, ret_pos %p, ret_data %p.\n",
            device, buffer, size, stride, ret_pos, ret_data);

    if (FAILED(hr = wined3d_streaming_buffer_prepare(device, buffer, size)))
        return hr;
    resource = &buffer->buffer->resource;

    pos = buffer->pos;
    if ((align = pos % stride))
        align = stride - align;
    if (pos + size + align > resource->size)
    {
        pos = 0;
        map_flags |= WINED3D_MAP_DISCARD;
    }
    else
    {
        pos += align;
        map_flags |= WINED3D_MAP_NOOVERWRITE;
    }

    wined3d_box_set(&box, pos, 0, pos + size, 1, 0, 1);
    if (SUCCEEDED(hr = wined3d_resource_map(resource, 0, &map_desc, &box, map_flags)))
    {
        *ret_pos = pos;
        *ret_data = map_desc.data;
        buffer->pos = pos + size;
    }
    return hr;
}

void CDECL wined3d_streaming_buffer_unmap(struct wined3d_streaming_buffer *buffer)
{
    wined3d_resource_unmap(&buffer->buffer->resource, 0);
}

HRESULT CDECL wined3d_streaming_buffer_upload(struct wined3d_device *device, struct wined3d_streaming_buffer *buffer,
        const void *data, unsigned int size, unsigned int stride, unsigned int *ret_pos)
{
    void *dst_data;
    HRESULT hr;

    if (SUCCEEDED(hr = wined3d_streaming_buffer_map(device, buffer, size, stride, ret_pos, &dst_data)))
    {
        memcpy(dst_data, data, size);
        wined3d_streaming_buffer_unmap(buffer);
    }
    return hr;
}
