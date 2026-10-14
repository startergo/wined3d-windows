#!/usr/bin/env python3
"""Differential test: D3DKMT{Create,Destroy}DCFromMemory and the D3DKMT
adapter stubs in the reference wined3d.dll (qemu-3dfx,
2.0.5 .. 8.0.2) vs our docker/d3dkmt_stubs.c, under tests/emu/emu.py.

  tests/emu/run.sh d3dkmt          # or: python3 tests/emu/test_d3dkmt.py [version ...]

Compares, per surface format/size: return codes, the BITMAPINFO handed to
CreateDIBSection, copy-in of the surface into the DIB, copy-back on destroy,
handle cleanup, the bookkeeping list under out-of-order destroys, GDI failure
paths, and the stub return codes.  Uses build/d3dkmt-ref.dll (reference
palette behaviour, see the deviation notes in docker/d3dkmt_stubs.c).
"""
import os, sys, struct, itertools
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from emu import Emu, Env

HERE = os.path.dirname(os.path.abspath(__file__))
REF_DIR = os.environ.get('QEMU3DFX_REF', os.path.join(HERE, 'reference'))
BUILD = os.environ.get('QEMU3DFX_EMU_BUILD', os.path.join(HERE, 'build'))
OURS = os.path.join(BUILD, 'd3dkmt-ref.dll')

# reference D3DKMTCreateDCFromMemory / D3DKMTDestroyDCFromMemory per version
REF_DC = {
    '2.0.5':  (0x1002b935, 0x1002badf),
    '3.0.5':  (0x100309a7, 0x10030b51),
    '4.12.1': (0x100421ec, 0x10042392),
    '5.0.5':  (0x10043adc, 0x10043c82),
    '6.0.4':  (0x1004bff1, 0x1004c199),
    '7.0.2':  (0x1004d647, 0x1004d7ef),
    '8.0.2':  (0x1004f9fc, 0x1004fba6),
}
# alphabetical order of the reference's small stubs (8.0.2 has all seven)
STUB_NAMES = ['D3DKMTCloseAdapter', 'D3DKMTCreateDevice', 'D3DKMTDestroyDevice',
              'D3DKMTOpenAdapterFromGdiDisplayName', 'D3DKMTOpenAdapterFromLuid',
              'D3DKMTQueryVideoMemoryInfo', 'D3DKMTSetVidPnSourceOwner']

FORMATS = [(20, 24), (21, 32), (22, 32), (23, 16), (24, 16), (25, 16), (26, 16), (30, 16), (41, 8)]
SIZES = [(64, 32), (17, 5), (1, 1)]

checks = fails = 0

def compare(label, a, b):
    global checks, fails
    checks += 1
    if a != b:
        fails += 1
        print('  FAIL %s\n       ref =%r\n       ours=%r' % (label, a, b))


class Side:
    def __init__(self, ver, kind, env):
        self.kind = kind
        self.e = Emu(env)
        if kind == 'ref':
            img = self.e.load(os.path.join(REF_DIR, ver, 'wined3d.dll'), 'ref')
            self.create, self.destroy = REF_DC[ver]
            self.img = img
        else:
            self.img = self.e.load(OURS, 'ours')
            self.create = self.img['exports']['D3DKMTCreateDCFromMemory']
            self.destroy = self.img['exports']['D3DKMTDestroyDCFromMemory']

    def make_surface(self, fmt, w, h, pitch, seed, palette=False):
        e = self.e
        mem = e.alloc(pitch * h)
        e.uc.mem_write(mem, bytes(((i * 7 + seed) & 0xff) for i in range(pitch * h)))
        pal = 0
        if palette:
            pal = e.alloc(256 * 4)
            e.uc.mem_write(pal, bytes(((i * 13 + 5) & 0xff) for i in range(1024)))
        desc = e.alloc(0x24)
        for off, v in ((0, mem), (4, fmt), (8, w), (0xc, h), (0x10, pitch), (0x14, 0x5555), (0x18, pal)):
            e.w32(desc + off, v)
        return mem, desc

    def create_dc(self, desc):
        rc = self.e.call(self.create, desc)
        hdc, hbm = self.e.r32(desc + 0x1c), self.e.r32(desc + 0x20)
        return rc, hdc, hbm

    def destroy_dc(self, hdc, hbm):
        dd = self.e.alloc(8)
        self.e.w32(dd, hdc); self.e.w32(dd + 4, hbm)
        return self.e.call(self.destroy, dd)

    def dib_bits(self, hbm):
        bits, n = self.e.dibs.get(hbm, (0, 0))
        return bits, n


def pitch_for(w, bpp, align):
    p = w * bpp // 8
    return (p + align - 1) // align * align


def defined_part(dib_log):
    """The reference builds a 52-byte BITMAPINFO (header + 3 mask slots) on
    the stack; for 8 bpp CreateDIBSection reads 256 RGBQUADs, i.e. 1 KB of
    stack garbage past those 12 bytes.  Compare only what is defined."""
    out = []
    for d in dib_log:
        d = dict(d)
        d['colors'] = d['colors'][:12]
        out.append(d)
    return out


def suite_formats(ver):
    for (fmt, bpp), (w, h), align in itertools.product(FORMATS, SIZES, (4, 8)):
        pitch = pitch_for(w, bpp, align)
        label = '%s fmt=%d %dx%d pitch=%d' % (ver, fmt, w, h, pitch)
        res = []
        for kind in ('ref', 'ours'):
            s = Side(ver, kind, Env())
            mem, desc = s.make_surface(fmt, w, h, pitch, seed=3, palette=(fmt == 41))
            rc, hdc, hbm = s.create_dc(desc)
            r = dict(rc=rc, have_dc=bool(hdc), have_bm=bool(hbm), dib=defined_part(s.e.dib_log),
                     selected=(s.e.selected.get(hdc) == hbm))
            bits, n = s.dib_bits(hbm)
            r['copy_in'] = bytes(s.e.uc.mem_read(bits, pitch * h)) == bytes(s.e.uc.mem_read(mem, pitch * h)) if bits else None
            if bits:  # simulate GDI drawing into the DIB
                s.e.uc.mem_write(bits, bytes(((i * 31 + 1) & 0xff) for i in range(pitch * h)))
            r['destroy_rc'] = s.destroy_dc(hdc, hbm)
            r['mem_after'] = bytes(s.e.uc.mem_read(mem, pitch * h))
            r['deleted'] = s.e.deleted[:]
            r['freed'] = len(s.e.freed)
            res.append(r)
        for k in res[0]:
            compare('%s %s' % (label, k), res[0][k], res[1][k])


def suite_list(ver):
    """three live DCs, destroyed out of order, plus a destroy of an unknown pair"""
    res = []
    for kind in ('ref', 'ours'):
        s = Side(ver, kind, Env())
        surf = []
        for i in range(3):
            mem, desc = s.make_surface(22, 8, 4, 32, seed=10 * i)
            rc, hdc, hbm = s.create_dc(desc)
            bits, n = s.dib_bits(hbm)
            s.e.uc.mem_write(bits, bytes([0xa0 + i]) * 128)
            surf.append((mem, hdc, hbm, rc))
        out = [tuple(x[3] for x in surf)]
        for i in (1, 0, 2):
            mem, hdc, hbm, _ = surf[i]
            out.append(s.destroy_dc(hdc, hbm))
            out.append(tuple(bytes(s.e.uc.mem_read(m, 128)) for m, _, _, _ in surf))
        out.append(s.destroy_dc(0xdead, 0xbeef))          # not in the list
        out.append(tuple(s.e.deleted))
        out.append(len(s.e.freed))
        res.append(out)
    compare('%s list/out-of-order destroy' % ver, res[0], res[1])


def suite_failures(ver):
    for fail in ('dc', 'dib', 'bits'):
        res = []
        for kind in ('ref', 'ours'):
            s = Side(ver, kind, Env(gdi_fail=fail))
            mem, desc = s.make_surface(23, 16, 8, 32, seed=1)
            rc, hdc, hbm = s.create_dc(desc)
            res.append((rc, bool(hdc), bool(hbm), len(s.e.dib_log), len(s.e.freed),
                        bytes(s.e.uc.mem_read(mem, 32 * 8))))
        compare('%s create with gdi_fail=%s' % (ver, fail), res[0], res[1])


def suite_stubs():
    """8.0.2 reference stubs sit just before CreateDCFromMemory, alphabetical"""
    ver = '8.0.2'
    ref = Side(ver, 'ref', Env())
    ours = Side(ver, 'ours', Env())
    stubs = [0x1004f9d6, 0x1004f9db, 0x1004f9e0, 0x1004f9e5, 0x1004f9ea, 0x1004f9ef, 0x1004f9f7]
    for name, addr in zip(STUB_NAMES, stubs):
        p1 = ref.e.alloc(0x100); p2 = ours.e.alloc(0x100)
        compare('8.0.2 %s return' % name, ref.e.call(addr, p1),
                ours.e.call(ours.img['exports'][name], p2))


if __name__ == '__main__':
    vers = sys.argv[1:] or list(REF_DC)
    for v in vers:
        print('== %s D3DKMT DC functions' % v)
        suite_formats(v)
        suite_list(v)
        suite_failures(v)
    print('== 8.0.2 D3DKMT stub return codes')
    suite_stubs()
    print('\n%d checks, %d failures' % (checks, fails))
    sys.exit(1 if fails else 0)
