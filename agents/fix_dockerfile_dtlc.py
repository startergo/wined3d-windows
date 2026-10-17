#!/usr/bin/env python3
"""Fix the DisableThreadLibraryCalls injection in the Dockerfile.
Uses perl -0777 to slurp the whole file, immune to line endings.
Also adds a verification grep so the build fails loudly if injection missed."""
import os
from pathlib import Path

# Repository root: the parent of agents/, or WINED3D_PROJECT_DIR if set.
PROJECT_DIR = Path(os.environ.get("WINED3D_PROJECT_DIR") or Path(__file__).resolve().parent.parent)
path = PROJECT_DIR / 'Dockerfile'
with open(path, 'r') as f:
    src = f.read()

old = "    perl -0777 -pi -e 's/DisableThreadLibraryCalls\\(inst\\);/DisableThreadLibraryCalls(inst);\\n        qemu3dfx_ddraw_passthrough_init();/' ddraw/main.c && \\"

# Already updated? Check for old sed version too
old_sed = "    perl -pi -e 's/DisableThreadLibraryCalls\\(inst\\);/DisableThreadLibraryCalls(inst);\\n        qemu3dfx_ddraw_passthrough_init();/' ddraw/main.c && \\"

new = (
    "    perl -0777 -pi -e "
    "'s/DisableThreadLibraryCalls\\(inst\\);/"
    "DisableThreadLibraryCalls(inst);\\n        qemu3dfx_ddraw_passthrough_init();/' "
    "ddraw/main.c && \\\n"
    "    grep -q 'qemu3dfx_ddraw_passthrough_init' ddraw/main.c || "
    "{ echo 'ERROR: passthrough_init injection failed'; exit 1; } && \\"
)

target = old if old in src else (old_sed if old_sed in src else None)

if target:
    new_src = src.replace(target, new, 1)
    with open(path, 'w') as f:
        f.write(new_src)
    print("Fixed. New injection:")
    print(new)
else:
    print("ERROR: target line not found. Searching...")
    for i, line in enumerate(src.split('\n')):
        if 'DisableThreadLibraryCalls' in line and ('perl' in line or 'sed' in line):
            print(f"  Line {i+1}: {line!r}")
