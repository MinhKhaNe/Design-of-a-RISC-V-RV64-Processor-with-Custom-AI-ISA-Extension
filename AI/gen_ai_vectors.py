#!/usr/bin/env python3
"""Unit-level vectors for ai_unit: writes <dir>/ai_vectors.txt, one vector per line:
   op(hex) sh(hex) a(hex64) b(hex64) expected(hex64)     op: 0=dot8 1=qrelu 2=max8"""
import os, sys, random
from ai_model import *

random.seed(12345)
out = sys.argv[1] if len(sys.argv) > 1 else '.'
os.makedirs(out, exist_ok=True)
OPN = {'dot8': 0, 'qrelu': 1, 'max8': 2}
vec = []

def add(op, a, b, sh=0):
    a &= M64; b &= M64
    sh = sh if op == 'qrelu' else 0
    vec.append((OPN[op], sh, a, b, execute(op, a, b, sh)))

def rep(byte): return int.from_bytes(bytes([byte]) * 8, 'little')

EB  = [0x80, 0x7f, 0x00, 0xff, 0x01, 0x02, 0x81, 0x7e]
I32 = [0x80000000, 0x7fffffff, 0, 1, 0xffffffff, 0x7f, 0x80, 0x100, 0x3f, 0x40, 0xffffff80]

# directed: edge bytes, replicated
for x in EB:
    for y in EB:
        for op in ('dot8', 'max8'):
            add(op, rep(x), rep(y))
# directed: edge bytes in random lanes
for _ in range(1500):
    a = int.from_bytes(bytes(random.choice(EB) for _ in range(8)), 'little')
    b = int.from_bytes(bytes(random.choice(EB) for _ in range(8)), 'little')
    for op in ('dot8', 'max8'):
        add(op, a, b)
# directed qrelu: edge int32 in every lane, every shift
for sh in range(32):
    for _ in range(60):
        w = [random.choice(I32) for _ in range(4)]
        add('qrelu', w[0] | (w[1] << 32), w[2] | (w[3] << 32), sh)
    # random values around the clamp boundaries for this shift
    for _ in range(60):
        w = [random.randint(-(1 << min(31, sh + 8)), (1 << min(31, sh + 8)) - 1) & 0xFFFFFFFF for _ in range(4)]
        add('qrelu', w[0] | (w[1] << 32), w[2] | (w[3] << 32), sh)
# fully random
for _ in range(3000):
    for op in ('dot8', 'max8'):
        add(op, random.getrandbits(64), random.getrandbits(64))
for _ in range(1500):
    add('qrelu', random.getrandbits(64), random.getrandbits(64), random.randrange(32))

random.shuffle(vec)
with open(os.path.join(out, 'ai_vectors.txt'), 'w') as f:
    for op, sh, a, b, e in vec:
        f.write(f"{op:x} {sh:x} {a:016x} {b:016x} {e:016x}\n")
print(f"{len(vec)} vectors -> {os.path.join(out, 'ai_vectors.txt')}")
