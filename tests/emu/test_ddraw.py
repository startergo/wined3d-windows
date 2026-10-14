#!/usr/bin/env python3
"""Differential tests for the ddraw side of qemu-3dfx, reference ddraw.dll
8.0.2 vs ours, under tests/emu/emu.py:

  - the ddrawwq.dll forwarders (qemu3dfx_ddraw_hooks.c);
  - the ddthru router (qemu3dfx_ddthru.c): the reference's internal router
    at 0x1000ef6e vs qemu3dfx_ddthru(), compared on the routing decision and
    the exact log line sent to the host, for wined3d.mod present/absent and
    various contents, ddrawwq.dll present/absent, and callers inside and
    outside the listed module ranges.

  tests/emu/run.sh ddraw          # or: python3 tests/emu/test_ddraw.py

For a missing, complete, incomplete-core and incomplete-optional ddrawwq.dll
it compares return values, the forwarded calls and their arguments, and the
LoadLibrary/FreeLibrary sequence.  The two deliberate deviations (see
qemu3dfx_ddraw_hooks.c) are asserted explicitly instead of compared.
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from emu import Emu, Env, DDRAWWQ_EXPORTS
import itertools

HERE = os.path.dirname(os.path.abspath(__file__))
REF_DIR = os.environ.get('QEMU3DFX_REF', os.path.join(HERE, 'reference'))
BUILD = os.environ.get('QEMU3DFX_EMU_BUILD', os.path.join(HERE, 'build'))
REF = os.path.join(REF_DIR, '8.0.2', 'ddraw.dll')
OURS = os.path.join(BUILD, 'ddraw-hooks.dll')
E_NOTIMPL = 0x80004001

CORE = ('DirectDrawCreate', 'DirectDrawCreateClipper', 'DirectDrawCreateEx',
        'DirectDrawEnumerateA', 'DirectDrawEnumerateExA', 'GetSurfaceFromDC')

SCENARIOS = {
    'absent': None,
    'complete': set(DDRAWWQ_EXPORTS),
    'missing core GetSurfaceFromDC': set(DDRAWWQ_EXPORTS) - {'GetSurfaceFromDC'},
    'missing core DirectDrawCreateEx': set(DDRAWWQ_EXPORTS) - {'DirectDrawCreateEx'},
    'missing optional DDInternalLock': set(DDRAWWQ_EXPORTS) - {'DDInternalLock'},
}

TRACE = {'LoadLibraryA', 'FreeLibrary', 'DDInternalLock', 'DDInternalUnlock',
         'D3DParseUnknownCommand', 'CompleteCreateSysmemSurface',
         'AcquireDDThreadLock', 'ReleaseDDThreadLock', 'wined3d_mutex_lock', 'wined3d_mutex_unlock'}

checks = fails = 0

def check(label, ok, detail=''):
    global checks, fails
    checks += 1
    if not ok:
        fails += 1
        print('  FAIL %s %s' % (label, detail))

def compare(label, a, b):
    check(label, a == b, '\n       ref =%r\n       ours=%r' % (a, b))


def run(path, kind, exports, skip=()):
    e = Emu(Env(ddrawwq=exports))
    img = e.load(path, kind)
    x = img['exports']
    out = []
    p = e.alloc(8)
    calls = [('DDInternalLock', (0x1111, p)), ('DDInternalUnlock', (0x2222,)),
             ('D3DParseUnknownCommand', (0x3333, p)), ('CompleteCreateSysmemSurface', (0x4444,)),
             ('AcquireDDThreadLock', ()), ('ReleaseDDThreadLock', ()),
             ('DDInternalLock', (0x5555, p))]                 # second call: no reload
    for name, args in calls:
        if name in skip:
            out.append((name, 'skipped'))
            continue
        e.log.clear()
        rv = e.call(x[name], *args)
        trace = []
        for l in e.log:
            if l[0] in TRACE and (not trace or trace[-1] != l):   # handlers log once more
                trace.append(l)
        voidfn = name in ('AcquireDDThreadLock', 'ReleaseDDThreadLock')
        out.append((name, None if voidfn else rv, tuple(trace)))
    return out


# ---------------------------------------------------------------- ddthru
REF_ROUTER = 0x1000ef6e          # reference 8.0.2 router(caller, &table)
HANDLES = {'opengl32': 0x7e000000, 'kernel32': 0x7c000000,
           'game.exe': 0x00400000, 'mylib': 0x10a00000}
MOD_FILES = {
    'absent': None,
    'empty': b'',
    'exe range': b'game.exe,2000\n',
    'dll range with offset': b'mylib,800,1000\r\n',
    'unknown module first': b'nomod,100\ngame.exe,2000\n',
    'junk and two ranges': b'junk line without comma\nmylib,800,1000\ngame.exe,2000\n',
    'only unknown modules': b'nomod,100\nother,200,10\n',
    'long line': b'game.exe,2000,0' + b'0' * 70 + b'\nmylib,800,1000\n',
}
CALLERS = [0x00401000, 0x00402000, 0x00403000, 0x10a01400, 0x10a00400, 0x10a01801, 0x7d001234]


def ddthru_case(mod, ddrawwq, caller):
    files = {} if mod is None else {'wined3d.mod': mod}
    env = lambda: Env(ddrawwq=set(DDRAWWQ_EXPORTS) if ddrawwq else None,
                      files=files, module_handles=dict(HANDLES))
    r = Emu(env()); r.load(REF, 'ref')
    out = r.alloc(4); r.w32(out, 0xdeadbeef)
    r.log.clear()
    r.call(REF_ROUTER, caller, out)
    ref_decision = r.r32(out) != 0
    ref_msgs = [l[1][5][1] for l in r.log if l[0] == 'glDebugMessageInsertARB']

    o = Emu(env()); img = o.load(OURS, 'ours')
    o.log.clear()
    ours_decision = o.call(img['exports']['qemu3dfx_ddthru'], caller) != 0
    ours_msgs = [l[1][5][1] for l in o.log if l[0] == 'glDebugMessageInsertARB']
    flags = [l[1] for l in o.log if l[0] == 'passthru_flag']
    return ref_decision, ref_msgs, ours_decision, ours_msgs, flags


def suite_ddthru():
    print('== ddthru router (ref 0x1000ef6e vs qemu3dfx_ddthru)')
    passthru = 0
    for (label, mod), ddrawwq, caller in itertools.product(MOD_FILES.items(), (True, False), CALLERS):
        rd, rm, od, om, flags = ddthru_case(mod, ddrawwq, caller)
        tag = '%s ddrawwq=%s caller=%08x' % (label, ddrawwq, caller)
        compare('ddthru decision ' + tag, rd, od)
        compare('ddthru log ' + tag, rm, om)
        check('ddthru published flag ' + tag, flags == [int(od)], repr(flags))
        passthru += od
    check('ddthru scenarios include passthrough decisions', passthru > 0, str(passthru))


def main():
    for label, exports in SCENARIOS.items():
        print('== ddrawwq.dll %s' % label)
        skip = ()
        if exports is not None and 'DDInternalLock' not in exports:
            # the reference keeps the module and calls through a NULL pointer
            # for a missing optional export (crash); ours returns E_NOTIMPL
            skip = ('DDInternalLock',)
        ref = run(REF, 'ref', exports, skip)
        ours = run(OURS, 'ours', exports, skip)
        for r, o in zip(ref, ours):
            name = r[0]
            if name in ('AcquireDDThreadLock', 'ReleaseDDThreadLock') and \
                    not any(t[0] == name for t in r[2]):
                # no ddrawwq lock: the reference does nothing, ours falls back
                # to the wined3d mutex like stock Wine (deviation 2)
                want = 'wined3d_mutex_lock' if name.startswith('Acquire') else 'wined3d_mutex_unlock'
                check('%s %s falls back to %s' % (label, name, want),
                      any(t[0] == want for t in o[2]), repr(o))
                check('%s %s reference does nothing' % (label, name),
                      not any(t[0] in ('wined3d_mutex_lock', 'wined3d_mutex_unlock') for t in r[2]))
                continue
            compare('%s %s' % (label, name), r, o)
        if skip:
            e = Emu(Env(ddrawwq=exports))
            img = e.load(OURS, 'ours')
            check('%s DDInternalLock -> E_NOTIMPL (deviation 1)' % label,
                  e.call(img['exports']['DDInternalLock'], 1, e.alloc(4)) == E_NOTIMPL)
    suite_ddthru()
    print('\n%d checks, %d failures' % (checks, fails))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
