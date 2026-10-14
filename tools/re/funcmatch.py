#!/usr/bin/env python3
"""funcmatch.py <reference.dll> <named.dll> 0xVA [0xVA ...]

Name functions of a stripped reference DLL by matching them against a build
that still has its COFF symbol table (e.g. /build/wined3d.dll from the
Docker image, before patch_pe_win98.py).  Each function is reduced to a
fingerprint — imported functions it calls, exported functions it calls,
distinctive immediate constants, size class — and candidates are ranked by
weighted Jaccard similarity.  Works across nearby Wine versions because
these features are stable under recompilation.
"""
import sys, re, subprocess, importlib.util, os, struct
from collections import Counter
here = os.path.dirname(os.path.abspath(__file__))
def load(n, f):
    s = importlib.util.spec_from_file_location(n, os.path.join(here, '..', f))
    m = importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
wu = load('wu', 'win98-universe.py'); cd = load('cd', 'win98-calldiff.py')

def disasm(path):
    src = cd.sanitized_copy(path)
    out = subprocess.run([cd.OBJDUMP, '-d', '--no-show-raw-insn', src], capture_output=True, text=True).stdout
    if src != path: os.unlink(src)
    lines = []
    for l in out.splitlines():
        m = re.match(r'^\s*([0-9a-f]+):\s+(.*)$', l)
        if m: lines.append((int(m.group(1), 16), m.group(2).rstrip()))
    return lines

def exports_of(pe):
    ex = {}
    if pe.dirs and pe.dirs[0][0]:
        eo = pe.off(pe.dirs[0][0])
        (_, _, _, _, _, _, nf, nn, af, an, ao) = struct.unpack_from('<IIHHIIIIIII', pe.d, eo)
        for i in range(nn):
            ex[pe.imagebase + pe.u32(af + 4 * pe.u16(ao + 2 * i))] = pe.cstr(pe.u32(an + 4 * i))
    return ex

class Image:
    def __init__(self, path, symbols=False):
        self.pe = wu.PE(path); self.iat = cd.iat_map(self.pe); self.ex = exports_of(self.pe)
        self.lines = disasm(path)
        self.idx = {a: i for i, (a, _) in enumerate(self.lines)}
        self.thunks = {}
        for a, t in self.lines:
            m = re.match(r'jmp\s+\*0x([0-9a-f]+)', t)
            if m and int(m.group(1), 16) in self.iat: self.thunks[a] = self.iat[int(m.group(1), 16)]
        self.syms = {}
        if symbols:
            nm = subprocess.run(['i686-w64-mingw32-nm', path], capture_output=True, text=True).stdout
            for l in nm.splitlines():
                p = l.split()
                if len(p) == 3 and p[1] in 'tT':
                    self.syms[int(p[0], 16)] = p[2].lstrip('_').split('@')[0]
            self.starts = sorted(a for a in self.syms if a in self.idx)

    def ranges(self):
        for k, a in enumerate(self.starts):
            e = self.starts[k + 1] if k + 1 < len(self.starts) else a + 0x4000
            yield self.syms[a], a, e

    def call_targets(self):
        if not hasattr(self, '_targets'):
            t = set()
            for a, ins in self.lines:
                m = re.match(r'call\s+([0-9a-f]+)', ins)
                if m: t.add(int(m.group(1), 16))
            t |= set(self.ex)
            self._targets = sorted(x for x in t if x in self.idx)
        return self._targets

    def bounds_guess(self, va):
        """reference: function = span between the call targets around va"""
        import bisect
        t = self.call_targets()
        k = bisect.bisect_right(t, va) - 1
        if k >= 0 and k + 1 < len(t):
            return t[k], t[k + 1]
        return self.bounds_prologue(va)

    def bounds_prologue(self, va):
        """fallback: walk back to a prologue, forward to the matching end"""
        i = self.idx.get(va)
        if i is None:
            i = min(self.idx, key=lambda a: abs(a - va)); i = self.idx[i]
        s = i
        while s > 0:
            t = self.lines[s][1]
            if (t.startswith('push   %ebp') and self.lines[s + 1][1].startswith('mov    %esp,%ebp')) or \
               t.startswith('lea    0x4(%esp),%ecx'):
                break
            s -= 1
        e = i
        while e + 1 < len(self.lines):
            t = self.lines[e + 1][1]
            if (t.startswith('push   %ebp') and e + 2 < len(self.lines) and
                    self.lines[e + 2][1].startswith('mov    %esp,%ebp') and
                    self.lines[e][1].startswith(('ret', 'nop', 'lea    0x0', 'xchg', 'jmp'))) or \
               (t.startswith('lea    0x4(%esp),%ecx') and self.lines[e][1].startswith(('ret', 'nop', 'jmp'))):
                break
            e += 1
        return self.lines[s][0], self.lines[e][0] + 1

    def fingerprint(self, start, end):
        f = Counter()
        n = 0
        i = self.idx.get(start)
        if i is None: return f, 0
        while i < len(self.lines) and self.lines[i][0] < end:
            t = self.lines[i][1]; n += 1
            m = re.search(r'\*0x([0-9a-f]+)', t)
            if m and int(m.group(1), 16) in self.iat:
                f['I:' + self.iat[int(m.group(1), 16)].split('!')[1]] += 1
            m = re.match(r'(?:call|jmp)\s+([0-9a-f]+)', t)
            if m:
                a = int(m.group(1), 16)
                if a in self.thunks: f['I:' + self.thunks[a].split('!')[1]] += 1
                elif a in self.ex: f['E:' + self.ex[a]] += 1
                else: f['call'] += 1
            for c in re.findall(r'\$0x([0-9a-f]+)', t):
                v = int(c, 16)
                if 0x10 <= v < 0x10000000 and v not in (0xff, 0xffff):
                    f['K:%x' % v] += 1
            for c in re.findall(r'0x([0-9a-f]{2,4})\(%e[a-z]{2}\)', t):     # struct offsets
                f['O:' + c] += 1
            i += 1
        return f, n

def sim(a, b, na, nb):
    keys = set(a) | set(b)
    w = lambda k: 4.0 if k[0] in 'IE' else 2.0 if k[0] == 'K' else 0.5 if k[0] == 'O' else 0.2
    inter = sum(w(k) * min(a[k], b[k]) for k in keys)
    union = sum(w(k) * max(a[k], b[k]) for k in keys)
    size = min(na, nb) / max(na, nb, 1)
    return (inter / union if union else 0) * (0.5 + 0.5 * size)

def main():
    ref = Image(sys.argv[1]); named = Image(sys.argv[2], symbols=True)
    cands = [(name, a, named.fingerprint(a, e)) for name, a, e in named.ranges()]
    for v in sys.argv[3:]:
        va = int(v, 16)
        s, e = ref.bounds_guess(va)
        fp, n = ref.fingerprint(s, e)
        scored = sorted(((sim(fp, f, n, m), name) for name, a, (f, m) in cands), reverse=True)[:4]
        print('%x (func %x-%x, %d insns): %s' % (va, s, e, n,
              '  '.join('%s %.2f' % (nm, sc) for sc, nm in scored)))

if __name__ == '__main__':
    main()
