"""
Agent 2 — Inspector
Compares built DLLs against reference DLLs.
Primary: pefile (pure Python, always available)
Supplement: i686-w64-mingw32-objdump (brew install mingw-w64) for cross-validation
            and section-level detail pefile doesn't expose as easily.
"""

import os
import subprocess
import sys
import re
import json
from pathlib import Path
from anthropic import Anthropic
import llm_client

# Repository root: the parent of agents/, or WINED3D_PROJECT_DIR if set.
PROJECT_DIR = Path(os.environ.get("WINED3D_PROJECT_DIR") or Path(__file__).resolve().parent.parent)

REFERENCE_BASE = Path(os.environ.get(
    "QEMU3DFX_REF", Path(__file__).resolve().parent.parent / "tests" / "emu" / "reference"))

SYSTEM_PROMPT = """You are the Inspector Agent for the wined3d-windows project.
Your job is to analyze PE DLL import/export diff reports and produce actionable findings for the lead engineer.

You have deep knowledge of:
- Win32 PE DLL structure (import tables, export tables, ordinals, forwarded exports)
- Wine DLL conventions (stdcall exports, spec file format, forwarded vs real implementations)
- Win98-compatible DLL requirements (msvcrt.dll, kernel32.dll — no ucrtbase, no NT-only DLLs)
- qemu-3dfx DLL conventions (wined3d_hal_3dfx, wined3d_passthru etc.)

When given a diff report, you:
1. Classify each discrepancy by severity: CRITICAL | WARNING | INFO
2. Identify the ROOT CAUSE (missing .def entry, wrong spec stub, missing compat object, import pollution)
3. Flag any dangerous imports (ucrtbase.dll, or non-Win98-safe DLLs NOT present in the reference)
4. Prioritize findings so the lead engineer knows what to fix first

KEY RULES for this project:
- W->A API differences (GetVersionExW->A, GetModuleHandleW->A, etc.) are INTENTIONAL — classify as INFO only
- Missing msvcrt.dll linkage vs reference is expected — MinGW links CRT functions explicitly via IAT; MSVC uses intrinsics/static CRT. Classify as INFO.
- Missing kernel32/user32/gdi32 imports vs reference are expected: debug code compiled out (WINE_NO_DEBUG_MSGS), NT threading disabled (Win9x CS patch), GDI fallback path not needed for OpenGL/qemu-3dfx path. Classify as INFO.
- Extra msvcrt.dll string/math imports (memset, strcmp, strlen, sprintf, pow, exp etc.) are MinGW-specific IAT linking — INFO only.
- Extra user32 RECT helpers (IsRectEmpty, OffsetRect, SetRect, SetRectEmpty) are MinGW inline vs MSVC intrinsic difference — INFO only.
- wined3d_streaming_buffer_upload missing from d3d9 imports is EXPECTED — Wine 8.0.2 d3d9 uses the older manual vertex buffer path; reference was built from newer Wine. Not a bug.
- tool_agreement=DISAGREE_EXPORTS_ONLY means objdump import parsing differs (known artifact), not a real issue.
- Dynamic binding via GetModuleHandleA+GetProcAddress is INTENTIONAL for qemu-3dfx architecture.
- ONLY flag as CRITICAL: missing exports, ucrtbase.dll imports, or export table corruption.
- Size differences alone are INFO, not WARNING.
- If all exports match: next_action must be DONE regardless of import differences.

Severity guidelines:
- CRITICAL: Missing export / ucrtbase.dll import / export table corruption
- WARNING: Unexpected extra exports / genuinely suspicious new imports not in reference
- INFO: Import count differences, W->A differences, size differences, CRT linking style differences

Respond ONLY with valid JSON in this exact format:
{
  "dll_reports": [
    {
      "dll": "wined3d.dll",
      "overall_status": "MATCH|MINOR_DIFF|MAJOR_DIFF|FAIL",
      "export_missing": ["exports in reference but not in built"],
      "export_extra": ["exports in built but not in reference"],
      "import_missing": ["imports in reference but not in built"],
      "import_extra": ["imports in built but not in reference"],
      "dangerous_imports": ["any non-Win98-safe imports found"],
      "tool_agreement": "AGREE|DISAGREE|OBJDUMP_UNAVAILABLE",
      "findings": [
        {
          "severity": "CRITICAL|WARNING|INFO",
          "description": "what is wrong",
          "likely_cause": "root cause in build system",
          "suggested_fix": "concrete suggestion for lead engineer"
        }
      ]
    }
  ],
  "summary": "overall assessment in 2-3 sentences",
  "priority_fixes": ["ordered list of most important fixes"]
}"""


def ensure_pefile():
    try:
        import pefile  # noqa: F401
    except ImportError:
        print("[Inspector] Installing pefile...")
        subprocess.run(
            [sys.executable, "-m", "pip", "install", "pefile",
             "--break-system-packages", "-q"],
            check=True,
        )


# ── pefile helpers ────────────────────────────────────────────────────────────

def get_exports(dll_path: Path) -> list:
    """Extract exported symbol names from a PE DLL."""
    import pefile
    try:
        pe = pefile.PE(str(dll_path), fast_load=False)
        exports = []
        if hasattr(pe, "DIRECTORY_ENTRY_EXPORT"):
            for exp in pe.DIRECTORY_ENTRY_EXPORT.symbols:
                if exp.name:
                    exports.append(exp.name.decode("utf-8", errors="replace"))
        pe.close()
        return sorted(exports)
    except Exception as e:
        return [f"ERROR:{e}"]


def get_imports(dll_path: Path) -> dict:
    """Extract import table: {dll_name_lower: [function_names]}"""
    import pefile
    # Known objdump PE table header artifacts to filter out
    _OBJDUMP_ARTIFACTS = {"address", "pointer", "table", "start", "end", "rva", "hint"}
    imports = {}
    try:
        pe = pefile.PE(str(dll_path), fast_load=False)
        if hasattr(pe, "DIRECTORY_ENTRY_IMPORT"):
            for entry in pe.DIRECTORY_ENTRY_IMPORT:
                dll_name = entry.dll.decode("utf-8", errors="replace").lower()
                funcs = []
                for imp in entry.imports:
                    if imp.name:
                        name = imp.name.decode("utf-8", errors="replace")
                        if name.lower() not in _OBJDUMP_ARTIFACTS:
                            funcs.append(name)
                    else:
                        funcs.append(f"ordinal_{imp.ordinal}")
                imports[dll_name] = sorted(funcs)
        pe.close()
    except Exception as e:
        imports["ERROR"] = [str(e)]
    return imports


def get_file_info(dll_path: Path) -> dict:
    """Get basic PE file metadata."""
    import pefile
    info = {"size_kb": round(dll_path.stat().st_size / 1024, 1)}
    try:
        pe = pefile.PE(str(dll_path), fast_load=True)
        info["machine"] = hex(pe.FILE_HEADER.Machine)
        info["image_base"] = hex(pe.OPTIONAL_HEADER.ImageBase)
        info["subsystem"] = pe.OPTIONAL_HEADER.Subsystem
        info["os_version"] = (
            f"{pe.OPTIONAL_HEADER.MajorOperatingSystemVersion}"
            f".{pe.OPTIONAL_HEADER.MinorOperatingSystemVersion}"
        )
        pe.close()
    except Exception as e:
        info["parse_error"] = str(e)
    return info


# ── objdump supplement ────────────────────────────────────────────────────────

def objdump_supplement(dll_name: str, built_path: Path, ref_path: Path) -> dict:
    """
    Run objdump-based diff as a cross-check alongside pefile.
    Returns the full_diff dict from pe_tools, or an error dict.
    """
    try:
        import pe_tools
        if not pe_tools.objdump_available():
            return {"available": False,
                    "hint": "brew install mingw-w64  # provides i686-w64-mingw32-objdump"}
        result = pe_tools.full_diff(dll_name, built_path, ref_path)
        result["available"] = True
        return result
    except ImportError:
        return {"available": False, "hint": "pe_tools.py not found next to agent_inspector.py"}


# ── core comparison ───────────────────────────────────────────────────────────

WIN98_SAFE_DLLS = {
    "kernel32.dll", "user32.dll", "gdi32.dll", "advapi32.dll",
    "msvcrt.dll", "opengl32.dll", "winmm.dll", "ole32.dll",
    "ddraw.dll", "d3d8.dll", "d3d9.dll", "wined3d.dll", "ntdll.dll",
}


def compare_dll(dll_name: str, built_path: Path, ref_path: Path) -> dict:
    print(f"[Inspector] Comparing {dll_name} (pefile)...")

    built_exports = set(get_exports(built_path))
    ref_exports   = set(get_exports(ref_path))
    built_imports = get_imports(built_path)
    ref_imports   = get_imports(ref_path)
    built_info    = get_file_info(built_path)
    ref_info      = get_file_info(ref_path)

    built_import_set = {f"{dll}:{fn}" for dll, fns in built_imports.items() for fn in fns}
    ref_import_set   = {f"{dll}:{fn}" for dll, fns in ref_imports.items()   for fn in fns}

    # Only flag dangerous imports actually present in the built DLL
    # and not already in the reference (reference may intentionally import them)
    ref_import_dlls = set(ref_imports.keys())
    dangerous = [
        f"{dll}:{fn}"
        for dll, fns in built_imports.items()
        if dll not in WIN98_SAFE_DLLS and dll not in ref_import_dlls
        for fn in fns
    ]

    print(f"[Inspector] Comparing {dll_name} (objdump supplement)...")
    od = objdump_supplement(dll_name, built_path, ref_path)

    # Cross-check: if objdump is available, compare export lists
    # Cross-check exports only — objdump import parsing has known artifacts
    tool_agreement = "OBJDUMP_UNAVAILABLE"
    if od.get("available"):
        od_missing = set(od.get("exports", {}).get("missing", []))
        pf_missing = ref_exports - built_exports
        tool_agreement = "AGREE" if od_missing == pf_missing else "DISAGREE_EXPORTS_ONLY"

    return {
        "dll": dll_name,
        "built_path": str(built_path),
        "ref_path":   str(ref_path),
        "built_info": built_info,
        "ref_info":   ref_info,
        "export_missing": sorted(ref_exports - built_exports),
        "export_extra":   sorted(built_exports - ref_exports),
        "import_missing": sorted(ref_import_set - built_import_set),
        "import_extra":   sorted(built_import_set - ref_import_set),
        "dangerous_imports": dangerous,
        "tool_agreement": tool_agreement,
        "objdump": od,
        "built_imports_by_dll": {k: v for k, v in sorted(built_imports.items())},
        "ref_imports_by_dll":   {k: v for k, v in sorted(ref_imports.items())},
    }


def analyze_with_claude(comparisons: list) -> dict:
    client = llm_client.get_client()
    model  = llm_client.get_model()

    summary_data = []
    for c in comparisons:
        summary_data.append({
            "dll": c["dll"],
            "built_size_kb": c["built_info"].get("size_kb"),
            "ref_size_kb":   c["ref_info"].get("size_kb"),
            "export_missing_count": len(c["export_missing"]),
            "export_missing":       c["export_missing"][:30],
            "export_extra_count":   len(c["export_extra"]),
            "export_extra":         c["export_extra"][:10],
            "import_missing_count": len(c["import_missing"]),
            "import_missing":       c["import_missing"][:15],
            "import_extra_count":   len(c["import_extra"]),
            "import_extra":         c["import_extra"][:10],
            "dangerous_imports":    c["dangerous_imports"][:10],
            "tool_agreement":       c["tool_agreement"],
            "built_imports_dlls":   list(c["built_imports_by_dll"].keys()),
            "ref_imports_dlls":     list(c["ref_imports_by_dll"].keys()),
        })

    user_message = (
        "DLL comparison results for wined3d-windows build:\n\n"
        + json.dumps(summary_data, indent=2)
        + "\n\nAnalyze these differences and return your JSON report."
    )

    response = client.messages.create(
        model=model,
        **llm_client.generation_kwargs(4096),
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": user_message}],
    )

    raw = llm_client.response_text(response).strip()
    raw = re.sub(r"^```[a-z]*\n?", "", raw)
    raw = re.sub(r"\n?```$", "", raw)

    # Try direct parse, then extract embedded JSON object
    for candidate in [raw, (re.search(r"\{.*\}", raw, re.DOTALL) or type("", (), {"group": lambda *a: ""})()).group(0)]:
        try:
            return json.loads(candidate)
        except (json.JSONDecodeError, AttributeError):
            pass

    # Retry: ask the model to return only JSON
    print("[Inspector] Non-JSON response, retrying...")
    retry_response = client.messages.create(
        model=model,
        **llm_client.generation_kwargs(4096),
        system=SYSTEM_PROMPT,
        messages=[
            {"role": "user",      "content": user_message},
            {"role": "assistant", "content": raw},
            {"role": "user",      "content": "Return ONLY the JSON object. Start with { and end with }. No other text."},
        ],
    )
    retry_raw = llm_client.response_text(retry_response).strip()
    retry_raw = re.sub(r"^```[a-z]*\n?", "", retry_raw)
    retry_raw = re.sub(r"\n?```$", "", retry_raw)
    try:
        return json.loads(retry_raw)
    except json.JSONDecodeError:
        return {"error": "Could not parse inspector response after retry", "raw": raw[:300]}


def run(wine_version: str, built_dir=None) -> dict:
    """Main inspector run. Returns structured comparison report."""
    ensure_pefile()

    built_dir = Path(built_dir) if built_dir else \
        PROJECT_DIR / "output" / wine_version
    ref_dir = REFERENCE_BASE / wine_version

    print(f"\n{'='*60}")
    print(f"[Inspector] Wine {wine_version}")
    print(f"[Inspector] Built:     {built_dir}")
    print(f"[Inspector] Reference: {ref_dir}")
    print(f"{'='*60}")

    if not ref_dir.exists():
        return {
            "agent": "inspector",
            "wine_version": wine_version,
            "status": "ERROR",
            "error": f"Reference directory not found: {ref_dir}",
        }

    dll_names = ["wined3d.dll", "ddraw.dll", "d3d8.dll", "d3d9.dll"]
    comparisons = []
    skipped = []

    for dll_name in dll_names:
        built_path = built_dir / dll_name
        ref_path   = ref_dir   / dll_name
        if not built_path.exists():
            skipped.append({"dll": dll_name, "reason": "not built"})
            continue
        if not ref_path.exists():
            skipped.append({"dll": dll_name, "reason": "no reference"})
            continue
        comparisons.append(compare_dll(dll_name, built_path, ref_path))

    if not comparisons:
        return {
            "agent": "inspector",
            "wine_version": wine_version,
            "status": "ERROR",
            "error": "No DLL pairs to compare",
            "skipped": skipped,
        }

    print(f"[Inspector] Sending {len(comparisons)} DLL comparisons to Claude...")
    analysis = analyze_with_claude(comparisons)

    return {
        "agent": "inspector",
        "wine_version": wine_version,
        "status": "COMPLETE",
        "skipped": skipped,
        "raw_comparisons": comparisons,
        "analysis": analysis,
    }
