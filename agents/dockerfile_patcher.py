"""
dockerfile_patcher.py — Safe, verified Dockerfile editing for the agent system.

Instead of generating sed/perl commands that break on macOS BSD sed,
agents provide (old_text, new_text) and this module:
  1. Reads the current Dockerfile
  2. Verifies old_text exists exactly once
  3. Replaces it with new_text
  4. Verifies the replacement took effect
  5. Optionally git-commits the change for rollback

Used by orchestrator.apply_lead_fixes() when change_type == DOCKERFILE_PATCH
and exact_change contains the JSON format:
  {"old": "...", "new": "..."}
"""

import json
import re
import subprocess
from pathlib import Path
import os

# Repository root: the parent of agents/, or WINED3D_PROJECT_DIR if set.
PROJECT_DIR = Path(os.environ.get("WINED3D_PROJECT_DIR") or Path(__file__).resolve().parent.parent)
DOCKERFILE   = PROJECT_DIR / "Dockerfile"


def read_file(path: Path) -> str:
    """Read any project file for agent context (read-only)."""
    full_path = PROJECT_DIR / path if not Path(path).is_absolute() else Path(path)
    if not full_path.exists():
        return f"(file not found: {full_path})"
    return full_path.read_text(encoding="utf-8", errors="replace")


def read() -> str:
    return DOCKERFILE.read_text(encoding="utf-8")


def patch(old: str, new: str, description: str = "") -> dict:
    """
    Replace old with new in the Dockerfile exactly once.
    Returns {"ok": True} or {"ok": False, "reason": "..."}.
    """
    content = read()

    count = content.count(old)
    if count == 0:
        return {"ok": False, "reason": f"old_text not found in Dockerfile: {old[:80]!r}"}
    if count > 1:
        return {"ok": False, "reason": f"old_text matched {count} times (ambiguous): {old[:80]!r}"}

    new_content = content.replace(old, new, 1)

    # Verify the replacement actually changed something
    if new_content == content:
        return {"ok": False, "reason": "replacement produced no change"}

    # Write back
    DOCKERFILE.write_text(new_content, encoding="utf-8")

    # Verify new text is now present
    if new not in DOCKERFILE.read_text():
        return {"ok": False, "reason": "write succeeded but new_text not found after write"}

    # Git commit for rollback
    _git_commit(description or f"agent patch: {old[:40]!r} → {new[:40]!r}")

    return {"ok": True}


def restore_from_git() -> dict:
    """Restore Dockerfile to last git commit."""
    result = subprocess.run(
        ["git", "checkout", "Dockerfile"],
        cwd=str(PROJECT_DIR), capture_output=True, text=True
    )
    if result.returncode == 0:
        return {"ok": True}
    return {"ok": False, "reason": result.stderr.strip()}


def get_section(marker: str, context_lines: int = 5) -> str:
    """
    Return lines around a marker string for the agent to see
    before proposing a patch. Helps agents write correct old_text.
    """
    lines = read().splitlines()
    result = []
    for i, line in enumerate(lines):
        if marker in line:
            start = max(0, i - context_lines)
            end   = min(len(lines), i + context_lines + 1)
            result.append(f"[lines {start+1}-{end}]")
            result.extend(lines[start:end])
            result.append("")
    return "\n".join(result) if result else f"(marker not found: {marker!r})"


def _git_commit(message: str):
    subprocess.run(
        ["git", "add", "Dockerfile"],
        cwd=str(PROJECT_DIR), capture_output=True
    )
    subprocess.run(
        ["git", "commit", "-m", f"[agent] {message[:120]}"],
        cwd=str(PROJECT_DIR), capture_output=True
    )


# ── Agent-facing patch format ────────────────────────────────────────────────
# When the lead engineer produces a DOCKERFILE_PATCH fix, exact_change should be:
#
#   {"old": "exact text to replace", "new": "replacement text"}
#
# The orchestrator detects this JSON format and calls patch() instead of
# running the string as a shell command.

def parse_patch_json(exact_change: str) -> dict | None:
    """
    If exact_change is a JSON object with "old" and "new" keys, return it.
    Otherwise return None (caller falls back to shell execution).
    """
    s = exact_change.strip()
    if not s.startswith("{"):
        return None
    try:
        obj = json.loads(s)
        if "old" in obj and "new" in obj:
            return obj
    except json.JSONDecodeError:
        pass
    return None
