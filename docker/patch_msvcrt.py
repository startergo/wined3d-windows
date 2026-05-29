#!/usr/bin/env python3
"""Post-build patch for msvcrt.dll: remove __wine_dbg_* imports, fix ImageBase.

Replaces unwanted __wine_dbg_* import names with __wine_dbg_strdup (a safe
nulldll export present in the reference) so the PE loader resolves them to
a harmless function.  The real fix is at compile time; this is a fallback.
"""
import sys, struct

path = sys.argv[1]
data = bytearray(open(path, 'rb').read())
changed = False

# Replace unwanted debug imports with safe alternatives (same byte length)
# __wine_dbg_strdup is already imported and harmless
replacements = {
    b'__wine_dbg_output\x00':           b'__wine_dbg_strdup\x00',
    b'__wine_dbg_header\x00':            b'__wine_dbg_strdup\x00',
    b'__wine_dbg_get_channel_flags\x00': b'__wine_dbg_strdup\x00\x00\x00\x00\x00',
}

for bad, good in replacements.items():
    if bad in data:
        # Must be same length or shorter (pad shorter with nulls)
        idx = data.index(bad)
        if len(good) <= len(bad):
            data[idx:idx + len(good)] = good
            # zero-fill remainder
            for i in range(idx + len(good), idx + len(bad)):
                data[i] = 0
            print(f'  patched import: {bad.decode().strip(chr(0))} -> {good.rstrip(b"\\x00").decode()}')
            changed = True
        else:
            print(f'  WARNING: replacement longer than original for {bad}')

# Fix ImageBase
pe_off = struct.unpack_from('<I', data, 0x3C)[0]
opt_off = pe_off + 24
cur_base = struct.unpack_from('<I', data, opt_off + 28)[0]
if cur_base != 0x10000000:
    struct.pack_into('<I', data, opt_off + 28, 0x10000000)
    print(f'  patched ImageBase: 0x{cur_base:08x} -> 0x10000000')
    changed = True

if changed:
    open(path, 'wb').write(bytes(data))
    print(f'  saved {path}')
else:
    print('  no patches needed')
