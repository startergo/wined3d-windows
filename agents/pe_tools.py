"""
PE inspection helpers using i686-w64-mingw32-objdump (Homebrew mingw-w64).
Used as a supplement/fallback alongside pefile in agent_inspector.py.

Install: brew install mingw-w64
"""

import subprocess
import re
import shutil
from pathlib import Path

OBJDUMP = "i686-w64-mingw32-objdump"


def objdump_available() -> bool:
    return shutil.which(OBJDUMP) is not None


def _run(args: list[str], dll_path: Path) -> str:
    """Run objdump and return stdout, or empty string on error."""
    try:
        result = subprocess.run(
            [OBJDUMP] + args + [str(dll_path)],
            capture_output=True, text=True, timeout=30
        )
        return result.stdout
    except Exception:
        return ""


def get_exports(dll_path: Path) -> list[str]:
    """
    Extract exported symbol names via objdump -p.
    Returns sorted list of names (no ordinals, no addresses).
    """
    output = _run(["-p"], dll_path)
    exports = []
    in_exports = False
    for line in output.splitlines():
        if "[Ordinal/Name Pointer] Table" in line:
            in_exports = True
            continue
        if in_exports:
            # Lines look like:  	[  0] wined3d_buffer_create
            m = re.match(r"\s+\[\s*\d+\]\s+(\S+)", line)
            if m:
                exports.append(m.group(1))
            elif line.strip() == "" or line.startswith("\t["):
                pass
            elif re.match(r"\t[A-Z]", line):
                # New section header — done with exports
                break
    return sorted(exports)


def get_imports(dll_path: Path) -> dict[str, list[str]]:
    """
    Extract import table via objdump -p.
    Returns {dll_name_lower: [function_names]}.
    """
    output = _run(["-p"], dll_path)
    imports: dict[str, list[str]] = {}
    current_dll = None

    for line in output.splitlines():
        # DLL Name line
        m = re.match(r"\s+DLL Name: (.+)", line)
        if m:
            current_dll = m.group(1).strip().lower()
            imports.setdefault(current_dll, [])
            continue
        # Symbol name line (under current DLL)
        if current_dll:
            m = re.match(r"\s+\S+ ([A-Za-z_][A-Za-z0-9_@]+)", line)
            if m:
                imports[current_dll].append(m.group(1))

    return {k: sorted(v) for k, v in imports.items()}


def get_section_info(dll_path: Path) -> list[dict]:
    """
    Return section headers via objdump -h.
    Useful for verifying .text, .data, .idata, .edata sizes.
    """
    output = _run(["-h"], dll_path)
    sections = []
    for line in output.splitlines():
        # Idx Name          Size      VMA       LMA       File off  Algn
        m = re.match(
            r"\s*\d+\s+(\S+)\s+([0-9a-f]+)\s+([0-9a-f]+)\s+([0-9a-f]+)\s+([0-9a-f]+)",
            line
        )
        if m:
            sections.append({
                "name": m.group(1),
                "size": int(m.group(2), 16),
                "vma": int(m.group(3), 16),
                "file_off": int(m.group(5), 16),
            })
    return sections


def get_header_info(dll_path: Path) -> dict:
    """
    Return PE file header fields via objdump -p (private headers).
    """
    output = _run(["-p"], dll_path)
    info = {}
    for line in output.splitlines():
        for key, pattern in [
            ("image_base",    r"ImageBase\s+([0-9a-fx]+)"),
            ("subsystem",     r"Subsystem\s+(\S+.*)"),
            ("machine",       r"Machine\s+(\S+)"),
            ("os_version",    r"MajorOSystemVersion\s+(\d+)"),
            ("linker_version",r"MajorLinkerVersion\s+(\d+)"),
        ]:
            m = re.search(pattern, line)
            if m and key not in info:
                info[key] = m.group(1).strip()
    return info


def compare_exports(built_path: Path, ref_path: Path) -> dict:
    """
    High-level export comparison between two DLLs using objdump.
    Returns dict with missing/extra lists.
    """
    built = set(get_exports(built_path))
    ref = set(get_exports(ref_path))
    return {
        "missing": sorted(ref - built),
        "extra": sorted(built - ref),
        "match_count": len(built & ref),
        "built_total": len(built),
        "ref_total": len(ref),
    }


def compare_imports(built_path: Path, ref_path: Path) -> dict:
    """
    High-level import comparison between two DLLs using objdump.
    Returns per-DLL diff.
    """
    built = get_imports(built_path)
    ref = get_imports(ref_path)

    all_dlls = set(built) | set(ref)
    result = {}
    for dll in sorted(all_dlls):
        b_syms = set(built.get(dll, []))
        r_syms = set(ref.get(dll, []))
        if b_syms != r_syms:
            result[dll] = {
                "missing": sorted(r_syms - b_syms),
                "extra": sorted(b_syms - r_syms),
            }
    return result


def full_diff(dll_name: str, built_path: Path, ref_path: Path) -> dict:
    """
    Complete objdump-based diff for one DLL pair.
    Designed to supplement pefile results in agent_inspector.
    """
    if not objdump_available():
        return {"error": f"{OBJDUMP} not found — install via: brew install mingw-w64"}

    export_diff = compare_exports(built_path, ref_path)
    import_diff = compare_imports(built_path, ref_path)
    built_hdr = get_header_info(built_path)
    ref_hdr = get_header_info(ref_path)
    built_sections = get_section_info(built_path)
    ref_sections = get_section_info(ref_path)

    # Flag dangerous imports (anything not Win98-safe)
    WIN98_SAFE = {
        "kernel32.dll", "user32.dll", "gdi32.dll", "advapi32.dll",
        "msvcrt.dll", "opengl32.dll", "winmm.dll", "ole32.dll",
        "ddraw.dll", "d3d8.dll", "d3d9.dll", "wined3d.dll", "ntdll.dll",
    }
    built_imports = get_imports(built_path)
    dangerous = [
        f"{dll}:{fn}"
        for dll, fns in built_imports.items()
        if dll not in WIN98_SAFE
        for fn in fns
    ]

    return {
        "dll": dll_name,
        "tool": OBJDUMP,
        "exports": export_diff,
        "imports": import_diff,
        "dangerous_imports": dangerous,
        "built_header": built_hdr,
        "ref_header": ref_hdr,
        "built_sections": built_sections,
        "ref_sections": ref_sections,
    }
