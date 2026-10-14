#!/usr/bin/env python3
"""Differential test: the qemu-3dfx module inside the reference wined3d.dll
(initialised by its own DllMain) vs our qemu3dfx_hooks.c,
both executed under tests/emu/emu.py with identical environments.

  tests/emu/run.sh module                    # or: python3 tests/emu/test_module.py [exports|internals]

Needs tests/emu/build/hooks-1.8.dll and hooks-8.0.dll (tests/emu/build.sh) and
the reference DLLs (tests/emu/extract-reference.sh).  See tests/emu/README.md.
"""
import os, sys, struct, itertools
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from emu import Emu, Env

HERE = os.path.dirname(os.path.abspath(__file__))
REF_DIR = os.environ.get('QEMU3DFX_REF', os.path.join(HERE, 'reference'))
BUILD = os.environ.get('QEMU3DFX_EMU_BUILD', os.path.join(HERE, 'build'))
REF = {v: os.path.join(REF_DIR, v, 'wined3d.dll') for v in ('1.8.7', '8.0.2')}
OURS = {'1.8.7': os.path.join(BUILD, 'hooks-1.8.dll'),
        '8.0.2': os.path.join(BUILD, 'hooks-8.0.dll')}

# reference-internal entry points (cdecl), reference 1.8.7 addresses
REF187_INTERNAL = dict(display_roi=0x10029473, override_mode=0x100294a2,
                       swap_interval=0x1002954b, scale_window=0x1002987b,
                       latch0=0x10029431, latch1=0x10029447, latch2=0x1002945d,
                       is_qemu_bochs=0x100290fc, set_host_cursor=0x10029561,
                       cursor_sync=0x10029592)
REF187_GLOBALS = dict(use_last_context_tid=0x1005e04c, scale_window=0x1005e064)
REF802_INTERNAL = dict(display_roi=0x1004f476, override_mode=0x1004f4a5,
                       swap_interval=0x1004f54e, scale_window=0x1004f8db,
                       latch0=0x1004f434, latch1=0x1004f44a, latch2=0x1004f460,
                       is_qemu_bochs=0x1004ee85, set_host_cursor=0x1004f5a8,
                       cursor_sync=0x1004f5d9, sysmem_quirk=0x1004f563)
REF802_GLOBALS = dict(use_last_context_tid=0x100d504c, scale_window=0x100d5064)
REF_INTERNAL = {'1.8.7': REF187_INTERNAL, '8.0.2': REF802_INTERNAL}
REF_GLOBALS = {'1.8.7': REF187_GLOBALS, '8.0.2': REF802_GLOBALS}
# gl_info offsets used by the reference cursor path: (ext flag, wglSetDeviceCursor3DFX, glDebugMessageInsertARB)
REF_GL = {'1.8.7': (0x270, 0x2fbc, 0xd44), '8.0.2': (0x37c, 0x3354, 0xe90)}
OUR_INTERNAL = dict(display_roi='qemu3dfx_display_roi', override_mode='qemu3dfx_override_mode',
                    swap_interval='qemu3dfx_swap_interval', scale_window='qemu3dfx_scale_window',
                    latch0='qemu3dfx_latch0', latch1='qemu3dfx_latch1', latch2='qemu3dfx_latch2',
                    is_qemu_bochs='qemu3dfx_is_qemu_bochs', set_host_cursor='qemu3dfx_set_host_cursor',
                    cursor_sync='qemu3dfx_cursor_sync')

TRACE_KEEP = {'Sleep', 'GetTickCount', 'wglSetDeviceCursor3DFX', 'glDebugMessageInsertARB',
              'GetSystemMetrics', 'MulDiv'}


class Side:
    def __init__(self, ver, kind, env):
        self.kind, self.ver = kind, ver
        self.e = Emu(env)
        if kind == 'ref':
            self.img = self.e.load(REF[ver], 'ref')
            self.e.call(self.img['entry'], self.img['base'], 1, 0)     # DllMain(PROCESS_ATTACH)
            self.ctx = self.e.alloc(0x40)                               # fake context -> gl_info
            gl = self.e.alloc(0x4000)
            flag, setcur, dbg = REF_GL[ver]
            self.e.w32(self.ctx + 0xc, gl)
            self.e.w32(gl + flag, 1)                                    # WGL_3DFX_gamma_control
            self.e.w32(gl + setcur, self.e.fn_stub('wglSetDeviceCursor3DFX'))
            self.e.w32(gl + dbg, self.e.fn_stub('glDebugMessageInsertARB'))
        else:
            self.img = self.e.load(OURS[ver], 'ours')
            # the reference DllMain(PROCESS_ATTACH) stores hInstDLL in the first
            # latch before wined3d_dll_init(); our wined3d DllMain must do the
            # same (call site, see re/CALLSITES.md) -- mirror it here.
            self.e.call(self.img['exports']['qemu3dfx_latch0'], 0x10000000)
        self.e.log.clear()
        self.e.clock_i = 0

    def exp(self, name, *args):
        return self.e.call(self.img['exports'][name], *args)

    def internal(self, name, *args):
        if self.kind == 'ref':
            if name in ('set_host_cursor', 'cursor_sync'):
                args = (self.ctx,) + args
            return self.e.call(REF_INTERNAL[self.ver][name], *args)
        return self.e.call(self.img['exports'][OUR_INTERNAL[name]], *args)

    def trace(self):
        t = [l for l in self.e.log if l[0] in TRACE_KEEP]
        self.e.log.clear()
        return t


fails = 0
checks = 0

def compare(label, a, b):
    global fails, checks
    checks += 1
    if a != b:
        fails += 1
        print('  FAIL %s\n       ref =%r\n       ours=%r' % (label, a, b))

def s32(v): return struct.unpack('<i', struct.pack('<I', v & 0xffffffff))[0]
def mem_rect(e, p): return tuple(s32(e.r32(p + 4 * i)) for i in range(4))

def run_pair(ver, env_kw, fn):
    return fn(Side(ver, 'ref', Env(**env_kw)), Side(ver, 'ours', Env(**env_kw)))


REG_CASES = [
    dict(def_={}, app=None),
    dict(def_={'D3D1Hal3Dfx': 'enabled'}, app=None),
    dict(def_={'D3D1Hal3Dfx': 'Enabled'}, app=None),
    dict(def_={'D3D1Hal3Dfx': 1}, app=None),
    dict(def_={'D3D1EnumHalLast': 'disabled'}, app=None),
    dict(def_={'UseLastContextTid': 'enabled'}, app=None),
    dict(def_={'UseLastContextTid': 'disabled'}, app=None),
    dict(def_={'DDSurfaceHeap': 'disabled'}, app=None),
    dict(def_={'BlitFpsLimit': 60, 'FlipFpsLimit': 30}, app=None),
    dict(def_={'BlitFpsLimit': 0x1ff, 'FlipFpsLimit': 0xff}, app=None),
    dict(def_={'ScaleWindow': 0x028001e0, 'OverrideCoopFullscreen': 1}, app=None),
    dict(def_={'ScaleWindow': 0x828001e0, 'OverrideCoopFullscreen': 0}, app=None),
    dict(def_={'OverrideCoopFullscreen': 1}, app=None),
    dict(def_={'DisplayROI': 0x00100020}, app=None),
    dict(def_={'OverrideModeWidth': 640}, app=None),
    dict(def_={'OverrideModeWidth': 0x028001e0}, app=None),
    dict(def_={'OverrideModeWidth': 0x80000320}, app=None),
    dict(def_={'SwapInterval': 0}, app=None),
    dict(def_={'D3D1Hal3Dfx': 'enabled', 'BlitFpsLimit': 30}, app={'D3D1Hal3Dfx': 'disabled', 'BlitFpsLimit': 75}),
    dict(def_={}, app={'D3D1Hal3Dfx': 'enabled', 'ScaleWindow': 0x01900100, 'DisplayROI': 0x00080008}),
]
EXES = ['C:\\GAMES\\TEST\\GAME.EXE', 'C:\\GAMES\\DS9\\ds9dw.exe', 'C:\\GAMES\\DS9\\DS9DW.EXE',
        'C:\\KONAMI\\SH4\\Silent Hill 4.exe', 'C:/WEIRD/ds9dw.exe']

def env_for(case, exe=EXES[0], **extra):
    kw = dict(registry={'def': case['def_'], 'app': case['app']}, exe=exe)
    kw.update(extra)
    return kw


def suite_exports(ver):
    print('== %s exported hooks' % ver)
    rtv_off = {'1.8.7': 0x28, '8.0.2': 0x34}[ver]
    for case, exe in itertools.product(REG_CASES, EXES):
        label = '%s %s exe=%s' % (ver, case, exe.replace('/', '\\').split('\\')[-1])
        def body(r, o):
            out = []
            for s in (r, o):
                res = {}
                res['hal_3dfx'] = s.exp('wined3d_hal_3dfx') & 0xff
                res['enum_hal_last'] = s.exp('wined3d_enum_hal_last') & 0xff
                if ver == '8.0.2':
                    res['surface_ddheap'] = s.exp('wined3d_surface_ddheap') & 0xff
                p = s.e.alloc(4)
                seq = []
                for v in (None, 1, None, 0, None, 7, None):
                    if v is None:
                        seq.append(s.exp('wined3d_passthru', 0))
                    else:
                        s.e.w32(p, v); seq.append(s.exp('wined3d_passthru', p))
                res['passthru_seq'] = tuple(seq)
                coop = []
                for v in (0, 1, 0x10, 0x11, 0x8, 0x29, 0xffffffff):
                    s.e.w32(p, v); s.exp('wined3d_override_cooplevel', p); coop.append(s.e.r32(p))
                res['cooplevel'] = tuple(coop)
                rtv = []
                for usage in (0, 1, 2, 0x200):
                    view = s.e.alloc(16); resource = s.e.alloc(0x80)
                    s.e.w32(view + 4, resource); s.e.w32(resource + rtv_off, usage)
                    s.exp('wined3d_override_rendertarget_view', view)
                    rtv.append(tuple(s.e.r32(resource + i) for i in range(0, 0x80, 4)))
                s.exp('wined3d_override_rendertarget_view', 0)
                res['rtv'] = tuple(rtv)
                s.trace()
                s.e.clock_i = 0
                s.e.env['clock'] = [1000, 1000, 1005, 1010, 1020, 1030, 1040, 1050, 1060]
                s.e.env['clock_step'] = 7
                for _ in range(3): s.exp('wined3d_blit_fpslimit')
                res['blit_trace'] = tuple(s.trace())
                for _ in range(3): s.exp('wined3d_flip_fpslimit')
                res['flip_trace'] = tuple(s.trace())
                out.append(res)
            for k in out[0]:
                compare('%s %s' % (label, k), out[0][k], out[1].get(k))
        run_pair(ver, env_for(case, exe), body)


def suite_internals(ver):
    print('== %s internal module functions' % ver)
    rects = [(0, 0, 640, 480), (10, 20, 650, 500), (-5, -5, 5, 5)]
    modes = [(640, 480, 8), (640, 480, 16), (640, 480, 32), (800, 600, 32), (1024, 768, 15)]
    for case in REG_CASES:
        def body(r, o):
            out = []
            for s in (r, o):
                e = s.e; res = {}
                if s.kind == 'ref':
                    res['ulct'] = e.r32(REF_GLOBALS[ver]['use_last_context_tid']) != 0
                    res['scale_value'] = e.r32(REF_GLOBALS[ver]['scale_window'])
                else:
                    res['ulct'] = (s.exp('qemu3dfx_use_last_context_tid') & 0xff) != 0
                    res['scale_value'] = s.exp('qemu3dfx_scale_window_value')
                roi = []
                for rc in rects:
                    p = e.alloc(16)
                    for i, v in enumerate(rc): e.w32(p + 4 * i, v)
                    s.internal('display_roi', p); roi.append(mem_rect(e, p))
                res['roi'] = tuple(roi)
                md = []
                for w, h, bpp in modes:
                    dm = e.alloc(0x9c)
                    e.w32(dm + 0x68, bpp); e.w32(dm + 0x6c, w); e.w32(dm + 0x70, h)
                    rv = s.internal('override_mode', dm)
                    md.append((rv & 0xff, e.r32(dm + 0x68), e.r32(dm + 0x6c), e.r32(dm + 0x70)))
                res['mode'] = tuple(md)
                si = []
                for v in (1, 0, 5):
                    p = e.alloc(4); e.w32(p, v); s.internal('swap_interval', p); si.append(e.r32(p))
                res['swap'] = tuple(si)
                sw = []
                for combo in itertools.product((0, 1), repeat=3):
                    a = e.alloc(16) if combo[0] else 0
                    b = e.alloc(16) if combo[1] else 0
                    c = e.alloc(4) if combo[2] else 0
                    for q in (a, b):
                        if q:
                            for i in range(4): e.w32(q + 4 * i, 0x55)
                    if c: e.w32(c, 9)
                    rv = s.internal('scale_window', a, b, c)
                    sw.append((rv & 0xff, mem_rect(e, a) if a else None, mem_rect(e, b) if b else None,
                               e.r32(c) if c else None))
                res['scale'] = tuple(sw)
                lt = []
                for name in ('latch0', 'latch1', 'latch2'):
                    lt.append(tuple(s.internal(name, v) for v in (0, 0x1234, 0, 0x99, 0)))
                res['latches'] = tuple(lt)
                out.append(res)
            for k in out[0]:
                compare('%s %s %s' % (ver, case, k), out[0][k], out[1][k])
        run_pair(ver, env_for(case), body)

    print('== %s adapter detection / host cursor' % ver)
    for adapter in ('QEMU Bochs Compatible VGA', 'QEMU Bochs', 'QEMU', 'QEMU bochs', 'Standard VGA', None):
        def body(r, o):
            compare('%s is_qemu_bochs(%r)' % (ver, adapter), r.internal('is_qemu_bochs') & 0xff,
                    o.internal('is_qemu_bochs') & 0xff)
            for s in (r, o): s.trace()
            for s in (r, o): s.internal('set_host_cursor', 0xc0ffee)
            compare('%s set_host_cursor(%r) trace' % (ver, adapter), r.trace(), o.trace())
        run_pair(ver, dict(adapter=adapter), body)

    scripts = [
        ('visible, moving', [dict(flags=1, h=0x11, x=100, y=200), dict(flags=1, h=0x11, x=100, y=200),
                             dict(flags=1, h=0x22, x=300, y=40), dict(flags=1, h=0x22, x=630, y=500)]),
        ('hidden then shown', [dict(flags=0, h=0x11, x=5, y=5), dict(flags=1, h=0x11, x=5, y=500),
                               dict(flags=0, h=0x0, x=0, y=0)]),
        ('GetCursorInfo fails', [None, dict(flags=1, h=0x33, x=50, y=60)]),
    ]
    for adapter in ('QEMU Bochs Compatible VGA', 'Standard VGA'):
        for name, steps in scripts:
            for clock in ([1000, 1005, 1030, 1031, 1060, 1100, 1200, 1300, 1400],
                          [100, 200, 300, 400, 500, 600, 700, 800]):
                def body(r, o):
                    tr = []
                    for s in (r, o):
                        t = []
                        s.e.clock_i = 0; s.e.env['clock'] = clock; s.e.env['clock_step'] = 50
                        for st in steps:
                            s.e.env['cursor'] = st
                            s.internal('cursor_sync', 0x777)
                            t.append(tuple(s.trace()))
                        tr.append(t)
                    compare('%s cursor_sync %s/%s clock=%s' % (ver, adapter.split()[0], name, clock[:3]), tr[0], tr[1])
                run_pair(ver, dict(adapter=adapter, window=(10, 20, 650, 520), client=(0, 0, 632, 474)), body)


def suite_sysmem_quirk():
    ver = '8.0.2'
    print('== 8.0.2 Silent Hill 4 / quartz sysmem quirk')
    for exe, modules, loc, count in itertools.product(
            ['C:\\KONAMI\\SH4\\Silent Hill 4.exe', 'C:\\KONAMI\\SH4\\SILENT HILL 4.EXE', 'C:\\GAMES\\GAME.EXE'],
            [(), ('quartz',)], [0x12, 0x2, 0x10, 0x13, 0x32], [0, 1, 2]):
        def body(r, o):
            # reference: quirk(texture) reads texture->sub_resources[0].locations
            tex = r.e.alloc(0x200); sub = r.e.alloc(0x34 * 2)
            r.e.w32(tex + 0x158, sub); r.e.w32(sub + 0x18, loc); r.e.w32(tex + 0xc0, count)
            r.internal('sysmem_quirk', tex)
            cnt = o.e.alloc(4); o.e.w32(cnt, count)
            o.e.call(o.img['exports']['qemu3dfx_sysmem_count_quirk'], loc, cnt)
            compare('8.0.2 sysmem_quirk exe=%s modules=%s loc=%#x count=%d' % (exe.split('\\')[-1], modules, loc, count),
                    r.e.r32(tex + 0xc0), o.e.r32(cnt))
        run_pair(ver, dict(exe=exe, modules=modules), body)


if __name__ == '__main__':
    only = sys.argv[1:] or ['exports', 'internals']
    if 'exports' in only:
        for v in ('1.8.7', '8.0.2'):
            suite_exports(v)
    if 'internals' in only:
        for v in ('1.8.7', '8.0.2'):
            suite_internals(v)
        suite_sysmem_quirk()
    print('\n%d checks, %d failures' % (checks, fails))
    sys.exit(1 if fails else 0)
