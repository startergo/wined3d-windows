#!/usr/bin/env python3
"""
Lead Engineer — Multi-Agent Orchestrator
Coordinates Agent 1 (Builder) and Agent 2 (Inspector).
Presents combined findings, applies lead engineer fixes, and drives the iterative loop.

Usage:
    python orchestrator.py 8.0.2
    python orchestrator.py 8.0.2 --inspect-only    # skip build, inspect existing output
    python orchestrator.py 8.0.2 --build-only      # skip inspection
    python orchestrator.py 8.0.2 --max-attempts 5  # more build retries
    python orchestrator.py 8.0.2 --auto            # fully automated cycling
    python orchestrator.py 8.0.2 --max-cycles 3    # loop up to N cycles
"""

import argparse
import json
import re
import subprocess
import sys
import textwrap
from pathlib import Path
from anthropic import Anthropic
import llm_client

sys.path.insert(0, str(Path(__file__).parent))
import dockerfile_patcher
import agent_builder
import agent_inspector
import os

# Repository root: the parent of agents/, or WINED3D_PROJECT_DIR if set.
PROJECT_DIR = Path(os.environ.get("WINED3D_PROJECT_DIR") or Path(__file__).resolve().parent.parent)
REPORTS_DIR = PROJECT_DIR / "output" / "_reports"

LEAD_ENGINEER_SYSTEM = """You are the Lead Engineer for the wined3d-windows project.
You coordinate a Builder agent and an Inspector agent to iteratively improve Wine DLL builds for Win98/qemu-3dfx compatibility.

Your job is to synthesize their reports and produce clear, prioritized action items.

You have expert knowledge of:
- The wined3d-windows Dockerfile build pipeline (wine9x-support, docker/ compat objects, MinGW-w64 cross-compilation)
- Wine DLL internals for versions 1.x through 8.x
- Win98 PE DLL constraints: msvcrt.dll only, i386, IMAGE_SUBSYSTEM_WINDOWS_GUI or _DLL
- qemu-3dfx architecture (wined3d_hal_3dfx, passthrough path, DDraw hooks)

PROTECTED PATHS — agents may READ but NEVER MODIFY:
- wine9x-support/   — read-only build infrastructure, do not suggest changes to it
- Dockerfile        — only via DOCKERFILE_PATCH (handled by safe patcher, never sed)

AGENT-WRITABLE PATHS:
- docker/           — compat .c stubs, patch scripts (COMPAT_OBJECT)
- wine9x-support/wined3d/*.def etc. are READ-ONLY. Do NOT suggest DEF_EXPORT fixes.

exact_change format by change_type:

DOCKERFILE_PATCH — JSON literal string replacement (no sed, no regex):
  {"old": "exact text from Dockerfile", "new": "replacement text"}
  Copy old text EXACTLY from the Dockerfile section provided.

COMPAT_OBJECT — printf to create a new .c file in docker/:
  printf 'void foo(void) {}' > docker/foo_stub.c

MAKEFILE_FLAG — modify the wine9x-support/Makefile that is COPIED into /build inside Docker.
  Use a DOCKERFILE_PATCH instead: add a sed command inside the Dockerfile RUN layer.
  Do NOT use MAKEFILE_FLAG — use DOCKERFILE_PATCH.

BUILD_SCRIPT — manual human action required, describe what to do.

Respond with valid JSON only. No markdown, no prose outside JSON:
{
  "cycle_summary": "2-3 sentence overview",
  "overall_status": "GOOD|NEEDS_WORK|BROKEN",
  "fixes": [
    {
      "priority": 1,
      "severity": "CRITICAL|WARNING|INFO",
      "title": "short title",
      "file": "docker/foo.c or Dockerfile",
      "change_type": "DOCKERFILE_PATCH|COMPAT_OBJECT|BUILD_SCRIPT",
      "description": "explanation",
      "exact_change": "{\"old\": \"...\", \"new\": \"...\"}"
    }
  ],
  "next_action": "REBUILD|INSPECT_ONLY|DONE|MANUAL_REVIEW"
}"""


def save_report(wine_version: str, cycle: int, data: dict, label: str):
    REPORTS_DIR.mkdir(parents=True, exist_ok=True)
    path = REPORTS_DIR / f"{wine_version}_cycle{cycle:02d}_{label}.json"
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
    print(f"[Lead] Report saved: {path}")
    return path


def print_builder_summary(report: dict):
    print(f"\n{'─'*60}")
    print(f"  BUILDER REPORT — Wine {report.get('wine_version')}")
    print(f"{'─'*60}")
    print(f"  Status:   {report.get('status')}")
    print(f"  Attempts: {report.get('attempts', '?')}")
    if report.get("dlls"):
        print("  DLLs built:")
        for dll in report["dlls"]:
            print(f"    ✓ {dll['name']} ({dll['size_kb']} KB)")
    if report.get("escalation_reason"):
        print(f"  ⚠  Escalation: {report['escalation_reason']}")
    for h in report.get("history", []):
        a = h.get("analysis", {})
        print(f"  Attempt {h['attempt']}: rc={h['returncode']} → {a.get('diagnosis', '?')}")


def print_inspector_summary(report: dict):
    print(f"\n{'─'*60}")
    print(f"  INSPECTOR REPORT — Wine {report.get('wine_version')}")
    print(f"{'─'*60}")
    analysis = report.get("analysis", {})
    if "error" in analysis:
        print(f"  ⚠  Analysis error: {analysis['error']}")
        return
    print(f"  Summary: {analysis.get('summary', 'N/A')}")
    print()
    for dll_report in analysis.get("dll_reports", []):
        status_icon = {"MATCH": "✓", "MINOR_DIFF": "~", "MAJOR_DIFF": "✗", "FAIL": "✗✗"}.get(
            dll_report.get("overall_status"), "?"
        )
        print(f"  {status_icon} {dll_report['dll']} — {dll_report.get('overall_status')}")
        if dll_report.get("export_missing"):
            names = ', '.join(dll_report['export_missing'][:5])
            more = '...' if len(dll_report['export_missing']) > 5 else ''
            print(f"      Missing exports ({len(dll_report['export_missing'])}): {names}{more}")
        if dll_report.get("dangerous_imports"):
            print(f"      ⚠  Dangerous imports: {', '.join(dll_report['dangerous_imports'][:3])}")
        for finding in dll_report.get("findings", [])[:3]:
            icon = {"CRITICAL": "🔴", "WARNING": "🟡", "INFO": "🔵"}.get(finding["severity"], "•")
            print(f"      {icon} {finding['description']}")


def print_lead_summary(lead_report: dict):
    print(f"\n{'='*60}")
    print(f"  LEAD ENGINEER SYNTHESIS")
    print(f"{'='*60}")
    print(f"  Overall: {lead_report.get('overall_status')}")
    print(f"  {lead_report.get('cycle_summary')}")
    print(f"\n  Priority Fixes:")
    for fix in lead_report.get("fixes", []):
        sev_icon = {"CRITICAL": "🔴", "WARNING": "🟡", "INFO": "🔵"}.get(fix.get("severity", ""), "•")
        print(f"\n  [{fix.get('priority','?')}] {sev_icon} {fix.get('title','?')}")
        print(f"       File: {fix.get('file','?')}")
        print(f"       Type: {fix.get('change_type','?')}")
        wrapped = textwrap.fill(
            fix.get("description", ""), width=70,
            initial_indent="       ", subsequent_indent="       "
        )
        print(wrapped)
        print(f"       Change:")
        for line in (fix.get("exact_change") or "").split("\n")[:6]:
            print(f"         {line}")
    print(f"\n  Next action: {lead_report.get('next_action')}")


def synthesize_with_claude(builder_report: dict, inspector_report) -> dict:
    client = llm_client.get_client()
    model  = llm_client.get_model()

    payload = {
        "builder_report": {
            "status": builder_report.get("status"),
            "attempts": builder_report.get("attempts"),
            "dlls": builder_report.get("dlls", []),
            "escalation_reason": builder_report.get("escalation_reason"),
            "history": [
                {"attempt": h["attempt"], "returncode": h["returncode"], "analysis": h["analysis"]}
                for h in builder_report.get("history", [])
            ],
        },
        "inspector_report": inspector_report.get("analysis") if inspector_report else None,
    }

    # Include the current Dockerfile link-flags section so the lead engineer
    # can write precise old/new patch text rather than guessing.
    dockerfile_context = dockerfile_patcher.get_section("Link ddraw with nocrt", context_lines=8)

    # Check if exports are already perfect — if so, skip further cycling
    exports_perfect = False
    if inspector_report:
        dll_reports = inspector_report.get("analysis", {}).get("dll_reports", [])
        if dll_reports and all(
            len(r.get("export_missing", [])) == 0 and len(r.get("export_extra", [])) == 0
            for r in dll_reports
        ):
            exports_perfect = True

    user_msg = (
        "Build + inspection cycle complete.\n\n"
        + json.dumps(payload, indent=2)
        + "\n\n=== CURRENT DOCKERFILE LINK FLAGS SECTION ===\n"
        + dockerfile_context
        + "\n=== END ===\n\n"
        + "IMPORTANT CONTEXT for import differences:\n"
        + "- W->A patches are intentional: GetVersionExW->A, GetModuleHandleW->A, CreateDCW->A, EnumDisplay*W->A etc.\n"
        + "- Dynamic binding via GetModuleHandleA+GetProcAddress is intentional for qemu-3dfx passthrough.\n"
        + "- Import table differences vs reference are expected and do NOT indicate build failures.\n"
        + "- Only missing EXPORTS are real problems. Missing imports are usually harmless differences.\n"
        + "- If all exports match: next_action must be DONE regardless of import differences.\n\n"
        + "Synthesize these reports. Return ONLY valid JSON. "
        + "For DOCKERFILE_PATCH fixes, exact_change must be JSON: {\"old\": \"exact text\", \"new\": \"replacement\"}. "
        + "Copy old text EXACTLY from the Dockerfile section above. Start response with { end with }."
    )

    if exports_perfect:
        print("[Lead] All exports match — short-circuiting to DONE")
        return {
            "cycle_summary": "All DLL exports match the reference perfectly. Import differences are expected due to the qemu-3dfx dynamic binding architecture and MinGW vs MSVC CRT linking differences.",
            "overall_status": "GOOD",
            "fixes": [],
            "next_action": "DONE",
        }

    response = client.messages.create(
        model=model, **llm_client.generation_kwargs(4096),
        system=LEAD_ENGINEER_SYSTEM,
        messages=[{"role": "user", "content": user_msg}],
    )

    raw = llm_client.response_text(response).strip()
    raw = re.sub(r"^```[a-z]*\n?", "", raw)
    raw = re.sub(r"\n?```$", "", raw)

    # Try parsing full response, then search for embedded JSON object
    for candidate in [raw, (re.search(r"\{.*\}", raw, re.DOTALL) or type("", (), {"group": lambda *a: ""})()).group(0)]:
        try:
            return json.loads(candidate)
        except (json.JSONDecodeError, AttributeError):
            pass

    na_match = re.search(r'"next_action"\s*:\s*"(\w+)"', raw)
    return {
        "cycle_summary": "Lead engineer response could not be parsed.",
        "overall_status": "NEEDS_WORK",
        "fixes": [],
        "next_action": na_match.group(1) if na_match else "REBUILD",
        "_raw": raw[:2000],
    }


def apply_lead_fixes(lead_report: dict) -> list:
    """
    Execute the lead engineer's recommended fixes.
    DOCKERFILE_PATCH: uses dockerfile_patcher (safe Python string replacement + git commit).
    COMPAT_OBJECT / MAKEFILE_FLAG / DEF_EXPORT: shell commands on the host.
    BUILD_SCRIPT: skipped (manual).

    Protected paths (read-only, never modified by agents):
      - Dockerfile        → only via dockerfile_patcher
      - wine9x-support/   → never modified (read-only build infrastructure)
    """
    PROTECTED = ("wine9x-support", "wine9x", "Dockerfile")
    results = []
    auto_types = {"DOCKERFILE_PATCH", "COMPAT_OBJECT"}

    for fix in lead_report.get("fixes", []):
        change_type = fix.get("change_type", "")
        exact_change = (fix.get("exact_change") or "").strip()
        title = fix.get("title", "?")

        if change_type not in auto_types:
            print(f"[Lead] Skipping '{title}' ({change_type} requires manual action)")
            results.append({"title": title, "skipped": True, "reason": change_type})
            continue

        if not exact_change:
            print(f"[Lead] Skipping '{title}' (empty exact_change)")
            results.append({"title": title, "skipped": True, "reason": "empty"})
            continue

        print(f"\n[Lead] Applying fix [{fix.get('priority','?')}]: {title}")

        # ── DOCKERFILE_PATCH: safe Python patcher ───────────────────────
        if change_type == "DOCKERFILE_PATCH":
            patch_obj = dockerfile_patcher.parse_patch_json(exact_change)
            if patch_obj is None:
                print(f"[Lead] ✗ DOCKERFILE_PATCH requires {{\"old\": ..., \"new\": ...}} JSON")
                print(f"[Lead]   Got: {exact_change[:120]}")
                results.append({"title": title, "applied": False, "stderr": "wrong format"})
                continue
            old_text = patch_obj["old"]
            new_text = patch_obj["new"]
            print(f"[Lead] Patching Dockerfile: {old_text[:60]!r} → {new_text[:60]!r}")
            result = dockerfile_patcher.patch(old_text, new_text, title)
            if result["ok"]:
                print(f"[Lead] ✓ Applied and committed")
                results.append({"title": title, "applied": True})
            else:
                print(f"[Lead] ✗ Failed: {result['reason']}")
                results.append({"title": title, "applied": False, "stderr": result["reason"]})
            continue

        # ── Other types: shell command on host ────────────────────────
        has_command_keyword = any(
            kw in exact_change
            for kw in ("sed ", "echo ", "cat ", "printf ", "perl ", ">>", "&&")
        )
        if not has_command_keyword or exact_change.count("\n") > 10:
            print(f"[Lead] Skipping '{title}' (exact_change is prose, not a command)")
            results.append({"title": title, "skipped": True, "reason": "prose"})
            continue

        cmd = re.sub(r"(?m)^RUN\s+", "", exact_change).strip()
        cmd = agent_builder.enforce_bsd_sed(cmd)

        # Block writes to protected paths (check both raw exact_change and resolved cmd)
        if any(p in exact_change or p in cmd for p in PROTECTED):
            print(f"[Lead] Skipping '{title}' (targets protected path — wine9x-support and Dockerfile are read-only)")
            results.append({"title": title, "skipped": True, "reason": "protected path"})
            continue

        print(f"[Lead] $ {cmd[:160]}{'...' if len(cmd) > 160 else ''}")
        result = subprocess.run(
            cmd, shell=True, cwd=str(PROJECT_DIR),
            capture_output=True, text=True
        )
        if result.returncode == 0:
            print(f"[Lead] ✓ Applied")
            results.append({"title": title, "applied": True})
        else:
            err = result.stderr.strip()[:300]
            print(f"[Lead] ✗ Failed (rc={result.returncode}): {err}")
            results.append({"title": title, "applied": False, "stderr": err})

    return results


def interactive_fix_loop(lead_report: dict) -> bool:
    """Ask the user whether to apply fixes and rebuild. Returns True to continue."""
    next_action = lead_report.get("next_action", "MANUAL_REVIEW")

    if next_action == "DONE":
        print("\n[Lead] ✓ All checks passed. No further action needed.")
        return False
    if next_action == "MANUAL_REVIEW":
        print("\n[Lead] Manual review required — see report for details.")
        return False

    print("\n" + "="*60)
    print("  LEAD ENGINEER — RECOMMENDED NEXT STEPS")
    print("="*60)
    print(f"  Recommended action: {next_action}")
    fixes = lead_report.get("fixes", [])
    if fixes:
        print("\n  Changes to apply:")
        for fix in fixes[:5]:
            print(f"  [{fix.get('priority','?')}] {fix.get('title','?')} ({fix.get('change_type','?')})")
    print()
    response = input("  Apply fixes and rebuild? [y/N/q(quit)]: ").strip().lower()
    if response == "q":
        return False
    if response == "y":
        apply_lead_fixes(lead_report)
        return next_action in ("REBUILD", "INSPECT_ONLY")
    return False


def main():
    parser = argparse.ArgumentParser(description="wined3d-windows multi-agent build orchestrator")
    parser.add_argument("wine_version", help="Wine version (e.g. 8.0.2)")
    parser.add_argument("--inspect-only", action="store_true", help="Skip build, inspect existing output")
    parser.add_argument("--build-only", action="store_true", help="Skip inspection after build")
    parser.add_argument("--max-attempts", type=int, default=3, help="Max build retry attempts per cycle")
    parser.add_argument("--max-cycles", type=int, default=5, help="Max full build+inspect cycles")
    parser.add_argument("--auto", action="store_true",
                        help="Non-interactive: auto-apply lead fixes and keep cycling until DONE or max-cycles")
    args = parser.parse_args()

    wine_version = args.wine_version
    cycle = 1

    print(f"\n{'#'*60}")
    print(f"  wined3d-windows Multi-Agent Orchestrator")
    print(f"  Wine version: {wine_version}")
    print(f"{'#'*60}")

    while cycle <= args.max_cycles:
        print(f"\n>>> CYCLE {cycle}/{args.max_cycles}")

        # ── Agent 1: Builder ──────────────────────────────────────
        if not args.inspect_only:
            builder_report = agent_builder.run(wine_version, max_attempts=args.max_attempts)
            save_report(wine_version, cycle, builder_report, "builder")
            print_builder_summary(builder_report)
            if builder_report["status"] not in ("SUCCESS",):
                print(f"\n[Lead] Build status: {builder_report['status']}")
        else:
            built_dir = PROJECT_DIR / "output" / wine_version
            if not (built_dir / "wined3d.dll").exists():
                print(f"[Lead] No built DLLs at {built_dir}. Run a build first.")
                sys.exit(1)
            builder_report = {
                "agent": "builder", "wine_version": wine_version, "status": "SUCCESS",
                "attempts": 0, "dlls": [], "output_dir": str(built_dir), "history": [],
            }

        # ── Agent 2: Inspector ────────────────────────────────────
        inspector_report = None
        if not args.build_only:
            built_dir = Path(builder_report.get("output_dir", ""))
            if built_dir.exists() and any(built_dir.glob("*.dll")):
                inspector_report = agent_inspector.run(wine_version, built_dir)
                save_report(wine_version, cycle, inspector_report, "inspector")
                print_inspector_summary(inspector_report)
            else:
                print("[Lead] No DLLs to inspect — skipping Inspector")

        # ── Lead Engineer Synthesis ───────────────────────────────
        lead_report = synthesize_with_claude(builder_report, inspector_report)
        save_report(wine_version, cycle, lead_report, "lead")
        print_lead_summary(lead_report)

        # ── Decision: apply fixes and continue? ───────────────────
        next_action = lead_report.get("next_action", "MANUAL_REVIEW")

        if next_action == "DONE":
            print("\n[Lead] ✓ All checks passed. Done.")
            break

        if args.auto:
            if next_action == "MANUAL_REVIEW":
                built_dir = Path(builder_report.get("output_dir", ""))
                has_dlls = built_dir.exists() and any(built_dir.glob("*.dll"))
                if not has_dlls:
                    print("\n[Lead] --auto: MANUAL_REVIEW with no DLLs — stopping.")
                    break
                print("\n[Lead] --auto: MANUAL_REVIEW but DLLs exist — applying fixes and continuing")

            if next_action in ("REBUILD", "INSPECT_ONLY", "MANUAL_REVIEW"):
                # Apply lead engineer fixes before next cycle
                fix_results = apply_lead_fixes(lead_report)
                applied = sum(1 for r in fix_results if r.get("applied"))
                skipped = sum(1 for r in fix_results if r.get("skipped"))
                print(f"\n[Lead] Fix results: {applied} applied, {skipped} skipped, "
                      f"{len(fix_results) - applied - skipped} failed")
                print(f"[Lead] --auto: starting cycle {cycle + 1}")
            else:
                print(f"\n[Lead] --auto: unknown next_action '{next_action}' — stopping.")
                break

        elif sys.stdin.isatty():
            should_rebuild = interactive_fix_loop(lead_report)
            if not should_rebuild:
                break
        else:
            break  # Non-interactive, no --auto: single cycle

        cycle += 1
        args.inspect_only = False

    print(f"\n[Orchestrator] Done after {cycle} cycle(s). Reports in: {REPORTS_DIR}")


if __name__ == "__main__":
    main()
