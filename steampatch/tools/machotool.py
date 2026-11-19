#!/usr/bin/env python3
"""machotool.py - small arm64 Mach-O analysis helper for Tessera's Steam integration.

Finds strings, the code that references them (ADRP+ADD / ADR / ADRP+LDR), the functions around those references
(LC_FUNCTION_STARTS), callers of a function (BL), and prints annotated disassembly (capstone).

Usage:
  machotool.py BIN strings  PATTERN           list C strings containing PATTERN (case-sensitive)
  machotool.py BIN xrefs    TEXT [--exact]    functions that reference a string containing TEXT
  machotool.py BIN dis      ADDR [N]          disassemble the function containing ADDR (N instructions max)
  machotool.py BIN callers  FUNCADDR          functions that BL to FUNCADDR
  machotool.py BIN calls    FUNCADDR          functions called (BL) from FUNCADDR, with their string refs
BIN must be a thin arm64 Mach-O (lipo -thin arm64).
"""
import bisect
import struct
import sys

LC_SEGMENT_64 = 0x19
LC_FUNCTION_STARTS = 0x26
LC_SYMTAB = 0x2


class MachO:
    def __init__(self, path):
        self.data = open(path, 'rb').read()
        magic, cpu, sub, ftype, ncmds, sizecmds, flags, _ = struct.unpack_from('<IiiIIIII', self.data, 0)
        if magic != 0xFEEDFACF:
            raise SystemExit('not a thin 64-bit Mach-O (use lipo -thin arm64)')
        self.sections = []          # (segname, sectname, addr, size, offset)
        self.segments = []          # (segname, vmaddr, vmsize, fileoff, filesize)
        self.func_starts = []
        self.symbols = {}           # addr -> name (defined symbols only)
        off = 32
        fs_cmd = None
        for _ in range(ncmds):
            cmd, size = struct.unpack_from('<II', self.data, off)
            if cmd == LC_SEGMENT_64:
                segname = self.data[off + 8:off + 24].split(b'\0')[0].decode()
                vmaddr, vmsize, fileoff, filesize, _, _, nsects, _ = struct.unpack_from('<QQQQiiII', self.data, off + 24)
                self.segments.append((segname, vmaddr, vmsize, fileoff, filesize))
                so = off + 72
                for _ in range(nsects):
                    sect = self.data[so:so + 16].split(b'\0')[0].decode()
                    seg = self.data[so + 16:so + 32].split(b'\0')[0].decode()
                    addr, ssize, soff = struct.unpack_from('<QQI', self.data, so + 32)
                    self.sections.append((seg, sect, addr, ssize, soff))
                    so += 80
            elif cmd == LC_FUNCTION_STARTS:
                fs_cmd = struct.unpack_from('<II', self.data, off + 8)
            elif cmd == LC_SYMTAB:
                symoff, nsyms, stroff, strsize = struct.unpack_from('<IIII', self.data, off + 8)
                for i in range(nsyms):
                    strx, ntype, nsect, ndesc, value = struct.unpack_from('<IBBhQ', self.data, symoff + i * 16)
                    if nsect and value:
                        name = self.data[stroff + strx:self.data.index(b'\0', stroff + strx)].decode(errors='replace')
                        self.symbols.setdefault(value, name)
            off += size
        text_seg = next(s for s in self.segments if s[0] == '__TEXT')
        if fs_cmd:
            dataoff, datasize = fs_cmd
            addr = text_seg[1]
            i = dataoff
            end = dataoff + datasize
            while i < end:
                val = 0
                shift = 0
                while True:
                    b = self.data[i]
                    i += 1
                    val |= (b & 0x7F) << shift
                    shift += 7
                    if not b & 0x80:
                        break
                if val == 0:
                    break
                addr += val
                self.func_starts.append(addr)
        self.text = next(s for s in self.sections if s[0] == '__TEXT' and s[1] == '__text')
        self._insns = None

    # ---- address helpers
    def read(self, addr, n):
        for seg, sect, a, size, off in self.sections:
            if a <= addr < a + size and off:
                return self.data[off + (addr - a):off + (addr - a) + n]
        return None

    def cstring_at(self, addr, limit=300):
        b = self.read(addr, limit)
        if b is None:
            return None
        return b.split(b'\0')[0].decode(errors='replace')

    def section_of(self, addr):
        for seg, sect, a, size, off in self.sections:
            if a <= addr < a + size:
                return seg + ',' + sect
        return None

    def func_of(self, addr):
        i = bisect.bisect_right(self.func_starts, addr) - 1
        if i < 0:
            return None, None
        start = self.func_starts[i]
        end = self.func_starts[i + 1] if i + 1 < len(self.func_starts) else self.text[2] + self.text[3]
        return start, end

    def name(self, addr):
        return self.symbols.get(addr)

    # ---- strings
    def find_strings(self, pattern, exact=False):
        res = []
        pb = pattern.encode()
        for seg, sect, a, size, off in self.sections:
            if sect not in ('__cstring', '__const', '__oslogstring', '__objc_methname', '__ustring') or not off:
                continue
            blob = self.data[off:off + size]
            start = 0
            while True:
                i = blob.find(pb, start)
                if i < 0:
                    break
                s = blob.rfind(b'\0', 0, i) + 1
                e = blob.find(b'\0', i)
                text = blob[s:e].decode(errors='replace')
                if not exact or text == pattern:
                    res.append((a + s, text, sect))
                start = (e if e > i else i) + 1
        seen = set()
        out = []
        for r in res:
            if r[0] not in seen:
                seen.add(r[0])
                out.append(r)
        return out

    # ---- instruction scan (ADRP+ADD/LDR, ADR) building a reference index
    def refs(self):
        if self._insns is not None:
            return self._insns
        seg, sect, base, size, off = self.text
        code = self.data[off:off + size]
        words = struct.unpack('<%dI' % (size // 4), code[:size - size % 4])
        fstarts = set(self.func_starts)
        page = [None] * 32
        refs = {}       # target addr -> list of insn addrs
        bl = {}         # target func -> list of insn addrs
        for idx, w in enumerate(words):
            pc = base + idx * 4
            if pc in fstarts:
                page = [None] * 32
            if (w & 0x9F000000) == 0x90000000:          # ADRP
                imm = ((w >> 29) & 3) | (((w >> 5) & 0x7FFFF) << 2)
                if imm & (1 << 20):
                    imm -= 1 << 21
                page[w & 31] = ((pc & ~0xFFF) + (imm << 12), idx)
            elif (w & 0x9F000000) == 0x10000000:        # ADR
                imm = ((w >> 29) & 3) | (((w >> 5) & 0x7FFFF) << 2)
                if imm & (1 << 20):
                    imm -= 1 << 21
                refs.setdefault(pc + imm, []).append(pc)
            elif (w & 0xFF800000) == 0x91000000:        # ADD Xd, Xn, #imm
                rn = (w >> 5) & 31
                p = page[rn]
                if p and idx - p[1] < 64:
                    imm = (w >> 10) & 0xFFF
                    if (w >> 22) & 1:
                        imm <<= 12
                    refs.setdefault(p[0] + imm, []).append(pc)
            elif (w & 0xFFC00000) == 0xF9400000:        # LDR Xt, [Xn, #imm*8]
                rn = (w >> 5) & 31
                p = page[rn]
                if p and idx - p[1] < 64:
                    refs.setdefault(p[0] + ((w >> 10) & 0xFFF) * 8, []).append(pc)
            elif (w & 0xFC000000) == 0x94000000:        # BL
                imm = w & 0x3FFFFFF
                if imm & (1 << 25):
                    imm -= 1 << 26
                bl.setdefault(pc + imm * 4, []).append(pc)
        self._insns = (refs, bl)
        return self._insns

    def xrefs_to(self, addr):
        refs, _ = self.refs()
        return refs.get(addr, [])

    def callers(self, faddr):
        _, bl = self.refs()
        return bl.get(faddr, [])

    # ---- disassembly
    def disasm(self, faddr, limit=4000):
        import capstone
        start, end = self.func_of(faddr)
        if start is None:
            return []
        refs, _ = self.refs()
        rev = {}
        for t, srcs in refs.items():
            for s in srcs:
                rev[s] = t
        md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM)
        code = self.read(start, min(end - start, limit * 4))
        out = []
        for ins in md.disasm(code, start):
            note = ''
            t = rev.get(ins.address)
            if t is not None:
                s = self.cstring_at(t, 120) if self.section_of(t) and 'cstring' in self.section_of(t) else None
                note = '  ; -> 0x%x %s' % (t, ('"%s"' % s) if s else (self.section_of(t) or ''))
            if ins.mnemonic == 'bl':
                tgt = int(ins.op_str.lstrip('#'), 16)
                nm = self.name(tgt)
                note = '  ; call 0x%x %s' % (tgt, nm or '')
            out.append('%9x  %-8s %s%s' % (ins.address, ins.mnemonic, ins.op_str, note))
        return out


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return
    m = MachO(sys.argv[1])
    cmd = sys.argv[2]
    if cmd == 'strings':
        for a, t, sect in m.find_strings(sys.argv[3]):
            print('0x%x  %-12s %s' % (a, sect, t[:160]))
    elif cmd == 'xrefs':
        exact = '--exact' in sys.argv
        for a, t, sect in m.find_strings(sys.argv[3], exact):
            for x in m.xrefs_to(a):
                f, e = m.func_of(x)
                print('string 0x%x "%s"  <- insn 0x%x in func 0x%x (size %d)' % (a, t[:90], x, f or 0, (e - f) if f else 0))
    elif cmd == 'dis':
        addr = int(sys.argv[3], 16)
        n = int(sys.argv[4]) if len(sys.argv) > 4 else 4000
        for line in m.disasm(addr, n):
            print(line)
    elif cmd == 'callers':
        addr = int(sys.argv[3], 16)
        for x in m.callers(addr):
            f, e = m.func_of(x)
            print('call at 0x%x in func 0x%x' % (x, f or 0))
    elif cmd == 'calls':
        addr = int(sys.argv[3], 16)
        for line in m.disasm(addr):
            if '; call' in line or '"' in line:
                print(line)


if __name__ == '__main__':
    main()
