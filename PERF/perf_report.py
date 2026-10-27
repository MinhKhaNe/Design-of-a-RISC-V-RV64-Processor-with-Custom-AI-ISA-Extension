#!/usr/bin/env python3
"""Turns the PERF_SNAP / PERF_FINAL / PERF_LOOP lines printed by perf_mon.sv into cycle-accounting tables.

  python3 perf_report.py <sim log> [--labels nn|none] [--ovh N] [--csv out.csv] [--md out.md]

The software TIMED() macro of the benchmarks reads `rdcycle` before and after the measured code, so the snapshots come in
pairs: region k = snapshot[2k+1] - snapshot[2k].  With --labels nn (default when the log has the 30 snapshots of nn_bench)
the regions are named after nn_bench.c and region 0 (the empty measurement) is subtracted from every other region, exactly
as the software does.  For another program use --labels none (regions are numbered) and --ovh <k> if one region is a
pure measurement overhead.

Every table row satisfies   cycles = retired + busy + ex_empty (+ illegal-instruction cycles),   and the bubbles are
explained:                  ex_empty = hz_load + hz_ai + 2 x (flushes) + (start-up / refill, tiny)."""
import argparse, re, sys

NN_LABELS = (["overhead"] + ["scalar " + l for l in ("conv1", "requant1", "conv2", "requant2", "pool", "fc")] +
             ["xai " + l for l in ("conv1", "requant1", "conv2", "requant2", "pool", "fc")] +
             ["scalar whole", "xai whole"])

def parse(path):
    snaps, final, loops = [], None, []
    for line in open(path, errors="replace"):
        m = re.match(r"\s*(?:#\s*)?(PERF_SNAP|PERF_FINAL)\s+(.*)$", line)
        if m:
            d = {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", m.group(2))}
            (snaps.append(d) if m.group(1) == "PERF_SNAP" else None)
            if m.group(1) == "PERF_FINAL": final = d
            continue
        m = re.match(r"\s*(?:#\s*)?PERF_LOOP pc=0x([0-9a-fA-F]+) target=0x([0-9a-fA-F]+) taken=(\d+)", line)
        if m: loops.append((int(m.group(1), 16), int(m.group(2), 16), int(m.group(3))))
    return snaps, final, loops

def sub(a, b): return {k: a[k] - b.get(k, 0) for k in a}

def derived(d):
    d = dict(d)
    d["flushes"] = d["fl_br"] + d["fl_jal"] + d["fl_jalr"] + d["fl_trap"]
    d["busy"] = d["busy_mdu"] + d["busy_fpu"] + d["busy_ai"]
    d["xai"] = d["i_dot8"] + d["i_qrelu"] + d["i_max8"]
    d["other_bubbles"] = d["ex_empty"] - d["hz_load"] - d["hz_ai"] - 2 * d["flushes"]
    d["unexplained"] = d["cycles"] - d["retired"] - d["busy"] - d["ex_empty"]
    return d

def table(rows, cols, head):
    w = [max(len(h), *(len(str(r[i])) for r in rows)) for i, h in enumerate(head)]
    out = ["  ".join(h.ljust(w[i]) if i == 0 else h.rjust(w[i]) for i, h in enumerate(head))]
    out.append("  ".join("-" * x for x in w))
    for r in rows:
        out.append("  ".join(str(c).ljust(w[i]) if i == 0 else str(c).rjust(w[i]) for i, c in enumerate(r)))
    return "\n".join(out)

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log")
    ap.add_argument("--labels", choices=("nn", "none"), default=None)
    ap.add_argument("--ovh", type=int, default=None, help="index of the measurement-overhead region (default 0 for nn)")
    ap.add_argument("--csv"); ap.add_argument("--md")
    a = ap.parse_args()
    snaps, final, loops = parse(a.log)
    if not snaps: sys.exit("no PERF_SNAP lines in %s: was perf_mon run (make perf_run)?" % a.log)
    n = len(snaps) // 2
    labels_mode = a.labels or ("nn" if len(snaps) >= 2 * len(NN_LABELS) else "none")
    labels = NN_LABELS if labels_mode == "nn" else ["region %d" % k for k in range(n)]
    ovh_i = a.ovh if a.ovh is not None else (0 if labels_mode == "nn" else None)
    regs = [sub(snaps[2 * k + 1], snaps[2 * k]) for k in range(min(n, len(labels)))]
    ovh = regs[ovh_i] if ovh_i is not None else None
    reg_named = []
    for k, r in enumerate(regs):
        if ovh is not None and k == ovh_i: continue
        reg_named.append((labels[k], derived(sub(r, ovh) if ovh is not None else r)))

    out = []
    out.append("== cycle accounting per region (measurement overhead subtracted: %s)\n" % ("yes" if ovh else "no"))
    head = ["region", "cycles", "retired", "CPI", "busy", "bubbles", "hz_load", "hz_ai", "flushes", "x2", "other", "unexpl"]
    rows = [[n_, d["cycles"], d["retired"], "%.3f" % (d["cycles"] / max(d["retired"], 1)), d["busy"], d["ex_empty"], d["hz_load"], d["hz_ai"],
             d["flushes"], 2 * d["flushes"], d["other_bubbles"], d["unexplained"]] for n_, d in reg_named]
    out.append(table(rows, None, head))
    out.append("\n   busy = cycles the EX instruction is held (multiplier / FPU / AI_LAT=2);  bubbles = cycles with no instruction in EX = hz_load + hz_ai + x2 + other")
    out.append("   hz_load = load-use bubbles, hz_ai = Xai-result-use bubbles (AI_LAT=3), flushes = taken branch / jal / jalr / trap (2 bubbles each)\n")

    out.append("== instruction mix (retired instructions)\n")
    cls = [("load", "i_load"), ("store", "i_store"), ("alu_imm", "i_alu_imm"), ("alu_reg", "i_alu_reg"), ("br taken", "i_br_t"), ("br not taken", "i_br_nt"),
           ("jal", "i_jal"), ("jalr", "i_jalr"), ("mul", "i_mul"), ("csr", "i_csr"), ("dot8", "i_dot8"), ("qrelu", "i_qrelu"), ("max8", "i_max8")]
    rows = [[n_] + [d[k] for _, k in cls] for n_, d in reg_named]
    out.append(table(rows, None, ["region"] + [c for c, _ in cls]))

    # ---- what-if analysis on the two whole-inference regions (or the last region) ----
    out.append("\n== where could cycles still be removed?  (upper bounds from the counters of each region; NOT a simulation of the change)\n")
    pick = [(n_, d) for n_, d in reg_named if "whole" in n_] or reg_named[-1:]
    head = ["region", "cycles", "ai stall (LAT2)", "xai-use bubbles", "load-use", "branch/jump flush", "loop iterations", "HW loop 3/it", "HW loop 4/it", "alu_reg (mac8 bound)"]
    rows = []
    for n_, d in pick:
        cyc = d["cycles"]
        pct = lambda x: "%d (%.1f%%)" % (x, 100.0 * x / cyc)
        rows.append([n_, cyc, pct(d["busy_ai"]), pct(d["hz_ai"]), pct(d["hz_load"]), pct(2 * (d["fl_br"] + d["fl_jal"] + d["fl_jalr"])),
                     d["br_back"], pct(3 * d["br_back"]), pct(4 * d["br_back"]), pct(d["i_alu_reg"])])
    out.append(table(rows, None, head))
    out.append("\n   HW loop 3/it : a hardware loop removes, per loop iteration, the loop-closing branch (1 cycle) and its 2-cycle flush;"
               "\n   HW loop 4/it : ... plus the counter update (addi) if the compiler uses a separate counter."
               "\n   alu_reg      : register-register ALU instructions (the accumulate adds are among them): an accumulating dot8/mac8 can remove at most these.")

    if loops:
        out.append("\n== loop-closing branches executed in the whole run (pc -> target, iterations), most frequent first\n")
        rows = [["0x%x" % pc, "0x%x" % tg, c, "%d B" % (pc - tg)] for pc, tg, c in sorted(loops, key=lambda x: -x[2])[:12]]
        out.append(table(rows, None, ["branch pc", "target", "iterations", "body span"]))
    text = "\n".join(out)
    print(text)
    if a.md: open(a.md, "w").write("```\n" + text + "\n```\n")
    if a.csv:
        keys = ["cycles", "retired", "busy", "ex_empty", "hz_load", "hz_ai", "flushes", "br_back", "xai"] + [k for _, k in cls]
        with open(a.csv, "w") as f:
            f.write("region," + ",".join(keys) + "\n")
            for n_, d in reg_named: f.write(n_ + "," + ",".join(str(d[k]) for k in keys) + "\n")

if __name__ == "__main__":
    main()
