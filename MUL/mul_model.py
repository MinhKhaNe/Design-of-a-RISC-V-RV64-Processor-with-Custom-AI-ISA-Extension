"""Golden model of the RV64M multiply / divide instructions (the specification mul_unit_tb.sv checks against)."""
M64 = (1 << 64) - 1
M32 = (1 << 32) - 1
MULOPS = ['mul', 'mulh', 'mulhsu', 'mulhu', 'mulw']                       # encodings 0..4 (mul_op_e)
DIVOPS = ['div', 'divu', 'rem', 'remu', 'divw', 'divuw', 'remw', 'remuw']  # encodings 0..7 (div_op_e)

def s64(x): x &= M64; return x - (1 << 64) if x >> 63 else x
def s32(x): x &= M32; return x - (1 << 32) if x >> 31 else x
def sext32(x): return s32(x) & M64

def mul(op, a, b):
    if op == 'mul':    return (a * b) & M64
    if op == 'mulh':   return ((s64(a) * s64(b)) >> 64) & M64
    if op == 'mulhsu': return ((s64(a) * b) >> 64) & M64
    if op == 'mulhu':  return ((a * b) >> 64) & M64
    if op == 'mulw':   return sext32((a & M32) * (b & M32))
    raise ValueError(op)

def tdiv(x, y):                      # division truncating toward zero
    q = abs(x) // abs(y)
    return -q if (x < 0) != (y < 0) else q

def div(op, a, b):
    if op in ('div', 'rem'):
        x, y = s64(a), s64(b)
        if y == 0:                        return M64 if op == 'div' else a
        if x == -(1 << 63) and y == -1:   return a if op == 'div' else 0
        q = tdiv(x, y)
        return q & M64 if op == 'div' else (x - q * y) & M64
    if op in ('divu', 'remu'):
        if b == 0: return M64 if op == 'divu' else a
        return (a // b) if op == 'divu' else (a % b)
    if op in ('divw', 'remw'):
        x, y = s32(a), s32(b)
        if y == 0:                        return M64 if op == 'divw' else sext32(x)
        if x == -(1 << 31) and y == -1:   return sext32(x) if op == 'divw' else 0
        q = tdiv(x, y)
        return sext32(q) if op == 'divw' else sext32(x - q * y)
    if op in ('divuw', 'remuw'):
        x, y = a & M32, b & M32
        if y == 0: return M64 if op == 'divuw' else sext32(x)
        return sext32(x // y) if op == 'divuw' else sext32(x % y)
    raise ValueError(op)