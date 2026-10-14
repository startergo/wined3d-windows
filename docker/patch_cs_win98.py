#!/usr/bin/env python3
"""
patch_cs_win98.py — Replace NT-only static CRITICAL_SECTION initializers
with runtime InitializeCriticalSection() calls for Win98 compatibility.

Wine 6.0+ uses NT-specific CRITICAL_SECTION_DEBUG structs in static initializers.
Win98's kernel32 does not support this — only InitializeCriticalSection() works.

Usage: python3 patch_cs_win98.py /build/wined3d/wined3d_main.c
"""

import re
import sys

path = sys.argv[1]
with open(path, 'r', encoding='utf-8', errors='replace') as f:
    src = f.read()

original = src

# 1. Remove all CRITICAL_SECTION_DEBUG struct definitions (multi-line)
#    Pattern: static CRITICAL_SECTION_DEBUG foo_debug = { ... };
src = re.sub(
    r'(?:static\s+)?CRITICAL_SECTION_DEBUG\s+\w+\s*=\s*\{[^}]*\}\s*;\s*\n',
    '',
    src,
    flags=re.DOTALL
)

# 2. Replace static CRITICAL_SECTION initializers with bare declarations
#    Handles both 'static' and non-static (e.g. wined3d_command_cs)
src = re.sub(
    r'^((?:static\s+)?CRITICAL_SECTION\s+(\w+))\s*=\s*\{[^}]*\}\s*;',
    r'\1;  /* Win9x: runtime initialized */',
    src,
    flags=re.MULTILINE
)

# 3. Collect all CS names that need runtime init
cs_names = re.findall(
    r'(?:static\s+)?CRITICAL_SECTION\s+(\w+)\s*;',
    src
)

# 4. Inject InitializeCriticalSection() calls after DisableThreadLibraryCalls
init_calls = ''.join(
    f'    InitializeCriticalSection(&{name});\n'
    for name in cs_names
)

if init_calls:
    src = re.sub(
        r'(DisableThreadLibraryCalls\([^)]*\);)',
        r'\1\n' + init_calls.rstrip('\n'),
        src,
        count=1
    )

# 5. Remove DeleteCriticalSection calls in wined3d_dll_destroy to match
#    (Win98 kernel32 has DeleteCriticalSection but it's a no-op, so it's fine to keep)

if src != original:
    with open(path, 'w', encoding='utf-8') as f:
        f.write(src)
    cs_list = ', '.join(cs_names) if cs_names else 'none'
    print(f'  Patched CS init in {path}: [{cs_list}]')
else:
    print(f'  No CS init changes needed in {path}')
