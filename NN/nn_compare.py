#!/usr/bin/env python3
"""Per-layer comparison scalar vs Xai from the log of `make bm_run PROG=nn_bench`.
   python3 nn_compare.py nn.log
Mailbox: [2..7] scalar cycles/layer, [8..13] Xai cycles/layer, [14..17] whole inference (cycles, instret) scalar / Xai,
         [18],[19] logit mismatches, [20] correct, [21] images, [22],[23] overhead."""
import re, sys

LAYERS = [("conv1 3x3 1->8", 2592, "MAC"), ("requant1", 288, "elem"), ("conv2 3x3 8->16", 18432, "MAC"),
          ("requant2", 256, "elem"), ("maxpool 2x2", 64, "out"), ("fc 64->10", 640, "MAC")]

def main():
    if len(sys.argv) != 2: sys.exit(__doc__)
    m = {}
    for line in open(sys.argv[1], errors="replace"):
        g = re.search(r"MBOX\[(\d+)\]\s*=\s*(\d+)", line)
        if g: m[int(g.group(1))] = int(g.group(2))
    need = list(range(2, 22))
    if any(k not in m for k in need if k not in (18, 19, 20)): print("WARNING: some slots missing (incomplete run?)")
    if m.get(18, 0) or m.get(19, 0): print("WARNING: logits differ from the Python reference (scalar %d, xai %d): timings are NOT valid" % (m.get(18, 0), m.get(19, 0)))
    print("%-18s %8s %8s %8s | %9s %9s" % ("layer", "scalar", "xai", "speedup", "scalar c/u", "xai c/u"))
    ts = tx = 0
    for i, (n, units, un) in enumerate(LAYERS):
        s, x = m.get(2 + i, 0), m.get(8 + i, 0); ts += s; tx += x
        print("%-18s %8d %8d %7.2fx | %9.2f %9.2f   (per %s)" % (n, s, x, s / x if x else 0, s / units, x / units, un))
    print("%-18s %8d %8d %7.2fx   (sum of the layers)" % ("layers total", ts, tx, ts / tx if tx else 0))
    print("\nwhole inference of image 0 (includes argmax):")
    for tag, c, i in (("scalar", 14, 15), ("xai", 16, 17)):
        print("  %-7s %6d cycles, %6d instructions, CPI %.2f" % (tag, m.get(c, 0), m.get(i, 0), m.get(c, 0) / m.get(i, 1)))
    if m.get(14) and m.get(16): print("  speedup %.2fx (cycle counts; convert to time only with the synthesised clock frequency)" % (m[14] / m[16]))
    if 21 in m: print("\nXai classified %d of %d embedded images correctly; logits identical to the reference: %s"
                       % (m.get(20, 0), m[21], "yes" if not (m.get(18, 0) or m.get(19, 0)) else "NO"))
    macs = 2592 + 18432 + 640
    print("MACs per inference: %d  ->  scalar %.2f, Xai %.3f cycles/MAC (whole inference, incl. requant/pool/argmax)" % (macs, m.get(14, 0) / macs, m.get(16, 0) / macs))

if __name__ == "__main__":
    main()
