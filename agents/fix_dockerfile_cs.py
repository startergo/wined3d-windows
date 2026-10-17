#!/usr/bin/env python3
"""Fix the CS init patch in the Dockerfile to use patch_cs_win98.py instead of fragile perl."""
import re
import os
from pathlib import Path

# Repository root: the parent of agents/, or WINED3D_PROJECT_DIR if set.
PROJECT_DIR = Path(os.environ.get("WINED3D_PROJECT_DIR") or Path(__file__).resolve().parent.parent)
path = PROJECT_DIR / 'Dockerfile'
with open(path, 'r') as f:
    src = f.read()

# Replace the three-line perl CS patch with a single python3 call
old_pattern = re.compile(
    r'true "=== Win9x: runtime critical section init ===?" && \\\n'
    r'    perl -pi -e \'s\^static CRITICAL_SECTION wined3d_cs.*\n'
    r'.*wined3d_wndproc_cs.*\n'
    r'.*DisableThreadLibraryCalls.*\n',
    re.DOTALL
)

# More robust: find the block by key anchor strings
old_block = None
start_marker = 'true "=== Win9x: runtime critical section init'
end_marker = 'true "=== Win9x: disable MT command stream'

start_idx = src.find(start_marker)
end_idx = src.find(end_marker)

if start_idx == -1 or end_idx == -1:
    print(f"ERROR: Could not find markers. start={start_idx}, end={end_idx}")
    # Print context around search
    for marker in [start_marker, end_marker]:
        idx = src.find(marker[:30])
        print(f"  Searching for {marker[:30]!r}: found at {idx}")
    exit(1)

old_block = src[start_idx:end_idx]
new_block = (
    'true "=== Win9x: runtime critical section init (all CS + debug structs) ===" && \\\n'
    '    python3 /docker/patch_cs_win98.py /build/wined3d/wined3d_main.c && \\\n'
    '    \\\n'
)

new_src = src[:start_idx] + new_block + src[end_idx:]

with open(path, 'w') as f:
    f.write(new_src)

print(f"Replaced CS init block ({len(old_block)} chars) with python3 call")
print(f"Old block was:\n{old_block}")
