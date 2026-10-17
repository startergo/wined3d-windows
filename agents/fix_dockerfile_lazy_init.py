#!/usr/bin/env python3
"""
Fix ddraw passthrough injection points in the Dockerfile:
1. Remove qemu3dfx_ddraw_passthrough_init() from DllMain (too early for EnumDisplayDevicesA)
2. Add it as a lazy init inside DDRAW_Create instead (called on first DirectDrawCreate)
"""
import os
from pathlib import Path

# Repository root: the parent of agents/, or WINED3D_PROJECT_DIR if set.
PROJECT_DIR = Path(os.environ.get("WINED3D_PROJECT_DIR") or Path(__file__).resolve().parent.parent)
path = PROJECT_DIR / 'Dockerfile'
with open(path, 'r') as f:
    src = f.read()

# Fix 1: Remove the DllMain injection (DisableThreadLibraryCalls anchor)
# Replace the passthrough_init call there with nothing
old_dllinit = (
    "    perl -0777 -pi -e "
    "'s/DisableThreadLibraryCalls\\(inst\\);/"
    "DisableThreadLibraryCalls(inst);\\n        qemu3dfx_ddraw_passthrough_init();/' "
    "ddraw/main.c && \\\n"
    "    grep -q 'qemu3dfx_ddraw_passthrough_init' ddraw/main.c || "
    "{ echo 'ERROR: passthrough_init injection failed'; exit 1; } && \\"
)

# Fix 2: Instead inject into DDRAW_Create, before the wined3d_mutex_lock
# The perl patch for DirectDrawCreate already adds the passthru check before wined3d_mutex_lock
# We need passthrough_init to be called once before qemu3dfx_ddraw_is_passthru() is checked
# Best place: at the top of DDRAW_Create as a one-time lazy init

new_dllinit = (
    "    perl -0777 -pi -e "
    "'s/static HRESULT DDRAW_Create\\(/static HRESULT DDRAW_Create(/"
    "' ddraw/main.c && \\"  # no-op placeholder, we inject differently below
)

# Actually simplest fix: inject into DirectDrawCreate and DirectDrawCreateEx
# BEFORE the qemu3dfx_ddraw_is_passthru() check that's already there
# The existing perl patches add:
#   if (qemu3dfx_ddraw_is_passthru())
#       return qemu3dfx_ddraw_create(...)
#   wined3d_mutex_lock();
#
# We want to add passthrough_init() before the is_passthru check.
# Change the DirectDrawCreate perl to inject init+check:

old_ddc_perl = (
    '    perl -pi -e \'if (/^HRESULT WINAPI.*DirectDrawCreate\\(GUID \\*driver_guid, IDirectDraw/) '
    '{ $in_ddc = 1; } if ($in_ddc && /^    wined3d_mutex_lock/) '
    '{ $_ = "    if (qemu3dfx_ddraw_is_passthru())\\n'
    '        return qemu3dfx_ddraw_create(driver_guid, (void **)ddraw, outer);\\n\\n" . $_; '
    '$in_ddc = 0; }\' ddraw/main.c && \\'
)

new_ddc_perl = (
    '    perl -pi -e \'if (/^HRESULT WINAPI.*DirectDrawCreate\\(GUID \\*driver_guid, IDirectDraw/) '
    '{ $in_ddc = 1; } if ($in_ddc && /^    wined3d_mutex_lock/) '
    '{ $_ = "    qemu3dfx_ddraw_passthrough_init();\\n'
    '    if (qemu3dfx_ddraw_is_passthru())\\n'
    '        return qemu3dfx_ddraw_create(driver_guid, (void **)ddraw, outer);\\n\\n" . $_; '
    '$in_ddc = 0; }\' ddraw/main.c && \\'
)

changes = 0

if old_dllinit in src:
    src = src.replace(old_dllinit, '', 1)
    print("Removed DllMain passthrough_init injection")
    changes += 1
else:
    print("WARNING: DllMain injection not found (may already be removed)")
    # Search for it
    for i, line in enumerate(src.split('\n')):
        if 'passthrough_init' in line and 'perl' in line:
            print(f"  Found at line {i+1}: {line[:80]!r}")

if old_ddc_perl in src:
    src = src.replace(old_ddc_perl, new_ddc_perl, 1)
    print("Updated DirectDrawCreate to call passthrough_init lazily")
    changes += 1
else:
    print("WARNING: DirectDrawCreate perl not found")
    for i, line in enumerate(src.split('\n')):
        if 'DirectDrawCreate' in line and 'perl' in line and 'in_ddc' in line:
            print(f"  Found at line {i+1}: {line[:80]!r}")

if changes > 0:
    with open(path, 'w') as f:
        f.write(src)
    print(f"\nApplied {changes} change(s) to Dockerfile")
else:
    print("\nNo changes applied - check the search strings above")
