#!/usr/bin/env python3
"""Compare benchmark runs from their simulator logs.

  python3 compare.py base.log [opt.log] [ai.log] [--names base,opt,ai]

Each log is the text printed by tb_baremetal.sv (lines like  "#   MBOX[4] = 59501  (0x...)").
 * the FIRST log is the reference; every later log gets a speedup column against it
 * with 3+ logs, the LAST one is also compared with the one before it (e.g. Xai vs the optimised scalar code)
 * prints cycles, instret, stall cycles per unit, CPI, cycles/MAC, and the Amdahl bound of the reference run

Mailbox layout (bench_baseline.c / bench_opt.c / bench_ai.c):
  [2..11] (cycles, instret) of dot, gemm, conv3x3, requant, maxpool     [12..16] mismatches     [17],[18] overhead
"""
import re, sys, os

KERNELS = [("dot", 2, 256, "MAC"), ("gemm", 4, 4096, "MAC"), ("conv3x3", 6, 1764, "MAC"),
           ("requant", 8, 196, "elem"), ("maxpool", 10, 49, "out")]

def load(path):
    m = {}
    for line in open(path, errors="replace"):
        g = re.search(r"MBOX\[(\d+)\]\s*=\s*(\d+)", line)
        if g: m[int(g.group(1))] = int(g.group(2))
        g = re.search(r"status code\s*=\s*(\d+)", line)
        if g: m["status"] = int(g.group(1))
    return m

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    names = None
    for a in sys.argv[1:]:
        if a.startswith("--names="): names = a.split("=", 1)[1].split(",")
    if "--names" in sys.argv:
        names = sys.argv[sys.argv.index("--names") + 1].split(","); args = [a for a in args if a != sys.argv[sys.argv.index("--names") + 1]]
    if not args: sys.exit(__doc__)
    names = names or [os.path.splitext(os.path.basename(a))[0] for a in args]
    runs = [load(a) for a in args]

    for n, r in zip(names, runs):
        bad = [(k, r.get(s, 0)) for k, s in zip([k[0] for k in KERNELS], range(12, 17)) if r.get(s, 0)]
        if any(c not in r for _, c, _, _ in KERNELS): print("WARNING: %s: some cycle slots missing (run incomplete?)" % n)
        if bad or r.get("status", 0): print("WARNING: %s computed WRONG results %s (status %s) -- its timings are not valid" % (n, bad, r.get("status")))

    W = max(10, max(len(n) for n in names) + 2)
    print("\ncycles (overhead already subtracted)")
    print("%-9s" % "kernel" + "".join("%*s" % (W, n) for n in names) + "".join("%*s" % (W + 4, "x vs " + names[0]) for _ in names[1:]) + ("%*s" % (W + 8, "x %s vs %s" % (names[-1], names[-2])) if len(names) >= 3 else ""))
    tot = [0] * len(runs)
    for k, c, units, un in KERNELS:
        cyc = [r.get(c, 0) for r in runs]
        for i, v in enumerate(cyc): tot[i] += v
        row = "%-9s" % k + "".join("%*d" % (W, v) for v in cyc)
        row += "".join("%*.2f" % (W + 4, cyc[0] / v if v else 0) for v in cyc[1:])
        if len(runs) >= 3: row += "%*.2f" % (W + 8, cyc[-2] / cyc[-1] if cyc[-1] else 0)
        print(row)
    row = "%-9s" % "TOTAL" + "".join("%*d" % (W, v) for v in tot) + "".join("%*.2f" % (W + 4, tot[0] / v if v else 0) for v in tot[1:])
    if len(runs) >= 3: row += "%*.2f" % (W + 8, tot[-2] / tot[-1] if tot[-1] else 0)
    print(row)

    print("\ncycles per unit (MAC / element / output) and CPI")
    print("%-9s" % "kernel" + "".join("%*s" % (W + 6, n + " c/u") for n in names) + "".join("%*s" % (W + 2, n + " CPI") for n in names))
    for k, c, units, un in KERNELS:
        print("%-9s" % k + "".join("%*.2f" % (W + 6, r.get(c, 0) / units) for r in runs) +
              "".join("%*.2f" % (W + 2, (r.get(c, 0) / r.get(c + 1, 1)) if r.get(c + 1) else 0) for r in runs))

    print("\nretired instructions, and stall cycles per unit (= (cycles - instructions) / units: mul waits, taken-branch flushes, load-use, AI waits)")
    print("%-9s" % "kernel" + "".join("%*s" % (W + 4, n + " instr") for n in names) + "".join("%*s" % (W + 4, n + " stall/u") for n in names))
    for k, c, units, un in KERNELS:
        print("%-9s" % k + "".join("%*d" % (W + 4, r.get(c + 1, 0)) for r in runs) +
              "".join("%*.2f" % (W + 4, (r.get(c, 0) - r.get(c + 1, 0)) / units) for r in runs))

    ref = runs[0]
    mac = sum(ref.get(c, 0) for k, c, _, _ in KERNELS if k in ("dot", "gemm", "conv3x3"))
    oth = sum(ref.get(c, 0) for k, c, _, _ in KERNELS if k not in ("dot", "gemm", "conv3x3"))
    if mac + oth:
        print("\nAmdahl, reference run '%s': multiply-accumulate kernels = %.1f%% of kernel time, requant+pool = %.1f%%"
              % (names[0], 100.0 * mac / (mac + oth), 100.0 * oth / (mac + oth)))
        print("  -> even if the MAC kernels cost nothing, the whole chain is limited to %.1fx unless requant/pool also speed up"
              % ((mac + oth) / max(oth, 1)))

if __name__ == "__main__":
    main()