#!/usr/bin/env python3
"""Summarise a multiplier sweep (logs written by mul_sweep.sh) and compare with the cycle model.
   python3 mul_sweep_report.py <dir with <cfg>_<prog>.log>

Model (validated on your measurements): the baseline and scalar_opt kernels execute 6116 multiplies (one `mulw` per MAC), so
   cycles(cfg) = cycles(iter) - (5 - stall_mulw(cfg)) * 6116       and the Xai kernels (no multiplies) do not change."""
import os, re, sys

CFG = [("iter", 5, "original iterative 16 b/cycle"), ("mulw_short", 3, "iterative, mulw in 2 chunks"),
       ("lat3", 3, "latency model, 3 stalls"), ("lat1", 1, "latency model, 1 stall"),
       ("mulw_fast", 0, "32x32 low-half mulw in EX"), ("comb", 0, "64x64 combinational in EX")]
PROGS = ["bench_baseline", "bench_opt", "bench_ai"]
MULS = 256 + 4096 + 1764
CYC = [2, 4, 6, 8, 10]; MISM = [12, 13, 14, 15, 16]

def load(path):
    m = {}
    if not os.path.exists(path): return None
    for line in open(path, errors="replace"):
        g = re.search(r"MBOX\[(\d+)\]\s*=\s*(\d+)", line)
        if g: m[int(g.group(1))] = int(g.group(2))
        g = re.search(r"status code\s*=\s*(\d+)", line)
        if g: m["status"] = int(g.group(1))
    return m

def total(m):
    return sum(m.get(c, 0) for c in CYC) if m and all(c in m for c in CYC) else None

def main():
    d = sys.argv[1] if len(sys.argv) > 1 else "mulsweep"
    data = {(c, p): load(os.path.join(d, "%s_%s.log" % (c, p))) for c, _, _ in CFG for p in PROGS}
    ref = {p: total(data[("iter", p)]) for p in PROGS}
    print("%-12s %-30s %6s | %9s %9s %9s | %8s %8s | model check (opt / base)" % ("config", "meaning", "stall", "baseline", "scalar_opt", "xai", "xai/opt", "xai/base"))
    for c, s, desc in CFG:
        t = {p: total(data[(c, p)]) for p in PROGS}
        warn = [p for p in PROGS if data[(c, p)] is None or total(data[(c, p)]) is None]
        wrong = [p for p in PROGS if data[(c, p)] and (data[(c, p)].get("status", 0) or any(data[(c, p)].get(i, 0) for i in MISM))]
        cell = lambda p: ("%9d" % t[p]) if t[p] is not None else "%9s" % "n/a"
        ratio = lambda a, b: ("%7.2fx" % (t[a] / t[b])) if t[a] and t[b] else "%8s" % "n/a"
        chk = ""
        if ref["bench_opt"] and ref["bench_baseline"] and t["bench_opt"] and t["bench_baseline"]:
            pred = lambda p: ref[p] - (5 - s) * MULS
            chk = "%+d / %+d" % (t["bench_opt"] - pred("bench_opt"), t["bench_baseline"] - pred("bench_baseline"))
        print("%-12s %-30s %6d | %s %s %s | %s %s | %s" % (c, desc, s, cell("bench_baseline"), cell("bench_opt"), cell("bench_ai"),
              ratio("bench_opt", "bench_ai"), ratio("bench_baseline", "bench_ai"), chk))
        if warn: print("   WARNING: missing/incomplete logs for", warn)
        if wrong: print("   WARNING: WRONG RESULTS in", wrong, "- timings invalid")
    print("\n'model check' = measured - predicted cycles (0 means the cycle model is exact). xai/opt is the number to report.")

if __name__ == "__main__":
    main()