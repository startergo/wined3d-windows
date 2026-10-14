#!/usr/bin/env python3
"""Patch PE DLLs for Win98 compatibility: set NO_SEH flag, strip COFF debug sections."""
import struct, glob, os, sys

# FILE_HEADER Characteristics flags
RELOCS_STRIPPED = 0x0001  # must be CLEAR for relocatable DLLs

# DllCharacteristics flags
NO_SEH = 0x0400

def fix_symbol_table(dll):
    with open(dll, 'r+b') as f:
        data = f.read()
        pe_off = struct.unpack_from('<I', data, 0x3C)[0]
        coff = pe_off + 4
        nsec = struct.unpack_from('<H', data, coff + 2)[0]
        opt_size = struct.unpack_from('<H', data, coff + 16)[0]
        sym_ptr, sym_count = struct.unpack_from('<II', data, coff + 8)
        if not sym_ptr or sym_ptr + sym_count * 18 + 4 <= len(data):
            return                                   # absent or intact
        sec_off = pe_off + 24 + opt_size
        names = {b'/4': b'.eh_fram'}
        renamed = []
        for i in range(nsec):
            s = sec_off + i * 40
            raw = data[s:s + 8].split(b'\x00')[0]
            if raw.startswith(b'/'):
                new = names.get(raw, (b'.s' + raw[1:]).ljust(8, b'\x00')[:8])
                f.seek(s); f.write(new.ljust(8, b'\x00'))
                renamed.append(f'{raw.decode()}->{new.rstrip(bytes(1)).decode()}')
        f.seek(coff + 8)
        f.write(struct.pack('<II', 0, 0))
        print(f'  Cleared dangling COFF symbol table ({sym_count} syms past EOF)'
              f'{", renamed " + " ".join(renamed) if renamed else ""} ({os.path.basename(dll)})')


outdir = sys.argv[1] if len(sys.argv) > 1 else '/output'
for dll in glob.glob(os.path.join(outdir, '*.dll')):
    with open(dll, 'r+b') as f:
        data = f.read()
        pe_off = struct.unpack_from('<I', data, 0x3C)[0]
        coff = pe_off + 4
        opt = pe_off + 24
        opt_size = struct.unpack_from('<H', data, coff + 16)[0]
        nsec = struct.unpack_from('<H', data, coff + 2)[0]

        # Clear RELOCS_STRIPPED so Win98 loader can relocate if ImageBase is taken
        # (reference DLLs have 0x2306 not 0x2106 — bit 0x0001 must be clear)
        file_chars = struct.unpack_from('<H', data, coff + 18)[0]
        if file_chars & RELOCS_STRIPPED:
            file_chars &= ~RELOCS_STRIPPED
            f.seek(coff + 18)
            f.write(struct.pack('<H', file_chars))
            print(f'  Cleared RELOCS_STRIPPED: FileChars={hex(file_chars)} ({os.path.basename(dll)})')

        # Set NO_SEH flag in DllCharacteristics (match reference DLLs: 0x0540)
        dll_chars = struct.unpack_from('<H', data, opt + 70)[0]
        if not (dll_chars & NO_SEH):
            dll_chars |= NO_SEH
            f.seek(opt + 70)
            f.write(struct.pack('<H', dll_chars))
            print(f'  Set NO_SEH flag: DllChars={hex(dll_chars)} ({os.path.basename(dll)})')

        sec_off = opt + opt_size

        # Resolve COFF string table for long section names stored as /N
        sym_ptr = struct.unpack_from('<I', data, coff + 8)[0]
        sym_count = struct.unpack_from('<I', data, coff + 12)[0]
        strtab = b''
        if sym_ptr > 0 and sym_count > 0:
            strtab_off = sym_ptr + sym_count * 18
            if strtab_off + 4 <= len(data):
                strtab_sz = struct.unpack_from('<I', data, strtab_off)[0]
                strtab = data[strtab_off:strtab_off + strtab_sz]

        def resolve_sec_name(idx):
            raw = data[sec_off + idx * 40:sec_off + idx * 40 + 8]
            name = raw.split(b'\x00')[0]
            if name.startswith(b'/') and len(strtab) > 4:
                offset = int(name[1:])
                if 0 < offset < len(strtab):
                    end = strtab.index(b'\x00', offset) if b'\x00' in strtab[offset:] else len(strtab)
                    return strtab[offset:end]
            return name

        # Only strip .debug_* sections, NOT .eh_frame (needed for exception handling)
        strip = [i for i in range(nsec)
                 if resolve_sec_name(i).startswith(b'.debug')]

        if strip:
            sa = struct.unpack_from('<I', data, opt + 32)[0]
            fa = struct.unpack_from('<I', data, opt + 36)[0]
            kept, kept_data = [], []
            for i in range(nsec):
                if i in strip:
                    continue
                s = sec_off + i * 40
                nb = data[s:s+8]
                vs = struct.unpack_from('<I', data, s+8)[0]
                va = struct.unpack_from('<I', data, s+12)[0]
                rs = struct.unpack_from('<I', data, s+16)[0]
                ra = struct.unpack_from('<I', data, s+20)[0]
                ch = struct.unpack_from('<I', data, s+36)[0]
                sd = data[ra:ra+rs] if rs > 0 and ra > 0 else b''
                kept.append([nb, vs, va, rs, ra, ch])
                kept_data.append(sd)

            f.seek(coff+2); f.write(struct.pack('<H', len(kept)))
            he = ((sec_off + len(kept)*40 + fa - 1) // fa) * fa
            rp = he; ni = 0
            for idx in range(len(kept)):
                sd = kept_data[idx]
                nrs = ((len(sd)+fa-1)//fa)*fa if sd else 0
                nra = rp if nrs > 0 else 0
                kept[idx][3:5] = [nrs, nra]
                if nrs:
                    rp = nra + nrs
                end = ((kept[idx][2]+max(kept[idx][1],nrs)+sa-1)//sa)*sa
                if end > ni:
                    ni = end
            f.seek(opt+56); f.write(struct.pack('<I', ni))
            for i, (nb, vs, va, rs, ra, ch) in enumerate(kept):
                f.seek(sec_off+i*40)
                f.write(nb)
                f.write(struct.pack('<IIIIIIHHI', vs, va, rs, ra, 0, 0, 0, 0, ch))
            ne = sec_off + len(kept)*40
            oe = sec_off + nsec*40
            if ne < oe:
                f.seek(ne)
                f.write(b'\x00'*(oe-ne))
            for idx, (nb, vs, va, rs, ra, ch) in enumerate(kept):
                sd = kept_data[idx]
                if sd and rs > 0:
                    f.seek(ra)
                    f.write(sd + b'\x00'*(rs-len(sd)) if len(sd) < rs else sd)
            f.truncate(rp)
            print(f'  Stripped {len(strip)} debug section(s) ({os.path.basename(dll)})')
        else:
            print(f'  No debug sections ({os.path.basename(dll)})')

    # The COFF symbol table and its string table lived past the last section
    # and were cut off by the truncate above (or by an earlier run): clear the
    # header's PointerToSymbolTable/NumberOfSymbols, and give long section
    # names ("/4" -> string-table offset, e.g. .eh_frame) a literal 8-byte
    # name.  Otherwise the file is malformed and binutils rejects it
    # ("file format not recognized").
    fix_symbol_table(dll)

