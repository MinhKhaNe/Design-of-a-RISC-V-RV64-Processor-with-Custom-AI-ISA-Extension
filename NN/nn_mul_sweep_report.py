#!/usr/bin/env python3
"""Summarise the multiplier sweep over nn_bench (logs written by nn_mul_sweep.sh) and compare with the cycle model.
   python3 nn_mul_sweep_report.py <dir with <cfg>.log>  [--mac8-saving 0.226]

Mailbox (see nn_compare.py): [2..7] scalar cycles per layer, [8..13] Xai cycles per layer, [14..17] whole inference
(cycles, instret) scalar / Xai, [18],[19] logit mismatches, [20] correct, [21] images.

Model: every scalar MAC is one `mulw`, 21664 per inference; the Xai path executes no multiply, so
   scalar(cfg) = scalar(iter) - (5 - stall(cfg)) * 21664        Xai(cfg) = Xai(iter)
A non-zero 'model check' means the cycle model is not exact (e.g. extra multiplies hidden in address arithmetic)."""
import os, re, sys

CFG = [("iter", 5, "original iterative 16 b/cycle"), ("mulw_short", 3, "iterative, mulw in 2 chunks"),
       ("lat3", 3, "latency model, 3 stalls"), ("lat1", 1, "latency model, 1 stall"),
       ("mulw_fast", 0, "32x32 low-half mulw in EX"), ("comb", 0, "64x64 combinational in EX")]
MULS = 2592 + 18432 + 640
LAYER = [("conv1", [0]), ("conv2", [2]), ("fc", [5]), ("requant", [1, 3]), ("pool", [4])]

def load(path):
    if not os.path.exists(path): return None
    m = {}
    for line in open(path, errors="replace"):
        g = re.search(r"MBOX\[(\d+)\]\s*=\s*(\d+)", line)
        if g: m[int(g.group(1))] = int(g.group(2))
        g = re.search(r"status code\s*=\s*(\d+)", line)
        if g: m["status"] = int(g.group(1))
    return m if all(k in m for k in (14, 15, 16, 17)) else None

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    saving = 0.226
    if "--mac8-saving" in sys.argv: saving = float(sys.argv[sys.argv.index("--mac8-saving") + 1])
    d = args[0] if args else "nn_mulsweep"
    data = {c: load(os.path.join(d, c + ".log")) for c, _, _ in CFG}
    ref = data["iter"]
    print("whole inference of image 0 (cycles, measured)\n")
    print("%-11s %-30s %5s | %9s %9s %8s | %7s %7s | model check (scalar / xai)" % ("config", "meaning", "stall", "scalar", "xai", "speedup", "CPI sc", "CPI xai"))
    for c, s, desc in CFG:
        m = data[c]
        if m is None: print("%-11s %-30s %5d | missing or incomplete log" % (c, desc, s)); continue
        bad = m.get(18, 0) or m.get(19, 0) or m.get("status", 0)
        chk = ""
        if ref: chk = "%+d / %+d" % (m[14] - (ref[14] - (5 - s) * MULS), m[16] - ref[16])
        print("%-11s %-30s %5d | %9d %9d %7.2fx | %7.2f %7.2f | %s%s" % (c, desc, s, m[14], m[16], m[14] / m[16], m[14] / m[15], m[16] / m[17], chk,
              "   WRONG RESULTS - timing invalid" if bad else ""))
    print("\nspeedup per layer (scalar cycles / Xai cycles)\n")
    print("%-11s " % "config" + " ".join("%9s" % n for n, _ in LAYER))
    for c, s, desc in CFG:
        m = data[c]
        if m is None or not all(k in m for k in range(2, 14)): continue
        print("%-11s " % c + " ".join("%8.2fx" % (sum(m[2 + i] for i in ix) / sum(m[8 + i] for i in ix)) for _, ix in LAYER))
    if ref:
        print("\nESTIMATE (not measured): if a 3-operand mac8 removes %.1f%% of the Xai cycles (accumulate adds, from the instruction mix)," % (100 * saving))
        print("the speedup would become:")
        for c, s, desc in CFG:
            m = data[c]
            if m: print("  %-11s %6.2fx  (now %.2fx)" % (c, m[14] / (m[16] * (1 - saving)), m[14] / m[16]))
    print("\n'model check' = measured - predicted cycles (0 means the model is exact).  The 'speedup' column is the number to report;")
    print("it is a CYCLE ratio: convert to time with the synthesised clock of each configuration (a faster multiplier may cost Fmax).")

if __name__ == "__main__":
    main()