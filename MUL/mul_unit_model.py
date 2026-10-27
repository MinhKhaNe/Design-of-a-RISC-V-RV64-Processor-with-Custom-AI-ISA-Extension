#!/usr/bin/env python3
"""Cycle-accurate Python mirror of the MULTIPLY path + FSM of rtl/mul_div_unit.sv (the divider is not modelled).
Checks, for every configuration, (1) results against mul_model.py and (2) the number of stall cycles per multiply.
   python3 mul_unit_model.py            (no simulator needed)
It mirrors the RTL line by line, so it validates the design logic (chunk algebra, FSM paths, stall counts) but
cannot find SystemVerilog syntax / typing mistakes: those are found by mul_unit_tb.sv in your simulator."""
import random, sys
from mul_model import *

M128 = (1 << 128) - 1
IDLE, RUN, DONE = 0, 1, 2
MUL_CYCLES = 4

class Unit:
    def __init__(self, mode=0, stall=3, mulw_fast=0, mulw_short=0):
        self.mode, self.stall, self.fast, self.short = mode, stall, mulw_fast, mulw_short
        self.state, self.cyc_left = IDLE, 0
        self.op_is_mul_q = 0; self.mul_op_q = 0; self.a_q = 0; self.b_q = 0; self.mplier = 0; self.acc = 0

    @staticmethod
    def full(x, y, op):                                   # mul_full()
        sx, sy = op in (1, 2), op == 1
        mx = s64(x) if sx else x
        my = s64(y) if sy else y
        p = mx * my
        if op == 0: return p & M64
        if op == 4: return sext32(p & M32)
        return (p >> 64) & M64

    def iter_result(self):                                # mul_corrected / mul_result
        acc, op = self.acc, self.mul_op_q
        corr = acc
        if op == 1:   corr = (acc - ((self.b_q << 64) if self.a_q >> 63 else 0) - ((self.a_q << 64) if self.b_q >> 63 else 0)) & M128
        elif op == 2: corr = (acc - ((self.b_q << 64) if self.a_q >> 63 else 0)) & M128
        if op == 0: return acc & M64
        if op in (1, 2): return (corr >> 64) & M64
        if op == 3: return (acc >> 64) & M64
        return sext32(acc & M32)

    def comb(self, req, is_mul, op, a, b):
        is_mulw = op == 4
        fast_now = is_mul and (self.mode == 1 or (self.fast and is_mulw))
        req_fsm = req and not fast_now
        lat_one = is_mul and self.mode == 2 and self.stall == 1
        busy = (self.state == IDLE and req_fsm) or self.state == RUN
        if fast_now:
            res = (sext32((a & M32) * (b & M32) & M32) if (self.fast and is_mulw) else self.full(a, b, op))
        elif self.op_is_mul_q:
            res = self.full(self.a_q, self.b_q, self.mul_op_q) if self.mode == 2 else self.iter_result()
        else:
            res = 0
        return busy, res, req_fsm, lat_one

    def clock(self, req_fsm, lat_one, is_mul, op, a, b):
        n = self.state
        if self.state == IDLE:
            if req_fsm: n = DONE if lat_one else RUN
        elif self.state == RUN:
            if self.cyc_left == 0: n = DONE
        else:
            n = IDLE
        if self.state == IDLE and req_fsm:
            self.op_is_mul_q = is_mul
            if is_mul:
                self.mul_op_q, self.a_q, self.b_q, self.acc = op, a, b, 0
                if self.mode == 2:
                    self.mplier = b; self.cyc_left = (self.stall - 2) if self.stall > 1 else 0
                elif self.short and op == 4:
                    self.mplier = (b & M32) << 32; self.cyc_left = 1
                else:
                    self.mplier = b; self.cyc_left = MUL_CYCLES - 1
        elif self.state == RUN:
            if self.op_is_mul_q:
                self.acc = ((self.acc << 16) + self.a_q * ((self.mplier >> 48) & 0xFFFF)) & M128
                self.mplier = (self.mplier << 16) & M64
            if self.cyc_left != 0: self.cyc_left -= 1
        self.state = n

    def run(self, op, a, b):
        """present one multiply, return (result, stall_cycles) the way mul_unit_tb.sv measures them"""
        stall = 0
        while True:
            busy, res, req_fsm, lat_one = self.comb(1, 1, op, a, b)
            if not busy: break
            self.clock(req_fsm, lat_one, 1, op, a, b); stall += 1
            assert stall < 300, "never finished"
        self.clock(req_fsm, lat_one, 1, op, a, b)           # the cycle in which the result is consumed (DONE -> IDLE)
        return res, stall

# name: (parameters, expected stall for mulw, expected stall for the other multiplies)
CONFIGS = {
    "iter":                  (dict(mode=0),                          5, 5),
    "iter+mulw_short":       (dict(mode=0, mulw_short=1),            3, 5),
    "iter+mulw_fast":        (dict(mode=0, mulw_fast=1),             0, 5),
    "comb":                  (dict(mode=1),                          0, 0),
    "lat1":                  (dict(mode=2, stall=1),                 1, 1),
    "lat2":                  (dict(mode=2, stall=2),                 2, 2),
    "lat3":                  (dict(mode=2, stall=3),                 3, 3),
    "lat5":                  (dict(mode=2, stall=5),                 5, 5),
    "lat3+mulw_fast":        (dict(mode=2, stall=3, mulw_fast=1),    0, 3),
    "comb+mulw_fast":        (dict(mode=1, mulw_fast=1),             0, 0),
}

def vectors(n_random=3000):
    random.seed(9)
    corner = [0, 1, M64, 1 << 63, (1 << 63) - 1, 2, 0xFFFFFFFE, M32, 0x80000000, 0x7FFFFFFF, 0xFFFFFFFF80000000, 0x100000000, 0xFF, 0xFFFFFFFFFFFFFF80, 0x7F, 3]
    v = [(i, a, b) for a in corner for b in corner for i in range(5)]
    for _ in range(n_random):
        pick = lambda: random.choice(corner) if random.random() < .3 else (random.randint(-128, 127) & M64 if random.random() < .5 else random.getrandbits(64))
        v.append((random.randrange(5), pick(), pick()))
    return v

if __name__ == "__main__":
    vs = vectors()
    bad = 0
    for name, (p, ew, eo) in CONFIGS.items():
        u = Unit(**p); nres = nst = 0
        for i, a, b in vs:
            res, st = u.run(i, a, b)
            if res != mul(MULOPS[i], a, b):
                nres += 1
                if nres <= 3: print("  %s: WRONG RESULT %s a=%x b=%x got %x exp %x" % (name, MULOPS[i], a, b, res, mul(MULOPS[i], a, b)))
            if st != (ew if i == 4 else eo):
                nst += 1
                if nst <= 3: print("  %s: WRONG STALL %s: %d (expected %d)" % (name, MULOPS[i], st, ew if i == 4 else eo))
        bad += nres + nst
        print("%-18s %6d multiplies, wrong results: %d, wrong stall counts: %d  %s" % (name, len(vs), nres, nst, "ok" if nres + nst == 0 else "<-- PROBLEM"))
    print("ALL CONFIGURATIONS OK" if bad == 0 else "%d problem(s)" % bad)
    sys.exit(1 if bad else 0)