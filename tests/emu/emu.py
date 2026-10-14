#!/usr/bin/env python3
"""emu.py — tiny Win32 user-mode emulator (Unicorn) for differential testing
of our Win9x wined3d additions against the qemu-3dfx reference DLLs.
See tests/emu/README.md.

Each PE is mapped at its preferred base, every import is bound to a Python
handler, and functions are called with a synthetic stack.  The environment
(registry, exe path, display adapter, clock, cursor, window rects) is a
plain dict so both images see exactly the same world, and every API call is
logged so call sequences can be compared too.
"""
import re, struct, importlib.util, os
from unicorn import Uc, UcError, UC_ARCH_X86, UC_MODE_32, UC_HOOK_CODE, UC_HOOK_MEM_INVALID
from unicorn.x86_const import *

HERE = os.path.dirname(os.path.abspath(__file__))
_s = importlib.util.spec_from_file_location('wu', os.path.join(HERE, '..', '..', 'tools', 'win98-universe.py'))
wu = importlib.util.module_from_spec(_s); _s.loader.exec_module(wu)

STUB_BASE = 0x70000000
STACK_TOP = 0x0fff0000
HEAP_BASE = 0x60000000
SCRATCH = 0x50000000
RET_MAGIC = 0x7ffe0000

class Stop(Exception):
    pass

# Functions handed out by fake modules (wglGetProcAddress, the fake
# ddrawwq.dll): stdcall argument counts and distinctive return values.
FAKE_NARGS = {'wglSetDeviceCursor3DFX': 1, 'glDebugMessageInsertARB': 6,
              'DDInternalLock': 2, 'DDInternalUnlock': 1, 'D3DParseUnknownCommand': 2,
              'CompleteCreateSysmemSurface': 1, 'AcquireDDThreadLock': 0,
              'ReleaseDDThreadLock': 0}
FAKE_RET = {'DDInternalLock': 0x11, 'DDInternalUnlock': 0x22, 'D3DParseUnknownCommand': 0x33,
            'CompleteCreateSysmemSurface': 0x44}
FAKE_DDRAWWQ = 0x7b000000
DDRAWWQ_EXPORTS = ('DirectDrawCreate', 'DirectDrawCreateClipper', 'DirectDrawCreateEx',
                   'DirectDrawEnumerateA', 'DirectDrawEnumerateExA', 'GetSurfaceFromDC',
                   'AcquireDDThreadLock', 'ReleaseDDThreadLock', 'DDInternalLock',
                   'DDInternalUnlock', 'D3DParseUnknownCommand', 'CompleteCreateSysmemSurface')

# argument counts (stdcall callee-pops unless listed in CDECL)
NARGS = {
    'GetTickCount': 0, 'Sleep': 1, 'GetModuleFileNameA': 3, 'RegOpenKeyA': 3,
    'RegOpenKeyExA': 5, 'RegQueryValueExA': 6, 'RegCloseKey': 1, 'lstrcpyA': 2,
    'lstrcatA': 2, 'lstrcmpiA': 2, 'EnumDisplayDevicesA': 4, 'GetSystemMetrics': 1,
    'MulDiv': 3, 'GetCursorInfo': 1, 'GetWindowRect': 2, 'GetClientRect': 2,
    'wglGetProcAddress': 1, 'DisableThreadLibraryCalls': 1, 'GetProcessHeap': 0,
    'HeapAlloc': 3, 'HeapFree': 3, 'HeapReAlloc': 4, 'GetVersionExA': 1, 'GetVersion': 0,
    'TlsAlloc': 0, 'TlsGetValue': 1, 'TlsSetValue': 2, 'TlsFree': 1,
    'InitializeCriticalSection': 1, 'EnterCriticalSection': 1, 'LeaveCriticalSection': 1,
    'DeleteCriticalSection': 1, 'GetModuleHandleA': 1, 'GetModuleHandleW': 1,
    'GetProcAddress': 2, 'LoadLibraryA': 1, 'FreeLibrary': 1, 'GetLastError': 0,
    'SetLastError': 1, 'RegisterClassA': 1, 'RegisterClassW': 1, 'RegisterClassExA': 1,
    'RegisterClassExW': 1, 'UnregisterClassA': 2, 'UnregisterClassW': 2,
    'GetCurrentThreadId': 0, 'GetCurrentProcessId': 0, 'InterlockedIncrement': 1,
    'InterlockedDecrement': 1, 'InterlockedExchange': 2, 'InterlockedCompareExchange': 3,
    'VirtualQuery': 3, 'VirtualProtect': 4, 'GetSystemInfo': 1, 'CreateEventA': 4,
    'CreateEventW': 4, 'CloseHandle': 1, 'SetEvent': 1, 'GlobalMemoryStatus': 1,
    'IsProcessorFeaturePresent': 1, 'GetEnvironmentVariableA': 3, 'GetEnvironmentVariableW': 3,
    'MultiByteToWideChar': 6, 'WideCharToMultiByte': 8, 'GetACP': 0, 'IsDBCSLeadByteEx': 2,
    'AreFileApisANSI': 0, 'LoadCursorA': 2, 'GetDC': 1, 'ReleaseDC': 2,
    'GetDeviceCaps': 2, 'CreateDCA': 4, 'DeleteDC': 1, 'GetStockObject': 1,
    'CreateCompatibleDC': 1, 'CreateDIBSection': 6, 'SelectObject': 2, 'DeleteObject': 1,
    'CreateFileA': 7, 'ReadFile': 5, 'wined3d_passthru': 1,
}
CDECL = {'fopen', 'fgets', 'fclose', 'wsprintfA', 'strcmp', '_stricmp', 'memcmp', 'memset', 'memcpy', 'memmove', 'strlen', 'strchr',
         'strrchr', 'malloc', 'calloc', 'realloc', 'free', 'strncmp', 'strcpy', '_initterm',
         'atexit', '_onexit', '__dllonexit', '_lock', '_unlock', '_amsg_exit', 'abort',
         'getenv', 'strtol', 'strtoul', 'atoi', '_strdup', 'strstr', 'sprintf', '_vsnprintf',
         'fprintf', 'fwrite', '__p__iob', '_iob', '__setusermatherr', 'signal', 'tolower',
         'toupper', 'isspace', 'isdigit', '__p___mb_cur_max', '___lc_codepage_func', 'localeconv',
         'setlocale', 'mbstowcs', 'wcstombs', 'strerror', '_errno', 'bsearch', 'qsort',
         'sscanf', 'rand', 'srand', '_snprintf', '_vscprintf', 'wcslen', 'vfprintf', 'fputc',
         '__getmainargs', '_cexit', '_exit', 'exit', 'isalpha', 'isupper', 'isprint', 'strcspn',
         '_write', 'ldexp', 'pow', 'exp', '_beginthreadex'}


class Env(dict):
    """registry: {'def': {name: value}, 'app': {name: value} or None};
    str -> REG_SZ, int -> REG_DWORD"""
    def __init__(self, **kw):
        super().__init__(dict(exe='C:\\GAMES\\TEST\\GAME.EXE', registry={'def': {}, 'app': None},
                              adapter='QEMU Bochs Compatible VGA', clock=[1000], clock_step=1,
                              screen=(1024, 768), cursor=dict(flags=1, h=0x1234, x=100, y=200),
                              window=(10, 20, 650, 520), client=(0, 0, 640, 480)))
        self.update(kw)


class Emu:
    def __init__(self, env, trace_unknown=False):
        self.env = env
        self.uc = Uc(UC_ARCH_X86, UC_MODE_32)
        self.log = []
        self.stubs = {}
        self.next_stub = STUB_BASE
        self.heap = HEAP_BASE
        self.handles = {}
        self.next_handle = 0x1000
        self.trace_unknown = trace_unknown
        uc = self.uc
        uc.mem_map(STUB_BASE, 0x100000)
        uc.mem_map(STACK_TOP - 0x200000, 0x200000)
        uc.mem_map(HEAP_BASE, 0x2000000)
        uc.mem_map(SCRATCH, 0x100000)
        uc.mem_map(RET_MAGIC, 0x1000)
        uc.mem_map(0x7ffdf000, 0x1000)       # fake TEB/PEB
        uc.hook_add(UC_HOOK_CODE, self._stub_hook, begin=STUB_BASE, end=STUB_BASE + 0x100000)
        uc.hook_add(UC_HOOK_CODE, self._ret_hook, begin=RET_MAGIC, end=RET_MAGIC + 0x10)
        self._setup_gdt()
        self.images = {}
        self.clock_i = 0
        self.dib_log, self.dibs, self.selected, self.deleted, self.freed = [], {}, {}, [], []

    # ---------------------------------------------------------------- PE
    def load(self, path, name):
        pe = wu.PE(path)
        size = max(va + sz for va, sz, _, _ in pe.sections)
        size = (size + 0xfff) & ~0xfff
        base = pe.imagebase
        self.uc.mem_map(base, size + 0x1000)
        self.uc.mem_write(base, pe.d[:0x1000])
        for va, sz, raw, rawsz in pe.sections:
            if rawsz:
                self.uc.mem_write(base + va, pe.d[raw:raw + min(rawsz, sz)])
        # bind imports
        import struct as st
        if len(pe.dirs) > 1 and pe.dirs[1][0]:
            rva = pe.dirs[1][0]
            while True:
                o = pe.off(rva)
                oft, _, _, nm, ft = st.unpack_from('<IIIII', pe.d, o)
                if not (oft or nm or ft):
                    break
                dll = pe.cstr(nm).upper()
                for i, sym in enumerate(pe._walk_thunks(oft or ft)):
                    self.uc.mem_write(base + ft + 4 * i, st.pack('<I', self._stub(dll, sym)))
                rva += 20
        exps = {}
        eo = pe.off(pe.dirs[0][0])
        (_, _, _, _, _, ebase, nf, nn, af, an, ao) = st.unpack_from('<IIHHIIIIIII', pe.d, eo)
        for i in range(nn):
            n = pe.cstr(pe.u32(an + 4 * i))
            exps[n] = base + pe.u32(af + 4 * pe.u16(ao + 2 * i))
        opt = st.unpack_from('<I', pe.d, 0x3c)[0] + 24
        entry = base + st.unpack_from('<I', pe.d, opt + 16)[0]
        self.images[name] = dict(pe=pe, base=base, exports=exps, entry=entry)
        return self.images[name]

    def _stub(self, dll, sym):
        key = (dll, sym)
        for a, k in self.stubs.items():
            if k == key:
                return a
        a = self.next_stub
        self.next_stub += 0x10
        self.stubs[a] = key
        self.uc.mem_write(a, b'\xc3')          # ret (never reached; hook handles)
        return a

    def fn_stub(self, name):
        """an address that, when called, logs `name` with its stack args"""
        return self._stub('FAKE', name)

    # ---------------------------------------------------------------- mem
    def r32(self, a): return struct.unpack('<I', self.uc.mem_read(a, 4))[0]
    def w32(self, a, v): self.uc.mem_write(a, struct.pack('<I', v & 0xffffffff))
    def rstr(self, a, n=512):
        b = bytes(self.uc.mem_read(a, n)); return b.split(b'\0')[0].decode('latin-1')
    def wstr(self, a, s): self.uc.mem_write(a, s.encode('latin-1') + b'\0')
    def alloc(self, n):
        a = self.heap; self.heap += (n + 15) & ~15
        self.uc.mem_write(a, b'\0' * n); return a

    # ---------------------------------------------------------------- GDT
    def _setup_gdt(self):
        """flat 32-bit code/data segments plus an FS segment at the fake TEB"""
        GDT = 0x40000000
        self.uc.mem_map(GDT, 0x1000)
        def desc(base, limit, access, flags):
            return struct.pack('<HHBBBB', limit & 0xffff, base & 0xffff, (base >> 16) & 0xff,
                               access, ((limit >> 16) & 0xf) | (flags << 4), (base >> 24) & 0xff)
        gdt = b'\0' * 8
        gdt += desc(0, 0xfffff, 0x9b, 0xc)          # 1: code, ring0, 32-bit, 4K gran
        gdt += desc(0, 0xfffff, 0x93, 0xc)          # 2: data
        gdt += desc(0x7ffdf000, 0xfff, 0x93, 0x4)  # 3: FS -> TEB
        self.uc.mem_write(GDT, gdt)
        self.uc.reg_write(UC_X86_REG_GDTR, (0, GDT, len(gdt) - 1, 0))
        self.uc.reg_write(UC_X86_REG_CS, 1 << 3)
        for r in (UC_X86_REG_DS, UC_X86_REG_ES, UC_X86_REG_SS, UC_X86_REG_GS):
            self.uc.reg_write(r, 2 << 3)
        self.uc.reg_write(UC_X86_REG_FS, 3 << 3)
        # minimal TEB: SEH list end, stack base/limit, self pointer, PEB
        teb = 0x7ffdf000
        self.w32(teb + 0x00, 0xffffffff)
        self.w32(teb + 0x04, STACK_TOP)
        self.w32(teb + 0x08, STACK_TOP - 0x200000)
        self.w32(teb + 0x18, teb)
        self.w32(teb + 0x24, 0x42)
        self.w32(teb + 0x30, teb + 0x800)

    # ---------------------------------------------------------------- call
    def call(self, addr, *args, stdcall=None, max_insn=5_000_000):
        uc = self.uc
        sp = STACK_TOP - 0x1000
        for a in reversed(args):
            sp -= 4; self.w32(sp, a)
        sp -= 4; self.w32(sp, RET_MAGIC)
        uc.reg_write(UC_X86_REG_ESP, sp)
        uc.reg_write(UC_X86_REG_EBP, 0)
        self.ret_sp = None
        try:
            uc.emu_start(addr, RET_MAGIC, count=max_insn)
        except Stop:
            pass
        except UcError as e:
            raise RuntimeError('emulation fault at %#x: %s' % (uc.reg_read(UC_X86_REG_EIP), e))
        return uc.reg_read(UC_X86_REG_EAX)

    def _ret_hook(self, uc, addr, size, ud):
        uc.emu_stop()

    # ---------------------------------------------------------------- APIs
    def _stub_hook(self, uc, addr, size, ud):
        dll, sym = self.stubs.get(addr, ('?', '?'))
        esp = uc.reg_read(UC_X86_REG_ESP)
        ret = self.r32(esp)
        n = NARGS.get(sym, 0)
        args = [self.r32(esp + 4 + 4 * i) for i in range(8)]
        h = getattr(self, 'api_' + sym, None)
        if dll == 'FAKE':
            n = FAKE_NARGS.get(sym, 0)
            h = None
            a = list(args[:n])
            if sym == 'glDebugMessageInsertARB':
                a[5] = ('text', self.rstr(a[5], 0xc0)) if a[4] == 0xc0 else ('payload', self.r32(a[5]))
            self.log.append((sym, tuple(a)))
            r = FAKE_RET.get(sym, 1)
        elif h is None:
            if self.trace_unknown:
                self.log.append(('UNSTUBBED', dll + '!' + sym))
            r = 0
            if sym in ('malloc', 'calloc'):
                r = self.alloc(args[0] * (args[1] if sym == 'calloc' else 1) or 16)
            elif sym in ('GetProcessHeap',):
                r = 0x5000
            elif sym == 'HeapAlloc':
                r = self.alloc(args[2] or 16)
            elif sym in ('TlsAlloc',):
                r = 1
            elif sym in ('GetCurrentThreadId', 'GetCurrentProcessId'):
                r = 0x42
            elif sym in ('InterlockedIncrement',):
                v = self.r32(args[0]) + 1; self.w32(args[0], v); r = v
            elif sym in ('InterlockedDecrement',):
                v = self.r32(args[0]) - 1; self.w32(args[0], v); r = v
            elif sym in ('RegisterClassA', 'RegisterClassW', 'RegisterClassExA', 'RegisterClassExW', 'DisableThreadLibraryCalls'):
                r = 1
            elif sym in ('_initterm',):
                r = self._initterm(args[0], args[1])
        else:
            r = h(*args)
            if sym not in ('GetTickCount',):
                self.log.append((sym,) + tuple(self._fmt(sym, args)))
        if sym in CDECL or dll.startswith('MSVCRT'):
            n = 0
        uc.reg_write(UC_X86_REG_EAX, r & 0xffffffff)
        uc.reg_write(UC_X86_REG_ESP, esp + 4 + 4 * n)
        uc.reg_write(UC_X86_REG_EIP, ret)

    def _initterm(self, a, b):
        # run nothing: constructors are not needed by the code under test
        return 0

    def _fmt(self, sym, args):
        if sym in ('RegQueryValueExA',):
            return (self.handles.get(args[0], args[0]), self.rstr(args[1]))
        if sym in ('RegOpenKeyA',):
            return (self.handles.get(args[0], hex(args[0])), self.rstr(args[1]))
        if sym in ('Sleep', 'GetSystemMetrics'):
            return (args[0],)
        if sym == 'MulDiv':
            return tuple(struct.unpack('<iii', struct.pack('<III', *args[:3])))
        return ()

    def api_GetTickCount(self, *a):
        c = self.env['clock']
        if self.clock_i < len(c):
            t = c[self.clock_i]
        else:
            t = c[-1] + (self.clock_i - len(c) + 1) * self.env['clock_step']
        self.clock_i += 1
        self.log.append(('GetTickCount', t))
        return t

    def api_Sleep(self, ms, *a):
        return 0

    def api_GetModuleFileNameA(self, h, buf, n, *a):
        s = self.env['exe']
        b = s.encode('latin-1')
        if len(b) >= n:
            self.uc.mem_write(buf, b[:n - 1] + b'\0'); return n
        self.wstr(buf, s); return len(b)

    def _newhandle(self, what):
        h = self.next_handle; self.next_handle += 4; self.handles[h] = what; return h

    def api_RegOpenKeyA(self, hkey, sub, phk, *a):
        sub = self.rstr(sub)
        parent = self.handles.get(hkey, 'HKCU' if hkey == 0x80000001 else hex(hkey))
        reg = self.env['registry']
        path = (parent + '\\' + sub)
        if path == 'HKCU\\Software\\Wine\\Direct3D':
            h = self._newhandle('def')
        elif path == 'HKCU\\Software\\Wine\\AppDefaults':
            h = self._newhandle('appdefaults')
        elif parent == 'appdefaults' and reg.get('app') is not None and \
                sub.lower() == (self.env['exe'].split('\\')[-1] + '\\Direct3D').lower():
            h = self._newhandle('app')
        else:
            return 2                          # ERROR_FILE_NOT_FOUND
        self.w32(phk, h); return 0

    def api_RegOpenKeyExA(self, hkey, sub, opt, sam, phk, *a):
        return self.api_RegOpenKeyA(hkey, sub, phk)

    def api_RegQueryValueExA(self, hkey, name, res, ptype, data, plen, *a):
        which = self.handles.get(hkey)
        vals = self.env['registry'].get(which) or {}
        name = self.rstr(name)
        if name not in vals:
            return 2
        v = vals[name]
        if isinstance(v, int):
            t, b = 4, struct.pack('<I', v & 0xffffffff)
        else:
            t, b = 1, v.encode('latin-1') + b'\0'
        if ptype: self.w32(ptype, t)
        if plen:
            cap = self.r32(plen)
            if data and cap < len(b):
                self.w32(plen, len(b)); return 234    # ERROR_MORE_DATA
            self.w32(plen, len(b))
        if data: self.uc.mem_write(data, b)
        return 0

    def api_RegCloseKey(self, h, *a): return 0
    def api_GetModuleHandleA(self, name, *a):
        if not name:
            return 0x400000
        n = self.rstr(name).lower()
        if n.endswith('.dll'): n = n[:-4]
        handles = self.env.get('module_handles')
        if handles is not None:
            return handles.get(n, 0)
        return 0x7a000000 if n in [m.lower() for m in self.env.get('modules', ())] else 0
    def api_lstrcpyA(self, d, s, *a): self.wstr(d, self.rstr(s)); return d
    def api_lstrcatA(self, d, s, *a): self.wstr(d, self.rstr(d) + self.rstr(s)); return d
    def api_lstrcmpiA(self, a_, b_, *a):
        x, y = self.rstr(a_).lower(), self.rstr(b_).lower(); return (x > y) - (x < y)
    def api__stricmp(self, a_, b_, *a): return self.api_lstrcmpiA(a_, b_)
    def api_strcmp(self, a_, b_, *a):
        x, y = self.rstr(a_), self.rstr(b_); return (x > y) - (x < y)
    def api_memcmp(self, a_, b_, n, *a):
        x = bytes(self.uc.mem_read(a_, n)); y = bytes(self.uc.mem_read(b_, n))
        return (x > y) - (x < y)
    def api_memset(self, d, c, n, *a): self.uc.mem_write(d, bytes([c & 0xff]) * n); return d
    def api_memcpy(self, d, s, n, *a): self.uc.mem_write(d, bytes(self.uc.mem_read(s, n))); return d
    def api_strlen(self, s, *a): return len(self.rstr(s, 4096))
    def api_strrchr(self, s, c, *a):
        t = self.rstr(s, 4096); i = t.rfind(chr(c & 0xff)); return 0 if i < 0 else s + i
    def api_strchr(self, s, c, *a):
        t = self.rstr(s, 4096); i = t.find(chr(c & 0xff)); return 0 if i < 0 else s + i
    def api_strcat(self, d, s, *a): self.wstr(d, self.rstr(d) + self.rstr(s)); return d
    def api_strcpy(self, d, s, *a): self.wstr(d, self.rstr(s)); return d

    def api_EnumDisplayDevicesA(self, dev, i, dd, flags, *a):
        if self.env['adapter'] is None or i:
            return 0
        self.uc.mem_write(dd + 4 + 32, self.env['adapter'].encode('latin-1')[:127] + b'\0')
        return 1

    def api_GetSystemMetrics(self, i, *a):
        return self.env['screen'][0] if i == 0 else self.env['screen'][1] if i == 1 else 0

    def api_MulDiv(self, a_, b_, c_, *a):
        a_, b_, c_ = struct.unpack('<iii', struct.pack('<III', a_, b_, c_))
        if c_ == 0: return -1
        r = a_ * b_
        neg = (r < 0) != (c_ < 0)
        q = (abs(r) + abs(c_) // 2) // abs(c_)
        return -q if neg else q

    def api_GetCursorInfo(self, p, *a):
        c = self.env['cursor']
        if c is None: return 0
        self.w32(p + 4, c['flags']); self.w32(p + 8, c['h'])
        self.w32(p + 12, c['x']); self.w32(p + 16, c['y'])
        return 1

    def _rect(self, p, r):
        for i, v in enumerate(r): self.w32(p + 4 * i, v)
        return 1
    def api_GetWindowRect(self, h, p, *a): return self._rect(p, self.env['window'])
    def api_GetClientRect(self, h, p, *a): return self._rect(p, self.env['client'])

    def api_wglGetProcAddress(self, name, *a):
        n = self.rstr(name)
        if n in ('wglSetDeviceCursor3DFX', 'glDebugMessageInsertARB'):
            return self.fn_stub(n)
        return 0

    # ---- GDI (DIB sections) -------------------------------------------
    # env['gdi_fail'] may be 'dc', 'dib' or 'bits' to simulate failures.
    def api_CreateCompatibleDC(self, hdc, *a):
        if self.env.get('gdi_fail') == 'dc':
            return 0
        return self._newhandle('hdc')

    def api_CreateDIBSection(self, hdc, pbmi, usage, ppbits, section, offset, *a):
        hdr = struct.unpack('<IiiHHIIiiII', bytes(self.uc.mem_read(pbmi, 40)))
        size, width, height, planes, bpp, comp, sizeimg = hdr[:7]
        clrused = hdr[9]
        masks = struct.unpack('<III', bytes(self.uc.mem_read(pbmi + 40, 12)))
        ncolors = clrused or (256 if bpp == 8 else 0)
        colors = bytes(self.uc.mem_read(pbmi + 40, 4 * ncolors)) if ncolors else b''
        self.dib_log.append(dict(hdr=hdr, masks=masks if comp == 3 else None,
                                 colors=colors, usage=usage, section=section, offset=offset,
                                 hdc_valid=hdc in self.handles))
        fail = self.env.get('gdi_fail')
        if fail == 'dib':
            if ppbits: self.w32(ppbits, 0)
            return 0
        stride = ((abs(width) * bpp + 31) // 32) * 4
        nbytes = stride * abs(height)
        bits = 0 if fail == 'bits' else self.alloc(max(nbytes, 4))
        if ppbits: self.w32(ppbits, bits)
        h = self._newhandle('hbitmap')
        self.dibs[h] = (bits, nbytes)
        return h

    def api_SelectObject(self, hdc, obj, *a):
        self.selected[hdc] = obj; return 0x99
    def api_DeleteDC(self, hdc, *a):
        self.deleted.append(('dc', self.handles.get(hdc, hdc))); return 1
    def api_DeleteObject(self, obj, *a):
        self.deleted.append(('obj', self.handles.get(obj, obj))); return 1
    def api_HeapFree(self, heap, flags, p, *a):
        self.freed.append(p); return 1

    # ---- modules: a fake ddrawwq.dll ----------------------------------
    # env['ddrawwq']: None (absent) or the set of export names it provides.
    def api_LoadLibraryA(self, name, *a):
        n = self.rstr(name).lower()
        self.log.append(('LoadLibraryA', n))
        if n == 'ddrawwq.dll' and self.env.get('ddrawwq') is not None:
            return FAKE_DDRAWWQ
        return 0

    def api_GetProcAddress(self, h, name, *a):
        n = self.rstr(name)
        if h == FAKE_DDRAWWQ and n in (self.env.get('ddrawwq') or ()):
            return self.fn_stub(n)
        handles = self.env.get('module_handles') or {}
        if n == 'glDebugMessageInsertARB' and h and h == handles.get('opengl32'):
            return self.fn_stub(n)
        return 0

    def api_FreeLibrary(self, h, *a):
        self.log.append(('FreeLibrary', h)); return 1

    def api_wined3d_mutex_lock(self, *a):
        self.log.append(('wined3d_mutex_lock',)); return 0
    def api_wined3d_mutex_unlock(self, *a):
        self.log.append(('wined3d_mutex_unlock',)); return 0

    def api_wined3d_passthru(self, p, *a):
        v = self.r32(p) if p else None
        self.log.append(('passthru_flag', None if v is None else int(v != 0)))
        return int(bool(v))

    # ---- files: env['files'] = {name: bytes}, relative to the current dir
    def _file(self, name):
        files = self.env.get('files') or {}
        return files.get(self.rstr(name).lower())

    def api_fopen(self, name, mode, *a):
        data = self._file(name)
        if data is None:
            return 0
        h = 0x6f000000 + len(self.open_files) * 0x10 if hasattr(self, 'open_files') else 0x6f000000
        if not hasattr(self, 'open_files'): self.open_files = {}
        h = 0x6f000000 + len(self.open_files) * 0x10
        self.open_files[h] = [data, 0]
        return h

    def api_fgets(self, buf, n, f, *a):
        data, pos = self.open_files[f]
        if pos >= len(data):
            return 0
        out = b''
        while pos < len(data) and len(out) < n - 1:
            c = data[pos:pos + 1]; pos += 1; out += c
            if c == b'\n':
                break
        self.open_files[f][1] = pos
        self.uc.mem_write(buf, out + b'\0')
        return buf

    def api_fclose(self, f, *a):
        self.open_files.pop(f, None); return 0

    def api_CreateFileA(self, name, access, share, sa, disp, flags, tmpl, *a):
        data = self._file(name)
        if data is None:
            return 0xffffffff
        if not hasattr(self, 'open_files'): self.open_files = {}
        h = 0x6f000000 + len(self.open_files) * 0x10
        self.open_files[h] = [data, 0]
        return h

    def api_ReadFile(self, h, buf, n, pread, ov, *a):
        data, pos = self.open_files[h]
        chunk = data[pos:pos + n]
        self.open_files[h][1] = pos + len(chunk)
        self.uc.mem_write(buf, chunk)
        if pread: self.w32(pread, len(chunk))
        return 1

    def api_CloseHandle(self, h, *a):
        if hasattr(self, 'open_files'): self.open_files.pop(h, None)
        return 1

    def api_strtoul(self, s, end, base, *a):
        t = self.rstr(s, 256).lstrip(' \t')
        if base == 16 and t[:2].lower() == '0x': t = t[2:]
        m = re.match(r'[0-9a-fA-F]*' if base == 16 else r'[0-9]*', t)
        return int(m.group(0), base) & 0xffffffff if m.group(0) else 0

    def _format(self, fmt, argp):
        out = ''; i = 0
        while i < len(fmt):
            c = fmt[i]
            if c != '%':
                out += c; i += 1; continue
            m = re.match(r'%(0?)(\d*)(l?)([sdxuXc%])', fmt[i:])
            if not m:
                out += c; i += 1; continue
            zero, width, _, conv = m.groups(); i += m.end()
            if conv == '%':
                out += '%'; continue
            v = self.r32(argp); argp += 4
            if conv == 's': t = self.rstr(v) if v else '(null)'
            elif conv == 'd': t = str(v - (1 << 32) if v & 0x80000000 else v)
            elif conv == 'u': t = str(v)
            elif conv == 'x': t = '%x' % v
            elif conv == 'X': t = '%X' % v
            else: t = chr(v & 0xff)
            if width: t = t.rjust(int(width), '0' if zero else ' ')
            out += t
        return out

    def api__vsnprintf(self, buf, n, fmt, va, *a):
        t = self._format(self.rstr(fmt), va).encode('latin-1')
        if len(t) >= n:
            self.uc.mem_write(buf, t[:n]); return 0xffffffff
        self.uc.mem_write(buf, t + b'\0'); return len(t)

    def api_wsprintfA(self, buf, fmt, *a):
        esp = self.uc.reg_read(UC_X86_REG_ESP)
        t = self._format(self.rstr(fmt), esp + 12).encode('latin-1')[:1023]
        self.uc.mem_write(buf, t + b'\0'); return len(t)
