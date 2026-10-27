#!/usr/bin/env python3
"""Core-level directed test of the Xai instructions.
Writes (into the output dir, default '.'):
   imem.hex         program as 16-bit parcels   (IMEM_INIT)
   dmem.hex         initial data, 1 byte/line   (DMEM_INIT)
   expected_regs.hex  x0..x31 (64-bit hex per line)
   expected_mem.hex   bytes 0x100..0x13f of data memory after the run
An independent interpreter (ai_model.py semantics) computes the expected state.
Hazard cases covered: AI result consumed by the next instruction, AI->AI forwarding, load->AI (load-use),
AI->store, rd=x0, AI chains with the result of an earlier AI instruction as operand.
Added for the pipelined unit (AI_LAT=3, the result is finished in MEM like a load): consumer at distance 1, 2, 3 and 4 after
an AI instruction, a younger instruction writing the same rd (WAW), AI result stored by the very next instruction, AI result
compared by the very next branch (taken / not taken, with an AI instruction squashed behind a taken branch), AI results next to a
multi-cycle `mul`, AI->AI->AI chains, load-use into an AI instruction.  Every test uses DIFFERENT operands (a stale or wrongly
forwarded value can not coincide with the right one) and writes its observations to memory (0x140..0x2ff), so later tests can not
mask an earlier error.  Memory window compared by the testbench: 0x100..0x2ff.
"""
import os, sys
from ai_model import *

def le64(*bytes_): return sum((b & 0xFF) << (8 * i) for i, b in enumerate(bytes_))
def i32pair(lo, hi): return (lo & 0xFFFFFFFF) | ((hi & 0xFFFFFFFF) << 32)

DATA = {                                   # addr -> 64-bit little-endian word
    0x100: le64(-128, 127, -1, 0, 1, 2, -3, 50),              # A8
    0x108: le64(-128, -128, 127, 127, -1, 5, -7, 3),          # B8
    0x110: i32pair(8000, -8000),                              # Q1 (two int32)
    0x118: i32pair(0x7FFFFFFF, 0x80000000),                   # Q2
    0x120: le64(1, 2, 3, 4, 5, 6, 7, 8),                      # C8
}

prog = []
def addi(rd, rs1, imm):        prog.append(('addi', rd, rs1, imm))
def add(rd, a, b):             prog.append(('add', rd, a, b))
def ld(rd, rs1, imm):          prog.append(('ld', rd, rs1, imm))
def sd(rs2, rs1, imm):         prog.append(('sd', rs2, rs1, imm))
def ai(op, rd, rs1, rs2, sh=0): prog.append(('ai', op, rd, rs1, rs2, sh))
def mul(rd, a, b):             prog.append(('mul', rd, a, b))
def beq(a, b):                 prog.append(('beq', a, b))       # forward branch over the NEXT instruction (offset +8)
def bne(a, b):                 prog.append(('bne', a, b))

addi(1, 0, 0x100)
ld(2, 1, 0)                       # x2 = A8
ld(3, 1, 8)                       # x3 = B8
ai('dot8', 4, 2, 3)
add(5, 4, 4)                      # consumes the AI result immediately
ai('dot8', 6, 3, 2)
ai('dot8', 7, 6, 3)               # operand = result of the previous AI instruction
ld(8, 1, 16)                      # x8 = Q1
ld(9, 1, 24)                      # x9 = Q2
ai('qrelu', 10, 8, 9, 5)
ai('qrelu', 11, 8, 9, 0)
ai('qrelu', 12, 8, 9, 31)
ai('qrelu', 13, 9, 8, 7)          # swapped operands
ai('max8', 14, 2, 3)
ld(15, 1, 32)                     # x15 = C8
ai('dot8', 16, 15, 2)             # load-use straight into an AI instruction
sd(4, 1, 40)
ld(17, 1, 40)
add(18, 16, 17)
ai('max8', 19, 2, 0)              # ReLU on bytes (max with zero)
ai('dot8', 0, 2, 3)               # rd = x0 must stay zero
add(20, 0, 4)
ai('max8', 21, 14, 15)            # chain: previous AI result and a loaded value
ai('qrelu', 22, 21, 10, 2)        # chain again
sd(22, 1, 48)

# ---------------- pipelined-unit hazards ----------------
# sources never overwritten below: x2 A8, x3 B8, x8 Q1, x14 max8(A8,B8), x15 C8, x21 chain result; base x1
OBS = []
def obs(r):                                       # observe register r: store it to its own memory slot
    sd(r, 1, 0x40 + 8 * len(OBS)); OBS.append(r)
for r in (4, 5, 6, 7, 9, 10, 11, 12, 13, 16, 17, 18, 19, 20, 22):        # keep the results of the first part (they are overwritten below)
    obs(r)

ai('dot8', 23, 2, 15);   add(24, 23, 3);                                  obs(24)          # consumer at distance 1
ai('dot8', 25, 3, 15);   addi(26, 0, 7);  add(27, 25, 26);                obs(27)          # distance 2
ai('max8', 28, 8, 2);    addi(29, 0, 1);  addi(29, 29, 1);  add(30, 28, 29);  obs(30)      # distance 3 (register-file write/read in the same cycle)
ai('qrelu', 31, 3, 15, 3); addi(5, 0, 5); addi(5, 5, 5);  addi(5, 5, 5);  add(6, 31, 5);   obs(6)     # distance 4
ai('dot8', 7, 14, 15);   addi(7, 0, 99);  add(9, 7, 3);                   obs(7); obs(9)   # WAW: the younger addi must win
ai('dot8', 10, 21, 3);   sd(10, 1, 56);   ld(11, 1, 56);                 obs(10); obs(11) # AI -> store (adjacent), then store -> load
ai('dot8', 12, 2, 2);    beq(12, 12);     addi(13, 0, 111); addi(16, 0, 222);  obs(13); obs(16)   # AI -> taken branch (adjacent); skipped addi
beq(0, 0);               ai('dot8', 17, 8, 3);                            obs(17)          # AI instruction squashed behind a taken branch
ai('dot8', 18, 15, 3);   bne(18, 0);      addi(19, 0, 333);               obs(18); obs(19) # AI -> bne (adjacent)
ai('dot8', 20, 2, 15);   mul(22, 20, 20); add(4, 22, 20);                 obs(22); obs(4)  # AI -> mul (multi-cycle EX) -> add
ai('dot8', 5, 3, 21);    mul(6, 2, 3);    add(9, 5, 6);                   obs(9)           # AI, independent mul, then the consumer
ai('max8', 10, 2, 8);    ai('dot8', 10, 10, 15);  ai('qrelu', 10, 10, 10, 4);  obs(10)    # AI -> AI -> AI chain on one register
ai('dot8', 11, 2, 3);    ai('dot8', 12, 3, 8);    add(13, 11, 12);        obs(13)          # consumers at distance 2 (first) and 1 (second)
ld(16, 1, 0);            ai('dot8', 17, 16, 3);   add(18, 17, 16);        obs(18)          # load-use into an AI instruction, AI -> add
ai('dot8', 20, 15, 8);   add(19, 3, 20);                                  obs(19)          # AI result as rs2 of the consumer
assert len(OBS) <= 63, "too many observation slots"
END = len(prog)

def enc(ins):
    k = ins[0]
    if k == 'addi': _, rd, rs1, imm = ins; return ((imm & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x13
    if k == 'add':  _, rd, a, b = ins;     return (b << 20) | (a << 15) | (rd << 7) | 0x33
    if k == 'ld':   _, rd, rs1, imm = ins; return ((imm & 0xFFF) << 20) | (rs1 << 15) | (3 << 12) | (rd << 7) | 0x03
    if k == 'sd':
        _, rs2, rs1, imm = ins
        return (((imm >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | (3 << 12) | ((imm & 0x1F) << 7) | 0x23
    if k == 'ai':   _, op, rd, rs1, rs2, sh = ins; return encode(op, rd, rs1, rs2, sh)
    if k == 'mul':  _, rd, a, b = ins;     return (1 << 25) | (b << 20) | (a << 15) | (rd << 7) | 0x33
    if k in ('beq', 'bne'):
        _, a, b = ins;                     return (b << 20) | (a << 15) | ((0 if k == 'beq' else 1) << 12) | (4 << 8) | 0x63     # offset +8
    raise ValueError(k)

words = [enc(p) for p in prog] + [0x0000006F]                    # jal x0, 0

# ---------------- reference interpreter ----------------
regs = [0] * 32
mem = {}
for a_, w in DATA.items():
    for i in range(8): mem[a_ + i] = (w >> (8 * i)) & 0xFF
def rd64(a): return sum(mem.get(a + i, 0) << (8 * i) for i in range(8))
def wr64(a, v):
    for i in range(8): mem[a + i] = (v >> (8 * i)) & 0xFF
def setr(r, v):
    if r: regs[r] = v & M64
pc_i = 0
while pc_i < len(prog):
    ins = prog[pc_i]; pc_i += 1
    k = ins[0]
    if k == 'mul': setr(ins[1], regs[ins[2]] * regs[ins[3]])
    elif k in ('beq', 'bne'):
        if (regs[ins[1]] == regs[ins[2]]) == (k == 'beq'): pc_i += 1       # taken: the next instruction is skipped
    elif k == 'addi': setr(ins[1], regs[ins[2]] + ins[3])
    elif k == 'add': setr(ins[1], regs[ins[2]] + regs[ins[3]])
    elif k == 'ld': setr(ins[1], rd64((regs[ins[2]] + ins[3]) & M64))
    elif k == 'sd': wr64((regs[ins[2]] + ins[3]) & M64, regs[ins[1]])
    elif k == 'ai': _, op, rd, rs1, rs2, sh = ins; setr(rd, execute(op, regs[rs1], regs[rs2], sh))

out = sys.argv[1] if len(sys.argv) > 1 else '.'
os.makedirs(out, exist_ok=True)
with open(os.path.join(out, 'imem.hex'), 'w') as f:
    for w_ in words:
        f.write('%04x\n%04x\n' % (w_ & 0xFFFF, w_ >> 16))
with open(os.path.join(out, 'dmem.hex'), 'w') as f:
    for a_ in range(0, 0x300): f.write('%02x\n' % (DATA.get(a_ & ~7, 0) >> (8 * (a_ & 7)) & 0xFF))
with open(os.path.join(out, 'expected_regs.hex'), 'w') as f:
    for r in regs: f.write('%016x\n' % r)
with open(os.path.join(out, 'expected_mem.hex'), 'w') as f:
    for a_ in range(0x100, 0x300): f.write('%02x\n' % mem.get(a_, 0))
print(len(words), "instructions")
for r in (4, 5, 6, 7, 10, 11, 12, 13, 14, 16, 17, 18, 19, 20, 21, 22):
    print("x%-2d = %016x" % (r, regs[r]))
# every observed value of the hazard part should be different from the others (so a stale / wrongly forwarded value is detectable)
seen = {}
for k, r in enumerate(OBS[15:], 15):
    v = rd64(0x100 + 0x40 + 8 * k)
    seen.setdefault(v, []).append(r)
dups = {v: rs for v, rs in seen.items() if len(rs) > 1}
print("hazard observations: %d slots, %d distinct values%s" % (len(OBS) - 15, len(seen), ("  (equal values: %s)" % ", ".join("%x:x%s" % (v, rs) for v, rs in dups.items())) if dups else ""))
