"""
Agent 1 — Builder
Runs build-docker.sh, captures output, detects failures,
attempts safe automatic fixes, and reports structured results.
"""

import subprocess
import re
import time
from pathlib import Path
import llm_client
import os

# Repository root: the parent of agents/, or WINED3D_PROJECT_DIR if set.
PROJECT_DIR = Path(os.environ.get("WINED3D_PROJECT_DIR") or Path(__file__).resolve().parent.parent)
OUTPUT_DIR = PROJECT_DIR / "output"

SYSTEM_PROMPT = """You are the Builder Agent for the wined3d-windows project.
Your job is to analyze Docker build logs for Wine DLL compilation failures and suggest safe, targeted fixes.

You have deep knowledge of:
- MinGW-w64 cross-compilation for i686 Windows targets
- Wine DLL build system (Makefile, wine9x-support, docker/ compat layer)
- Win98-compatible PE constraints (no ucrtbase, no NT-only APIs)
- The Dockerfile RUN layer structure and patch sequences

When given build output, you:
1. Identify the exact failure point (compiler error, linker error, missing file, Docker layer issue)
2. Classify it: COMPILE_ERROR | LINK_ERROR | MISSING_FILE | DOCKER_ERROR | PATCH_FAILED | UNKNOWN
3. Suggest one specific safe fix — either a shell command to patch source/Dockerfile, or a build flag change
4. Never suggest modifying wined3d source logic — only build infrastructure, Makefile flags, or compat stubs
5. Return a structured report as JSON

SAFE fixes you may suggest:
- Adding/removing compiler flags in Makefile or config.mk
- Adding a missing sed/perl patch to Dockerfile for a new Wine version quirk
- Adjusting a .def file export list
- Adding a missing #include or macro stub to docker/ compat files
- Retrying with --no-cache

ESCALATE to lead engineer (do not attempt fix) if:
- The error is in wined3d core logic (cs.c, device.c, drawprim.c etc.)
- A new Wine API is used that has no Win98 equivalent
- The fix would require changing exported function signatures
- The log is too truncated to identify the actual error

RESPOND WITH RAW JSON ONLY. NO MARKDOWN. NO PROSE. NO EXPLANATION OUTSIDE THE JSON OBJECT.
Do not write ```json or ``` or any other text. Start your response with { and end with }.

JSON format:
{
  "status": "FAILED_FIXABLE" or "FAILED_ESCALATE",
  "failure_type": "COMPILE_ERROR" or "LINK_ERROR" or "MISSING_FILE" or "DOCKER_ERROR" or "PATCH_FAILED" or "UNKNOWN",
  "failure_file": "filename.c or null",
  "failure_line": "exact error line from log or null",
  "diagnosis": "one sentence",
  "fix_type": "SHELL_PATCH" or "MAKEFILE_FLAG" or "DOCKERFILE_PATCH" or "NO_CACHE_RETRY" or "NONE",
  "fix_target": "HOST" or "DOCKERFILE",
  "fix_command": "exact BSD sed -i '' command for host, or null",
  "fix_description": "what the fix does",
  "escalation_reason": "reason or null"
}"""


def run_build(wine_version: str, extra_args: str = "") -> dict:
    """Run build-docker.sh and capture all output."""
    cmd = [
        str(PROJECT_DIR / "build-docker.sh"),
        "--force",
        "--progress=plain",
        "--versions", wine_version,
    ]
    if extra_args:
        cmd.extend(extra_args.split())

    print(f"[Builder] Running: {' '.join(cmd)}")
    start = time.time()

    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        cwd=str(PROJECT_DIR),
        timeout=1800,
    )

    elapsed = time.time() - start
    return {
        "returncode": result.returncode,
        "stdout": result.stdout,
        "stderr": result.stderr,
        "combined": result.stdout + "\n" + result.stderr,
        "elapsed_seconds": round(elapsed),
        "success": result.returncode == 0,
    }


def check_output_dlls(wine_version: str) -> dict:
    """Check what DLLs were actually produced."""
    version_dir = OUTPUT_DIR / wine_version
    expected = ["wined3d.dll", "ddraw.dll", "d3d8.dll", "d3d9.dll"]
    found = []
    missing = []

    for dll in expected:
        path = version_dir / dll
        if path.exists():
            size = path.stat().st_size
            found.append({"name": dll, "size_kb": round(size / 1024, 1)})
        else:
            missing.append(dll)

    return {"found": found, "missing": missing, "complete": len(missing) == 0}


def extract_error_lines(log: str) -> str:
    """
    Pull the most diagnostic lines from a Docker build log:
    compiler errors, linker errors, make failures, and the last 50 lines.
    """
    lines = log.splitlines()
    error_lines = []
    keywords = (
        "error:", "Error", "undefined reference", "cannot find",
        "No such file", "fatal error", "ld returned", "make["  ,
        "FAILED", "Makefile:", "warning: ld", "unrecognized",
        "implicit declaration", "undeclared", "incompatible",
    )
    for i, line in enumerate(lines):
        if any(k in line for k in keywords):
            # Include surrounding context
            start = max(0, i - 1)
            end = min(len(lines), i + 3)
            error_lines.extend(lines[start:end])

    # Deduplicate while preserving order
    seen = set()
    unique_errors = []
    for l in error_lines:
        if l not in seen:
            seen.add(l)
            unique_errors.append(l)

    error_section = "\n".join(unique_errors[:150])  # cap at 150 error lines
    tail_section = "\n".join(lines[-60:])           # always include last 60 lines
    return f"=== ERROR LINES ===\n{error_section}\n\n=== LOG TAIL (last 60 lines) ===\n{tail_section}"


def analyze_with_claude(build_result: dict, wine_version: str, attempt: int) -> dict:
    """Send build log to Claude for diagnosis and fix suggestion."""
    import json

    client = llm_client.get_client()
    model  = llm_client.get_model()
    log_excerpt = extract_error_lines(build_result["combined"])

    user_message = f"""Wine version: {wine_version}
Build attempt: {attempt}
Exit code: {build_result['returncode']}
Elapsed: {build_result['elapsed_seconds']}s

{log_excerpt}

Return your JSON analysis now. Start with {{ and end with }}. No other text."""

    def try_parse(text: str) -> dict | None:
        text = text.strip()
        # Strip markdown fences if model ignored the instruction
        text = re.sub(r"^```[a-z]*\n?", "", text)
        text = re.sub(r"\n?```$", "", text)
        # Find the outermost JSON object even if there's leading prose
        m = re.search(r"\{.*\}", text, re.DOTALL)
        if m:
            try:
                return json.loads(m.group(0))
            except json.JSONDecodeError:
                pass
        return None

    response = client.messages.create(
        model=model,
        **llm_client.generation_kwargs(1024),
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": user_message}],
    )
    raw = llm_client.response_text(response)
    result = try_parse(raw)

    if result is None:
        # Retry: send the raw response back and ask for JSON only
        print("[Builder] Non-JSON response from model, retrying for JSON...")
        retry_msg = (
            f"Your previous response was not valid JSON:\n{raw[:500]}\n\n"
            "Return ONLY the JSON object. No explanation. No markdown. "
            "Start with { and end with }."
        )
        retry_response = client.messages.create(
            model=model,
            **llm_client.generation_kwargs(1024),
            system=SYSTEM_PROMPT,
            messages=[
                {"role": "user",      "content": user_message},
                {"role": "assistant", "content": raw},
                {"role": "user",      "content": retry_msg},
            ],
        )
        result = try_parse(llm_client.response_text(retry_response))

    if result is None:
        return {
            "status": "FAILED_ESCALATE",
            "failure_type": "UNKNOWN",
            "failure_file": None,
            "failure_line": None,
            "diagnosis": "Model did not return valid JSON after retry",
            "fix_type": "NONE",
            "fix_target": "HOST",
            "fix_command": None,
            "fix_description": None,
            "escalation_reason": "Could not parse agent response",
        }

    return result


def enforce_bsd_sed(cmd: str) -> str:
    """
    Ensure all `sed -i` calls use BSD syntax (macOS).
    GNU:  sed -i 's/old/new/' file
    BSD:  sed -i '' 's/old/new/' file
    Handles both single and double quote variants.
    """
    import re
    # Match: sed -i followed by anything that is NOT already '' or ""
    cmd = re.sub(r"\bsed\s+-i\s+(?!''|\"\"|\s)", "sed -i '' ", cmd)
    return cmd


def apply_fix(analysis: dict) -> bool:
    """Apply a safe automatic fix suggested by Claude."""
    if analysis.get("fix_type") == "NO_CACHE_RETRY":
        print("[Builder] Fix: will retry with --no-cache on next attempt")
        return True

    fix_cmd = analysis.get("fix_command")
    if not fix_cmd:
        return False

    if analysis.get("fix_type") in ("SHELL_PATCH", "MAKEFILE_FLAG", "DOCKERFILE_PATCH"):
        print(f"[Builder] Applying fix: {analysis['fix_description']}")
        print(f"[Builder] Command: {fix_cmd}")
        # Enforce BSD sed -i '' regardless of what the model generated
        safe_cmd = enforce_bsd_sed(fix_cmd)
        if safe_cmd != fix_cmd:
            print(f"[Builder] (BSD sed enforced)")
        result = subprocess.run(
            safe_cmd,
            shell=True,
            cwd=str(PROJECT_DIR),
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            print(f"[Builder] Fix command failed: {result.stderr}")
            return False
        print("[Builder] Fix applied successfully")
        return True

    return False


def run(wine_version: str, max_attempts: int = 3) -> dict:
    """Main builder loop. Returns a structured report for the lead engineer."""
    print(f"\n{'='*60}")
    print(f"[Builder] Starting build for Wine {wine_version}")
    print(f"{'='*60}")

    history = []
    no_cache = False
    build_result = {}

    for attempt in range(1, max_attempts + 1):
        print(f"\n[Builder] Attempt {attempt}/{max_attempts}")

        extra = "--no-cache" if no_cache else ""

        # Clear stale output before building so inspector never sees old artifacts
        version_dir = OUTPUT_DIR / wine_version
        if version_dir.exists():
            for stale in version_dir.glob("*.dll"):
                stale.unlink()
            print(f"[Builder] Cleared stale DLLs from {version_dir}")

        build_result = run_build(wine_version, extra)
        dll_check = check_output_dlls(wine_version)

        # If all DLLs exist after build, treat as success
        # (script may exit non-zero on warnings but still produce valid output)
        if dll_check["complete"]:
            rc = build_result['returncode']
            if build_result["success"] or rc == 0:
                print(f"[Builder] ✓ Build succeeded on attempt {attempt}")
            else:
                print(f"[Builder] ✓ All DLLs produced (rc={rc}, treating as success)")
            return {
                "agent": "builder",
                "wine_version": wine_version,
                "status": "SUCCESS",
                "attempts": attempt,
                "dlls": dll_check["found"],
                "output_dir": str(OUTPUT_DIR / wine_version),
                "history": history,
            }

        analysis = analyze_with_claude(build_result, wine_version, attempt)
        history.append({
            "attempt": attempt,
            "returncode": build_result["returncode"],
            "analysis": analysis,
        })

        print(f"[Builder] Diagnosis: {analysis.get('diagnosis')}")
        print(f"[Builder] Status: {analysis.get('status')}")

        if analysis.get("status") == "FAILED_ESCALATE":
            print("[Builder] → Escalating to lead engineer")
            return {
                "agent": "builder",
                "wine_version": wine_version,
                "status": "ESCALATED",
                "attempts": attempt,
                "dlls": dll_check["found"],
                "output_dir": str(OUTPUT_DIR / wine_version),
                "history": history,
                "escalation_reason": analysis.get("escalation_reason"),
                "last_log_tail": extract_error_lines(build_result["combined"]),
            }

        if attempt < max_attempts:
            if analysis.get("fix_type") == "NO_CACHE_RETRY":
                no_cache = True
            elif analysis.get("fix_type") in ("SHELL_PATCH", "MAKEFILE_FLAG", "DOCKERFILE_PATCH"):
                fix_cmd = analysis.get("fix_command", "")
                # Reject obviously bad auto-generated commands (placeholders, comments, multi-line)
                bad_cmd = (
                    not fix_cmd
                    or "<" in fix_cmd
                    or "PATH_TO" in fix_cmd
                    or "LINE_NUMBER" in fix_cmd
                    or fix_cmd.strip().startswith("#")
                    or "\n" in fix_cmd.strip()
                )
                if bad_cmd:
                    print("[Builder] Fix command looks auto-generated/placeholder — escalating instead of applying")
                    return {
                        "agent": "builder",
                        "wine_version": wine_version,
                        "status": "ESCALATED",
                        "attempts": attempt,
                        "dlls": dll_check["found"],
                        "output_dir": str(OUTPUT_DIR / wine_version),
                        "history": history,
                        "escalation_reason": f"Agent suggested non-applicable fix: {fix_cmd[:120]}",
                        "last_log_tail": extract_error_lines(build_result["combined"]),
                    }
                fixed = apply_fix(analysis)
                if not fixed:
                    print("[Builder] Could not apply fix automatically, escalating")
                    return {
                        "agent": "builder",
                        "wine_version": wine_version,
                        "status": "ESCALATED",
                        "attempts": attempt,
                        "dlls": dll_check["found"],
                        "output_dir": str(OUTPUT_DIR / wine_version),
                        "history": history,
                        "escalation_reason": "Automatic fix application failed",
                        "last_log_tail": extract_error_lines(build_result["combined"]),
                    }
            else:
                # Unknown fix type — escalate rather than do nothing and loop
                return {
                    "agent": "builder",
                    "wine_version": wine_version,
                    "status": "ESCALATED",
                    "attempts": attempt,
                    "dlls": dll_check["found"],
                    "output_dir": str(OUTPUT_DIR / wine_version),
                    "history": history,
                    "escalation_reason": f"No actionable auto-fix for fix_type={analysis.get('fix_type')}",
                    "last_log_tail": truncate_log(build_result["combined"], 3000),
                }

    return {
        "agent": "builder",
        "wine_version": wine_version,
        "status": "FAILED",
        "attempts": max_attempts,
        "dlls": [],
        "output_dir": str(OUTPUT_DIR / wine_version),
        "history": history,
        "last_log_tail": extract_error_lines(build_result.get("combined", "")),
        }
