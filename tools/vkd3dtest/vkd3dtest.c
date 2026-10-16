/* vkd3dtest: runtime check of vkd3d-shader on Windows 98.
 *
 * Loads vkd3d_shader_test.dll, then
 *   1. disassembles a vs_1_1 shader given as D3D9 bytecode;
 *   2. compiles an HLSL vertex shader to vs_2_0 bytecode and disassembles it.
 * vkd3d's string buffers start small, so both exercise its vsnprintf-based
 * buffer growth. Results go to COM1 (and stdout). */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#define VKD3D_SHADER_NO_PROTOTYPES
#include "vkd3d_shader.h"

static HANDLE com1;
static void out(const char *s)
{
    DWORD w;
    fputs(s, stdout);
    if (com1 != INVALID_HANDLE_VALUE) WriteFile(com1, s, (DWORD)strlen(s), &w, NULL);
}
static void outf(const char *fmt, ...)
{
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    _vsnprintf(buf, sizeof(buf) - 1, fmt, ap);
    buf[sizeof(buf) - 1] = 0;
    va_end(ap);
    out(buf);
}

static PFN_vkd3d_shader_compile p_compile;
static PFN_vkd3d_shader_free_shader_code p_free_code;
static PFN_vkd3d_shader_free_messages p_free_messages;
static PFN_vkd3d_shader_get_version p_get_version;

static int run(const char *name, const void *src, size_t size,
        enum vkd3d_shader_source_type stype, enum vkd3d_shader_target_type ttype,
        const void *next, struct vkd3d_shader_code *result)
{
    struct vkd3d_shader_compile_info info;
    char *messages = NULL;
    int rc;

    memset(&info, 0, sizeof(info));
    info.type = VKD3D_SHADER_STRUCTURE_TYPE_COMPILE_INFO;
    info.next = next;
    info.source.code = src;
    info.source.size = size;
    info.source_type = stype;
    info.target_type = ttype;
    info.log_level = VKD3D_SHADER_LOG_INFO;
    info.source_name = name;

    rc = p_compile(&info, result, &messages);
    outf("[%s] rc=%d, output %u bytes\r\n", name, rc, (unsigned)(rc >= 0 ? result->size : 0));
    if (messages && *messages) { out("  messages:\r\n"); out(messages); out("\r\n"); }
    if (messages) p_free_messages(messages);
    return rc;
}

int main(void)
{
    /* vs_1_1: dcl_position v0; m4x4 oPos, v0, c0 */
    static const DWORD vs11[] = {
        0xfffe0101, 0x0000001f, 0x80000000, 0x900f0000,
        0x00000014, 0xc00f0000, 0x90e40000, 0xa0e40000, 0x0000ffff,
    };
    static const char hlsl[] =
        "float4x4 mvp;\n"
        "float4 tint;\n"
        "struct vs_out { float4 pos : POSITION; float4 color : COLOR0; };\n"
        "vs_out main(float4 p : POSITION, float4 c : COLOR0)\n"
        "{\n"
        "    vs_out o;\n"
        "    o.pos = mul(p, mvp);\n"
        "    o.color = saturate(c * tint + 0.25);\n"
        "    return o;\n"
        "}\n";
    struct vkd3d_shader_hlsl_source_info hlsl_info;
    struct vkd3d_shader_code asm1 = {0}, bc = {0}, asm2 = {0};
    unsigned int major = 0, minor = 0;
    const char *ver;
    HMODULE lib;

    com1 = CreateFileA("COM1", GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);
    out("=== vkd3dtest ===\r\n");
    if (!(lib = LoadLibraryA("vkd3d_shader_test.dll")))
    {
        outf("LoadLibrary failed, error %lu\r\n", GetLastError());
        return 1;
    }
    p_compile = (void *)GetProcAddress(lib, "vkd3d_shader_compile");
    p_free_code = (void *)GetProcAddress(lib, "vkd3d_shader_free_shader_code");
    p_free_messages = (void *)GetProcAddress(lib, "vkd3d_shader_free_messages");
    p_get_version = (void *)GetProcAddress(lib, "vkd3d_shader_get_version");
    if (!p_compile || !p_free_code || !p_free_messages || !p_get_version)
    {
        out("missing exports\r\n");
        return 1;
    }
    ver = p_get_version(&major, &minor);
    outf("version: %s (%u.%u)\r\n", ver, major, minor);

    /* 1. disassemble D3D9 bytecode */
    if (run("vs11_disasm", vs11, sizeof(vs11), VKD3D_SHADER_SOURCE_D3D_BYTECODE,
            VKD3D_SHADER_TARGET_D3D_ASM, NULL, &asm1) >= 0)
    {
        out("--- disassembly ---\r\n");
        out((const char *)asm1.code);
        out("--- end ---\r\n");
        p_free_code(&asm1);
    }

    /* 2. HLSL -> vs_2_0 bytecode -> disassembly */
    memset(&hlsl_info, 0, sizeof(hlsl_info));
    hlsl_info.type = VKD3D_SHADER_STRUCTURE_TYPE_HLSL_SOURCE_INFO;
    hlsl_info.entry_point = "main";
    hlsl_info.profile = "vs_2_0";
    if (run("hlsl_compile", hlsl, sizeof(hlsl) - 1, VKD3D_SHADER_SOURCE_HLSL,
            VKD3D_SHADER_TARGET_D3D_BYTECODE, &hlsl_info, &bc) >= 0)
    {
        if (run("hlsl_disasm", bc.code, bc.size, VKD3D_SHADER_SOURCE_D3D_BYTECODE,
                VKD3D_SHADER_TARGET_D3D_ASM, NULL, &asm2) >= 0)
        {
            out("--- disassembly ---\r\n");
            out((const char *)asm2.code);
            out("--- end ---\r\n");
            p_free_code(&asm2);
        }
        p_free_code(&bc);
    }
    out("=== vkd3dtest done ===\r\n");
    return 0;
}
