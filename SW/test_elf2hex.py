"""Self-test: build a tiny synthetic ELF64 (text at 0, data at RAM_BASE, a symtab with _trap)
and check what elf2hex.py writes."""
import os, struct, subprocess, sys, tempfile

RAM = 0x10000
text = bytes([0x13, 0x00, 0x00, 0x00,  0x6f, 0x00, 0x00, 0x00,  0x01, 0x00])   # nop; jal x0,0; c.nop
data = bytes(range(0xA0, 0xA0 + 11))

def build():
    strtab = b'\0_trap\0'
    symtab = struct.pack('<IBBHQQ', 0, 0, 0, 0, 0, 0) + struct.pack('<IBBHQQ', 1, 0x10, 0, 1, 0x8, 0)
    shstr = b'\0.symtab\0.strtab\0.shstrtab\0'
    off = 64 + 2 * 56
    t_off = off; d_off = t_off + len(text); sym_off = d_off + len(data)
    str_off = sym_off + len(symtab); shs_off = str_off + len(strtab)
    sh_off = shs_off + len(shstr)
    ehdr = b'\x7fELF' + bytes([2, 1, 1, 0]) + bytes(8) + struct.pack('<HHIQQQIHHHHHH',
            2, 243, 1, 0, 64, sh_off, 0, 64, 56, 2, 64, 4, 3)
    ph = struct.pack('<IIQQQQQQ', 1, 5, t_off, 0, 0, len(text), len(text), 4) + \
         struct.pack('<IIQQQQQQ', 1, 6, d_off, RAM, RAM, len(data), len(data) + 64, 8)
    def sh(name, typ, flags, addr, o, size, link, info, align, ent):
        return struct.pack('<IIQQQQIIQQ', name, typ, flags, addr, o, size, link, info, align, ent)
    sections = sh(0, 0, 0, 0, 0, 0, 0, 0, 0, 0) + \
               sh(1, 2, 0, 0, sym_off, len(symtab), 2, 1, 8, 24) + \
               sh(9, 3, 0, 0, str_off, len(strtab), 0, 0, 1, 0) + \
               sh(17, 3, 0, 0, shs_off, len(shstr), 0, 0, 1, 0)
    return ehdr + ph + text + data + symtab + strtab + shstr + sections

with tempfile.TemporaryDirectory() as t:
    elf = os.path.join(t, 'x.elf'); open(elf, 'wb').write(build())
    here = os.path.dirname(os.path.abspath(__file__))
    subprocess.check_call([sys.executable, os.path.join(here, 'elf2hex.py'), elf, '--ram-base', hex(RAM),
                           '--imem-bytes', '65536', '--dmem-bytes', '65536', '-o', t])
    imem = open(os.path.join(t, 'imem.hex')).read().split()
    dmem = open(os.path.join(t, 'dmem.hex')).read().split()
    assert imem == ['0013', '0000', '006f', '0000', '0001'], imem
    assert dmem == ['%02x' % b for b in data], dmem
    par = open(os.path.join(t, 'prog_params.svh')).read()
    assert "TRAP_PC = 64'h8;" in par and 'IMEM_BYTES = 65536' in par, par
print("elf2hex self-test PASS")