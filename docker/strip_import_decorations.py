#!/usr/bin/env python3
"""Strip @N stdcall decorations from PE import name strings.
   Modifies the hint/name table entries in-place so the PE loader
   looks up undecorated names (e.g. 'RegCloseKey' not 'RegCloseKey@4')."""
import sys, struct, os

def strip_import_decorations(filepath):
    with open(filepath, 'rb') as f:
        data = bytearray(f.read())
    if data[:2] != b'MZ':
        return
    pe_off = struct.unpack_from('<I', data, 0x3C)[0]
    if data[pe_off:pe_off+4] != b'PE\x00\x00':
        return
    coff = pe_off + 4
    nsec = struct.unpack_from('<H', data, coff + 2)[0]
    opt_sz = struct.unpack_from('<H', data, coff + 16)[0]
    opt = coff + 20
    if struct.unpack_from('<H', data, opt)[0] != 0x10B:
        return
    imp_rva = struct.unpack_from('<I', data, opt + 104)[0]
    if imp_rva == 0:
        return
    secs = []
    for i in range(nsec):
        s = opt + opt_sz + i * 40
        va = struct.unpack_from('<I', data, s + 12)[0]
        vs = struct.unpack_from('<I', data, s + 8)[0]
        rp = struct.unpack_from('<I', data, s + 20)[0]
        rs = struct.unpack_from('<I', data, s + 16)[0]
        secs.append((va, vs, rp, rs))
    def r2o(rva):
        for va, vs, rp, rs in secs:
            if va <= rva < va + max(vs, rs):
                return rp + (rva - va)
        return None
    do = r2o(imp_rva)
    if do is None:
        return
    stripped = 0
    dll_lowered = 0
    while True:
        ilt_rva = struct.unpack_from('<I', data, do)[0]
        name_rva = struct.unpack_from('<I', data, do + 12)[0]
        if ilt_rva == 0 and name_rva == 0:
            break
        # Lowercase the import DLL name
        if name_rva != 0:
            dn_off = r2o(name_rva)
            if dn_off is not None:
                end = dn_off
                while end < len(data) and data[end] != 0:
                    end += 1
                orig = data[dn_off:end]
                lowered = orig.lower()
                if orig != lowered:
                    data[dn_off:end] = lowered
                    dll_lowered += 1
        ilt_off = r2o(ilt_rva)
        if ilt_off is not None:
            idx = 0
            while True:
                entry = struct.unpack_from('<I', data, ilt_off + idx * 4)[0]
                if entry == 0:
                    break
                if not (entry & 0x80000000):
                    hn_off = r2o(entry & 0x7FFFFFFF)
                    if hn_off is not None:
                        noff = hn_off + 2
                        end = noff
                        while end < len(data) and data[end] != 0:
                            end += 1
                        nm = data[noff:end]
                        at = nm.rfind(b'@')
                        if at > 0 and nm[at+1:].isdigit():
                            data[noff + at] = 0
                            stripped += 1
                idx += 1
        do += 20
    if stripped > 0 or dll_lowered > 0:
        with open(filepath, 'wb') as f:
            f.write(data)
        print(f"  Stripped {stripped} @N, lowercased {dll_lowered} DLL names: {os.path.basename(filepath)}")

if __name__ == '__main__':
    path = sys.argv[1]
    if os.path.isdir(path):
        for f in sorted(os.listdir(path)):
            if f.lower().endswith('.dll'):
                strip_import_decorations(os.path.join(path, f))
    else:
        strip_import_decorations(path)
