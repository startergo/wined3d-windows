"""Pure Python PE import checker — no external dependencies."""
import struct, sys, glob, os

def rva_to_offset(sections, rva):
    for va, raw, raw_size in sections:
        if va <= rva < va + raw_size:
            return raw + (rva - va)
    return None

def get_imports(path):
    with open(path, 'rb') as f:
        data = f.read()
    if data[:2] != b'MZ':
        raise ValueError("Not a PE file")
    e_lfanew = struct.unpack_from('<I', data, 0x3C)[0]
    if data[e_lfanew:e_lfanew+4] != b'PE\0\0':
        raise ValueError("Invalid PE signature")
    coff = e_lfanew + 4
    num_sec = struct.unpack_from('<H', data, coff + 2)[0]
    opt_size = struct.unpack_from('<H', data, coff + 16)[0]
    opt = coff + 20
    magic = struct.unpack_from('<H', data, opt)[0]
    if magic != 0x10B:
        raise ValueError(f"Not PE32 (magic={hex(magic)})")
    dd = opt + 96  # data directories start
    imp_rva = struct.unpack_from('<I', data, dd + 8)[0]
    imp_size = struct.unpack_from('<I', data, dd + 12)[0]
    if imp_rva == 0:
        return []
    # Parse sections for RVA mapping
    sec_off = opt + opt_size
    sections = []
    for i in range(num_sec):
        s = sec_off + i * 40
        sections.append((
            struct.unpack_from('<I', data, s + 12)[0],  # VirtualAddress
            struct.unpack_from('<I', data, s + 20)[0],  # PointerToRawData
            struct.unpack_from('<I', data, s + 16)[0],  # SizeOfRawData
        ))
    off = rva_to_offset(sections, imp_rva)
    if off is None:
        return []
    imports = []
    while True:
        name_rva = struct.unpack_from('<I', data, off + 12)[0]
        if name_rva == 0:
            break
        name_off = rva_to_offset(sections, name_rva)
        if name_off is not None:
            end = data.index(b'\0', name_off)
            imports.append(data[name_off:end].decode('ascii', errors='replace').lower())
        off += 20
    return imports

if __name__ == '__main__':
    version = sys.argv[1] if len(sys.argv) > 1 else '*'
    pattern = f'output/{version}/*.dll'
    fail = False
    for path in sorted(glob.glob(pattern)):
        name = os.path.basename(path)
        try:
            imports = get_imports(path)
        except Exception as e:
            print(f'ERROR: {name}: {e}')
            fail = True
            continue
        for dll in imports:
            if dll == 'ucrtbase.dll':
                print(f'ERROR: {name} links ucrtbase.dll')
                fail = True
            if dll == 'libwine.dll':
                print(f'ERROR: {name} links libwine.dll')
                fail = True
        print(f'  {name}: {" ".join(imports)}')
    sys.exit(1 if fail else 0)
