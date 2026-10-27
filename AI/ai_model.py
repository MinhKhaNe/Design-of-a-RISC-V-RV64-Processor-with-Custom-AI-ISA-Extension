"""Golden model of the Xai custom-0 instructions (the specification the RTL and the C emulation must match).

  dot8  rd, rs1, rs2        funct3=000, funct7=0
        rd = sum_{i<8} s8(rs1.byte[i]) * s8(rs2.byte[i])          (exact, sign-extended to 64 bits)
  qrelu rd, rs1, rs2, SH    funct3=001, funct7[4:0]=SH (0..31), funct7[6:5]=0
        4 int32 inputs  {rs1[31:0], rs1[63:32], rs2[31:0], rs2[63:32]}  ->  rd.byte[0..3]  (rd[63:32] = 0)
        byte = clamp( floor((v + (SH ? 2^(SH-1) : 0)) / 2^SH), 0, 127 )      (round-half-up, ReLU, saturate)
  max8  rd, rs1, rs2        funct3=010, funct7=0
        rd.byte[i] = max_signed(rs1.byte[i], rs2.byte[i])  for i<8
"""
M64 = (1 << 64) - 1
OPC_CUSTOM0 = 0x0B
F3 = dict(dot8=0, qrelu=1, max8=2)

def s8(x):  x &= 0xFF;       return x - 256 if x & 0x80 else x
def s32(x): x &= 0xFFFFFFFF; return x - (1 << 32) if x & 0x80000000 else x

def dot8(a, b):
    return sum(s8(a >> (8 * i)) * s8(b >> (8 * i)) for i in range(8)) & M64

def qrelu(a, b, sh):
    assert 0 <= sh < 32
    out = 0
    for l, v in enumerate((a & 0xFFFFFFFF, (a >> 32) & 0xFFFFFFFF, b & 0xFFFFFFFF, (b >> 32) & 0xFFFFFFFF)):
        r = (s32(v) + ((1 << (sh - 1)) if sh else 0)) >> sh          # Python >> on ints is an arithmetic (floor) shift
        out |= max(0, min(127, r)) << (8 * l)
    return out

def max8(a, b):
    out = 0
    for i in range(8):
        out |= (max(s8(a >> (8 * i)), s8(b >> (8 * i))) & 0xFF) << (8 * i)
    return out

def execute(op, a, b, sh=0):
    return {'dot8': lambda: dot8(a, b), 'qrelu': lambda: qrelu(a, b, sh), 'max8': lambda: max8(a, b)}[op]()

def encode(op, rd, rs1, rs2, sh=0):
    f7 = sh if op == 'qrelu' else 0
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (F3[op] << 12) | (rd << 7) | OPC_CUSTOM0