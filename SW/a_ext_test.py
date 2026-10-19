"""Directed test for the A extension.
Builds a program (instruction words -> prog.hex, one byte per line, little endian),
runs it through an independent reference interpreter implementing the A-extension
semantics, and writes the expected architectural state for rv64imcfa_tb.sv:
    expected_regs.hex  : x0..x31 (64-bit hex per line)
    expected_mem.hex   : bytes of data memory 0x100..0x11f
    prog_params.svh    : END_PC (also used as TRAP_PC for the misaligned test)
    imem.hex           : program as 16-bit parcels (one per line) for imem.sv's IMEM_INIT
"""
M64 = (1 << 64) - 1
def sx(v, b): v &= (1 << b) - 1; return v - (1 << b) if v >> (b - 1) else v

F5 = dict(add=0b00000, swap=0b00001, lr=0b00010, sc=0b00011, xor=0b00100, or_=0b01000,
          and_=0b01100, min=0b10000, max=0b10100, minu=0b11000, maxu=0b11100)

prog = []                                    # (mnemonic, args...)
def addi(rd, rs1, imm): prog.append(('addi', rd, rs1, imm))
def lui(rd, imm20):     prog.append(('lui', rd, imm20))
def add(rd, a, b):      prog.append(('add', rd, a, b))
def sw(rs2, rs1, imm):  prog.append(('sw', rs2, rs1, imm))
def sd(rs2, rs1, imm):  prog.append(('sd', rs2, rs1, imm))
def lw(rd, rs1, imm):   prog.append(('lw', rd, rs1, imm))
def ld(rd, rs1, imm):   prog.append(('ld', rd, rs1, imm))
def amo(op, w, rd, rs2, rs1): prog.append(('amo', op, w, rd, rs2, rs1))   # w: 'w' or 'd'
def fence():            prog.append(('fence',))

# ------------------------------------------------------------------ program
addi(1, 0, 0x100)               # x1 = base
addi(13, 1, 8)                  # x13 = base+8
addi(2, 0, 5)
sw(2, 1, 0)                     # mem[0x100] = 5
addi(3, 0, 7)
amo('add', 'w', 4, 3, 1)        # x4 = 5, mem = 12
lw(5, 1, 0)                     # x5 = 12
add(6, 4, 5)                    # x6 = 17   (load-use after lw)
amo('swap', 'w', 7, 2, 1)       # x7 = 12, mem = 5
amo('swap', 'w', 8, 3, 1)       # x8 = 5,  mem = 7   (back-to-back AMOs, same address)
add(9, 8, 8)                    # x9 = 10  (consumer right after AMO -> stall)
lui(10, 0x80000)                # x10 = 0xFFFFFFFF80000000
sw(10, 13, 0)                   # mem[0x108] = 0x80000000
addi(11, 0, 1)
amo('min',  'w', 12, 11, 13)    # signed:   min(-2^31, 1) -> stays; x12 = sext(0x80000000)
amo('minu', 'w', 14, 11, 13)    # unsigned: min(0x80000000, 1) -> 1; x14 = sext(0x80000000)
amo('max',  'w', 15, 10, 13)    # signed:   max(1, -2^31) -> 1; x15 = 1
amo('maxu', 'w', 16, 10, 13)    # unsigned: max(1, 0x80000000) -> 0x80000000; x16 = 1
amo('xor',  'w', 17, 11, 13)    # x17 = sext(0x80000000), mem = 0x80000001
amo('or_',  'w', 18, 2, 13)     # x18 = sext(0x80000001), mem = 0x80000005
amo('and_', 'w', 19, 3, 13)     # x19 = sext(0x80000005), mem = 0x00000005
sd(10, 1, 16)                   # mem[0x110] (64-bit) = 0xFFFFFFFF80000000
addi(29, 1, 16)                 # x29 = 0x110
amo('add', 'd', 20, 11, 29)     # 64-bit: x20 = 0xFFFFFFFF80000000, mem = 0xFFFFFFFF80000001
amo('maxu', 'd', 21, 0, 29)     # x21 = 0xFFFFFFFF80000001, mem unchanged (max with 0)
amo('add', 'w', 0, 3, 1)        # rd = x0: must not change x0; mem[0x100] += 7 -> 14
fence()
# ---- LR / SC
amo('lr', 'w', 22, 0, 1)        # x22 = 14, reservation on 0x100
addi(23, 22, 1)                 # x23 = 15
amo('sc', 'w', 24, 23, 1)       # success: x24 = 0, mem[0x100] = 15
amo('sc', 'w', 25, 3, 1)        # no reservation: x25 = 1, mem unchanged
amo('lr', 'd', 26, 0, 13)       # reservation on 0x108 (x26 = 5)
sw(0, 13, 0)                    # store to reserved granule clears reservation
amo('sc', 'd', 27, 3, 13)       # fails: x27 = 1
amo('lr', 'w', 28, 0, 1)        # reserve 0x100 (x28 = 15)
amo('sc', 'w', 30, 3, 13)       # different granule: x30 = 1, mem[0x108] unchanged (0)
lw(31, 1, 0)                    # x31 = 15
# ---- misaligned atomic -> TRAP_PC (= END)
addi(12, 1, 2)                  # x12 = 0x102 (misaligned for .W)
amo('add', 'w', 14, 3, 12)      # trap: x14 must keep its earlier value, memory untouched
END = len(prog)                 # index of the final self-loop

# ------------------------------------------------------------------ encode
def enc(i, ins):
    k = ins[0]
    if k == 'addi': _, rd, rs1, imm = ins; return ((imm & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x13
    if k == 'lui':  _, rd, imm = ins;      return ((imm & 0xFFFFF) << 12) | (rd << 7) | 0x37
    if k == 'add':  _, rd, a, b = ins;     return (b << 20) | (a << 15) | (rd << 7) | 0x33
    if k in ('sw', 'sd'):
        _, rs2, rs1, imm = ins; f3 = 2 if k == 'sw' else 3
        return (((imm >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 0x1F) << 7) | 0x23
    if k in ('lw', 'ld'):
        _, rd, rs1, imm = ins; f3 = 2 if k == 'lw' else 3
        return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x03
    if k == 'amo':
        _, op, w, rd, rs2, rs1 = ins
        return (F5[op] << 27) | (rs2 << 20) | (rs1 << 15) | ((2 if w == 'w' else 3) << 12) | (rd << 7) | 0x2F
    if k == 'fence': return 0x0FF0000F
    raise ValueError(k)

words = [enc(i, p) for i, p in enumerate(prog)] + [0x0000006F]       # jal x0, 0
# ------------------------------------------------------------------ reference interpreter
regs = [0] * 32
mem = {}
resv = None
def rd_mem(a, n): return sum(mem.get(a + i, 0) << (8 * i) for i in range(n))
def wr_mem(a, n, v):
    for i in range(n): mem[a + i] = (v >> (8 * i)) & 0xFF
def setr(r, v):
    if r: regs[r] = v & M64

for ins in prog:
    k = ins[0]
    if k == 'addi': setr(ins[1], regs[ins[2]] + ins[3])
    elif k == 'lui': setr(ins[1], sx(ins[2] << 12, 32))
    elif k == 'add': setr(ins[1], regs[ins[2]] + regs[ins[3]])
    elif k == 'sw' or k == 'sd':
        n = 4 if k == 'sw' else 8; a = (regs[ins[2]] + ins[3]) & M64
        wr_mem(a, n, regs[ins[1]])
        if resv is not None and (a >> 3) == resv: resv = None
    elif k == 'lw': setr(ins[1], sx(rd_mem((regs[ins[2]] + ins[3]) & M64, 4), 32))
    elif k == 'ld': setr(ins[1], rd_mem((regs[ins[2]] + ins[3]) & M64, 8))
    elif k == 'fence': pass
    elif k == 'amo':
        _, op, w, rd, rs2, rs1 = ins
        n = 4 if w == 'w' else 8; bits = 8 * n
        a = regs[rs1]
        if a % n:                                   # misaligned -> trap to END, no side effects
            resv = None; break
        old = sx(rd_mem(a, n), bits) if w == 'w' else rd_mem(a, n)
        src = sx(regs[rs2], bits) if w == 'w' else regs[rs2]
        if op == 'lr':
            setr(rd, old); resv = a >> 3
        elif op == 'sc':
            if resv == (a >> 3): wr_mem(a, n, regs[rs2]); setr(rd, 0)
            else: setr(rd, 1)
            resv = None
        else:
            so, ss = sx(old, 64), sx(src, 64); uo, us = old & M64, src & M64
            new = dict(swap=src, add=old + src, xor=old ^ src, or_=old | src, and_=old & src,
                       min=old if so < ss else src, max=old if so > ss else src,
                       minu=old if uo < us else src, maxu=old if uo > us else src)[op]
            wr_mem(a, n, new)
            setr(rd, old)
            if resv is not None and (a >> 3) == resv: resv = None

# ------------------------------------------------------------------ emit
with open('prog.hex', 'w') as f:
    for w_ in words:
        for b in range(4): f.write('%02x\n' % ((w_ >> (8 * b)) & 0xFF))
with open('imem.hex', 'w') as f:
    for w_ in words:
        f.write('%04x\n' % (w_ & 0xFFFF))
        f.write('%04x\n' % (w_ >> 16))
with open('expected_regs.hex', 'w') as f:
    for r in regs: f.write('%016x\n' % r)
with open('expected_mem.hex', 'w') as f:
    for a in range(0x100, 0x120): f.write('%02x\n' % mem.get(a, 0))
with open('prog_params.svh', 'w') as f:
    f.write("localparam logic [63:0] END_PC = 64'h%x;\n" % (4 * END))
print(len(words), "instructions, END_PC = 0x%x" % (4 * END))
for r in (4,5,6,7,8,9,12,14,15,16,17,18,19,20,21,22,24,25,26,27,28,30,31):
    print("x%-2d = %016x" % (r, regs[r]))
print("mem[0x100] =", hex(rd_mem(0x100, 4)), " mem[0x108] =", hex(rd_mem(0x108, 4)), " mem[0x110] =", hex(rd_mem(0x110, 8)))
