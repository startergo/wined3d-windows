/* Vulkan stubs for Wine 6.0+ -- Win98 doesn't use Vulkan, these are never called */

#include <windows.h>

struct wined3d_context_vk;
struct wined3d_adapter_vk;
struct wined3d_bo_slab_entry;
struct wined3d_fence;

enum wined3d_compare_op { WINED3D_COMPARE_OP_NEVER_STUB };

BOOL wined3d_adapter_vk_create(const void *a, UINT b, const void *c, const void *d, struct wined3d_adapter_vk **e) { return 0; }
UINT wined3d_adapter_vk_get_memory_type_index(struct wined3d_adapter_vk *a, unsigned int b, DWORD c) { return ~0u; }
void *wined3d_context_vk_get_command_buffer(struct wined3d_context_vk *a) { return NULL; }
void wined3d_context_vk_end_current_render_pass(struct wined3d_context_vk *a) { }
void wined3d_context_vk_submit_command_buffer(struct wined3d_context_vk *a) { }
BOOL wined3d_context_vk_wait_command_buffer(struct wined3d_context_vk *a) { return 0; }
void wined3d_context_vk_poll_command_buffers(struct wined3d_context_vk *a) { }
BOOL wined3d_context_vk_allocate_memory(struct wined3d_context_vk *a, unsigned int b, SIZE_T c, void *d) { return 0; }
void wined3d_context_vk_destroy_memory(struct wined3d_context_vk *a, void *b) { }
BOOL wined3d_context_vk_create_bo(struct wined3d_context_vk *a, SIZE_T b, unsigned int c, DWORD d, struct wined3d_bo_slab_entry **e) { return 0; }
void wined3d_context_vk_destroy_bo(struct wined3d_context_vk *a, struct wined3d_bo_slab_entry *b) { }
void wined3d_context_vk_destroy_allocator_block(struct wined3d_context_vk *a, void *b) { }
void *wined3d_context_vk_get_render_pass(struct wined3d_context_vk *a, const void *b) { return NULL; }
void wined3d_context_vk_destroy_framebuffer(struct wined3d_context_vk *a, void *b) { }
void wined3d_context_vk_destroy_image(struct wined3d_context_vk *a, void *b) { }
void wined3d_context_vk_destroy_image_view(struct wined3d_context_vk *a, void *b) { }
void wined3d_context_vk_destroy_buffer_view(struct wined3d_context_vk *a, void *b) { }
void wined3d_context_vk_image_barrier(struct wined3d_context_vk *a, const void *b, unsigned int c, unsigned int d, unsigned int e, unsigned int f, unsigned int g) { }
BOOL wined3d_context_vk_allocate_query(struct wined3d_context_vk *a, unsigned int b) { return 0; }
void wined3d_context_vk_add_pending_query(struct wined3d_context_vk *a, struct wined3d_fence *b) { }
void wined3d_context_vk_accumulate_pending_queries(struct wined3d_context_vk *a) { }
void wined3d_context_vk_remove_pending_queries(struct wined3d_context_vk *a) { }
void wined3d_spirv_shader_backend_cleanup(void *a) { }
enum wined3d_compare_op vk_compare_op_from_wined3d(enum wined3d_compare_op op) { return op; }

/* Wine 7.0+ renamed functions and added new ones */
void wined3d_context_vk_destroy_vk_image_view(struct wined3d_context_vk *a, void *b) { }
void wined3d_context_vk_destroy_vk_buffer_view(struct wined3d_context_vk *a, void *b) { }
void wined3d_context_vk_destroy_vk_framebuffer(struct wined3d_context_vk *a, void *b) { }
BOOL wined3d_context_vk_create_image(struct wined3d_context_vk *a, const void *b, void *c) { return 0; }
void *wined3d_context_vk_create_vk_descriptor_set(struct wined3d_context_vk *a, void *b) { return NULL; }
void *wined3d_context_vk_get_pipeline_layout(struct wined3d_context_vk *a, const void *b) { return NULL; }
void adapter_vk_copy_bo_address(void *a, const void *b) { }
unsigned int vk_access_mask_from_buffer_usage(unsigned int a) { return 0; }
unsigned int vk_pipeline_stage_mask_from_buffer_usage(unsigned int a) { return 0; }

/* Wine 8.0+ additional VK stubs */
void wined3d_context_vk_destroy_vk_event(struct wined3d_context_vk *a, void *b) { }
