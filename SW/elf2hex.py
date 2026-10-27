#!/usr/bin/env python3
"""ELF64 (little-endian RISC-V) -> hex images for the Harvard core.

  imem.hex : one 16-bit parcel per line (little-endian), loaded by imem.sv via $readmemh
  dmem.hex : one byte per line, loaded by dmem.sv via $readmemh
  prog_params.svh : IMEM_BYTES / DMEM_BYTES / TRAP_PC for the testbench

PT_LOAD segments are split by address: vaddr <  ram_base -> imem (offset = vaddr)
                                       vaddr >= ram_base -> dmem (offset = vaddr - ram_base)
No objcopy needed.
"""
import argparse, os, struct, sys

NOP16 = 0x0001           # c.nop: what imem.sv pre-fills with

def parse_elf(path):
    d = open(path, 'rb').read()
    if d[:4] != b'\x7fELF' or d[4] != 2 or d[5] != 1:
        sys.exit("%s: not a little-endian ELF64" % path)
    e_phoff, e_shoff = struct.unpack_from('<QQ', d, 0x20)
    e_phentsize, e_phnum, e_shentsize, e_shnum = struct.unpack_from('<HHHH', d, 0x36)
    segs = []
    for i in range(e_phnum):
        p_type, p_flags, p_off, p_vaddr, p_paddr, p_filesz, p_memsz, p_align = \
            struct.unpack_from('<IIQQQQQQ', d, e_phoff + i * e_phentsize)
        if p_type == 1 and p_filesz > 0:                       # PT_LOAD
            segs.append((p_vaddr, d[p_off:p_off + p_filesz]))
    syms = {}
    for i in range(e_shnum):
        (sh_name, sh_type, sh_flags, sh_addr, sh_off, sh_size, sh_link, sh_info,
         sh_align, sh_entsize) = struct.unpack_from('<IIQQQQIIQQ', d, e_shoff + i * e_shentsize)
        if sh_type == 2:                                       # SHT_SYMTAB
            st_off = struct.unpack_from('<Q', d, e_shoff + sh_link * e_shentsize + 0x18)[0]
            for k in range(sh_size // 24):
                n, info, other, shndx, val, size = struct.unpack_from('<IBBHQQ', d, sh_off + 24 * k)
                end = d.index(b'\0', st_off + n)
                syms[d[st_off + n:end].decode()] = val
    return segs, syms

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('elf')
    ap.add_argument('--ram-base', type=lambda x: int(x, 0), required=True)
    ap.add_argument('--imem-bytes', type=lambda x: int(x, 0), default=65536)
    ap.add_argument('--dmem-bytes', type=lambda x: int(x, 0), default=65536)
    ap.add_argument('-o', '--outdir', default='.')
    a = ap.parse_args()

    segs, syms = parse_elf(a.elf)
    imem = bytearray()
    dmem = bytearray()
    for vaddr, data in segs:
        if vaddr < a.ram_base:
            off, buf, size, name = vaddr, imem, a.imem_bytes, 'imem'
        else:
            off, buf, size, name = vaddr - a.ram_base, dmem, a.dmem_bytes, 'dmem'
        if off + len(data) > size:
            sys.exit("segment at 0x%x (+%d bytes) does not fit in %s (%d bytes)" % (vaddr, len(data), name, size))
        if len(buf) < off + len(data):
            n = off + len(data) - len(buf)
            buf.extend((b'\x01\x00' * ((n + 1) // 2))[:n] if name == 'imem' else b'\x00' * n)   # c.nop padding in imem
        buf[off:off + len(data)] = data

    if len(imem) % 2: imem.append(0)
    if not imem: imem = bytearray(b'\x01\x00')
    os.makedirs(a.outdir, exist_ok=True)
    with open(os.path.join(a.outdir, 'imem.hex'), 'w') as f:
        for i in range(0, len(imem), 2):
            f.write('%04x\n' % (imem[i] | (imem[i + 1] << 8)))
    with open(os.path.join(a.outdir, 'dmem.hex'), 'w') as f:
        for b in (dmem if dmem else b'\x00'):
            f.write('%02x\n' % b)
    trap = syms.get('_trap', 0)
    with open(os.path.join(a.outdir, 'prog_params.svh'), 'w') as f:
        f.write("localparam int IMEM_BYTES = %d;\n" % a.imem_bytes)
        f.write("localparam int DMEM_BYTES = %d;\n" % a.dmem_bytes)
        f.write("localparam logic [63:0] TRAP_PC = 64'h%x;\n" % trap)
    print("imem: %d bytes, dmem: %d bytes, _trap = 0x%x" % (len(imem), len(dmem), trap))

if __name__ == '__main__':
    main()