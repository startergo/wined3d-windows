#!/usr/bin/env python3
"""Patch PE headers for Windows 98 compatibility and strip COFF debug sections."""
import struct, glob, os, sys

outdir = sys.argv[1] if len(sys.argv) > 1 else '/output'
for dll in glob.glob(os.path.join(outdir, '*.dll')):
    with open(dll, 'r+b') as f:
        data = f.read()
        pe_off = struct.unpack_from('<I', data, 0x3C)[0]
        coff = pe_off + 4
        opt = pe_off + 24
        opt_size = struct.unpack_from('<H', data, coff + 16)[0]
        nsec = struct.unpack_from('<H', data, coff + 2)[0]

        old_dc = struct.unpack_from('<H', data, opt + 70)[0]
        old_subsys = struct.unpack_from('<H', data, opt + 68)[0]
        old_major = struct.unpack_from('<H', data, opt + 72)[0]
        old_minor = struct.unpack_from('<H', data, opt + 74)[0]

        f.seek(opt + 68); f.write(struct.pack('<H', 2))       # Subsystem = GUI
        f.seek(opt + 72); f.write(struct.pack('<H', 4))       # MajorSubsystemVersion
        f.seek(opt + 74); f.write(struct.pack('<H', 10))      # MinorSubsystemVersion
        f.seek(opt + 70); f.write(struct.pack('<H', 0x0000))   # Clear DllCharacteristics

        sec_off = opt + opt_size
        strip = [i for i in range(nsec)
                 if data[sec_off+i*40:sec_off+i*40+8].split(b'\x00')[0].startswith(b'/')]

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
            print(f'  Win98 PE: Subsys={old_subsys}->2 DllChar=0x{old_dc:04x}->0x0000, stripped {len(strip)} debug ({os.path.basename(dll)})')
        else:
            print(f'  Win98 PE: Subsys={old_subsys}->2 DllChar=0x{old_dc:04x}->0x0000 ({os.path.basename(dll)})')
