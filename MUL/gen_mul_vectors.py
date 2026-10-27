#!/usr/bin/env python3
"""Write mul_vectors.txt for mul_unit_tb.sv.   Line: kind(0=mul,1=div) op(hex) a(16 hex) b(16 hex) expected(16 hex)
Usage: gen_mul_vectors.py [outdir]"""
import os, random, sys
from mul_model import *

random.seed(5)
CORNER = [0, 1, M64, (1 << 63), (1 << 63) - 1, 2, 0xFFFFFFFE, M32, 0x80000000, 0x7FFFFFFF, 0xFFFFFFFF80000000,
          0x7FFFFFFF00000000, 0x100000000, 0xFF, 0xFFFFFFFFFFFFFF80, 0x7F, 3, 0xDEADBEEF]
def rnd():
    r = random.random()
    if r < 0.30: return random.choice(CORNER)
    if r < 0.50: return random.randint(-128, 127) & M64                      # int8 sign-extended (the AI workload)
    if r < 0.60: return random.randint(-(1 << 31), (1 << 31) - 1) & M64      # int32 sign-extended
    return random.getrandbits(64)

vecs = []
for a in CORNER:
    for b in CORNER:
        for i, op in enumerate(MULOPS): vecs.append((0, i, a, b, mul(op, a, b)))
for _ in range(3000):
    a, b = rnd(), rnd(); i = random.randrange(5)
    vecs.append((0, i, a, b, mul(MULOPS[i], a, b)))
for a in CORNER[:10]:
    for b in CORNER[:10]:
        for i, op in enumerate(DIVOPS): vecs.append((1, i, a, b, div(op, a, b)))
for _ in range(300):
    a, b = rnd(), rnd(); i = random.randrange(8)
    vecs.append((1, i, a, b, div(DIVOPS[i], a, b)))
random.shuffle(vecs)
out = sys.argv[1] if len(sys.argv) > 1 else '.'
os.makedirs(out, exist_ok=True)
with open(os.path.join(out, 'mul_vectors.txt'), 'w') as f:
    for k, i, a, b, e in vecs: f.write("%02x %02x %016x %016x %016x\n" % (k, i, a, b, e))
print(len(vecs), "vectors (%d mul, %d div) written to %s" % (sum(1 for v in vecs if v[0] == 0), sum(1 for v in vecs if v[0] == 1), os.path.join(out, 'mul_vectors.txt')))