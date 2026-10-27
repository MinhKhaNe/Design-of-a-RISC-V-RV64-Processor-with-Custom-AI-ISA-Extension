#!/usr/bin/env python3
"""Annotate a RISC-V objdump listing for the Xai core and flag load-use pairs.

   python3 dis_check.py <prog.dis> <function-name-part> [--all]

 * finds the function whose symbol CONTAINS the name (GCC adds suffixes such as .constprop.0 / .isra.0);
 * decodes the custom-0 words that objdump cannot name (dot8 / qrelu / max8) from the raw machine code;
 * marks '<-- LOAD-USE' where an instruction needs the register loaded by the instruction right before it
   (on this core that costs one stall cycle) and '<-- loop back' on backward branches;
 * prints counts so you can judge the inner loop without reading every line.
Make the listing with:  make bm_dis PROG=<prog>     (it is SW_build/<prog>/<prog>.dis)
It is a STATIC check: it shows whether the pattern exists in the code, not how often it executes."""
import re, sys

ABI = "zero ra sp gp tp t0 t1 t2 s0 s1 a0 a1 a2 a3 a4 a5 a6 a7 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 t3 t4 t5 t6".split()
REG = re.compile(r"\b(zero|ra|sp|gp|tp|fp|t[0-6]|s(?:1[01]|[0-9])|a[0-7])\b")
LOADS = {"lb", "lbu", "lh", "lhu", "lw", "lwu", "ld", "lwsp", "ldsp"}
STORES = {"sb", "sh", "sw", "sd", "swsp", "sdsp"}
BRANCH = {"beq", "bne", "blt", "bge", "bltu", "bgeu", "beqz", "bnez"}
RMW = {"add", "addi", "addiw", "addw", "sub", "subw", "and", "or", "xor", "slli", "srli", "srai", "andi"}   # c.* forms: rd is also a source
CUSTOM = {0: "dot8", 1: "qrelu", 2: "max8"}

def decode_custom(word):
    if word & 0x7F != 0x0B: return None
    f3 = (word >> 12) & 7
    if f3 not in CUSTOM: return None
    rd, rs1, rs2, f7 = (word >> 7) & 31, (word >> 15) & 31, (word >> 20) & 31, word >> 25
    ops = "%s,%s,%s" % (ABI[rd], ABI[rs1], ABI[rs2]) + (",%d" % (f7 & 31) if f3 == 1 else "")
    return CUSTOM[f3], ops

def regs_of(ops):
    return ["s0" if r == "fp" else r for r in REG.findall(ops)]

def analyse(mn, ops, custom):
    regs = regs_of(ops)
    base = mn[2:] if mn.startswith("c.") else mn
    if custom:                       return (regs[0], regs[1:3])
    if base in LOADS:                return (regs[0] if regs else None, regs[1:])
    if base in STORES or base in BRANCH: return (None, regs)
    if base in ("lui", "auipc", "li") or base == "jal" or base == "j": return (regs[0] if regs and base not in ("j",) else None, [])
    if base in ("jalr", "jr"):       return (regs[0] if regs and base == "jalr" else None, regs[1:] if base == "jalr" else regs)
    if mn.startswith("c.") and base in RMW: return (regs[0] if regs else None, regs)
    return (regs[0] if regs else None, regs[1:])

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 2: sys.exit(__doc__)
    path, want = args
    lines = open(path, errors="replace").read().splitlines()
    funcs, cur = [], None
    for ln in lines:
        h = re.match(r"^([0-9a-f]+) <(.+)>:\s*$", ln)
        if h: cur = [h.group(2), []]; funcs.append(cur); continue
        if cur is None: continue
        p = ln.split("\t")
        if len(p) >= 3 and re.match(r"^\s*[0-9a-f]+:\s*$", p[0]):
            cur[1].append((p[0].strip().rstrip(":"), p[1].strip(), p[2].strip(), p[3].strip() if len(p) > 3 else ""))
    hits = [f for f in funcs if want in f[0]]
    if not hits: sys.exit("no function containing '%s' in %s (try: grep '<' %s | grep -i %s)" % (want, path, path, want))
    for name, ins in hits:
        print("=" * 78 + "\nfunction <%s>  (%d instructions)\n" % (name, len(ins)) + "=" * 78)
        rows, counts, lu_pairs = [], {"load": 0, "dot8": 0, "qrelu": 0, "max8": 0, "branch": 0, "mul": 0}, 0
        prev_dest, prev_load = None, False
        for addr, hexw, mn, ops in ins:
            custom = None
            if len(hexw) == 8:
                try: custom = decode_custom(int(hexw, 16))
                except ValueError: pass
            if custom: mn, ops = custom
            dest, srcs = analyse(mn, ops, custom is not None)
            mark = ""
            if prev_load and prev_dest and prev_dest != "zero" and prev_dest in srcs:
                mark = "   <-- LOAD-USE (stalls 1 cycle)"; lu_pairs += 1
            base = mn[2:] if mn.startswith("c.") else mn
            if base in LOADS: counts["load"] += 1
            if base in CUSTOM.values(): counts[base] += 1
            if base in BRANCH or base in ("jal", "j", "jalr", "jr"): counts["branch"] += 1
            if base.startswith("mul"): counts["mul"] += 1
            tgt = re.search(r"([0-9a-f]+)\s*<", ops)
            if base in BRANCH and tgt and int(tgt.group(1), 16) <= int(addr, 16): mark += "   <-- loop back"
            rows.append("%8s  %-8s %-26s%s" % (addr + ":", mn, ops, mark))
            prev_dest, prev_load = dest, (base in LOADS)
        print("\n".join(rows))
        print("\nsummary: %d instr | loads %d | dot8 %d, qrelu %d, max8 %d | mul* %d | branches/jumps %d | LOAD-USE pairs %d"
              % (len(ins), counts["load"], counts["dot8"], counts["qrelu"], counts["max8"], counts["mul"], counts["branch"], lu_pairs))
        if len(hits) > 1 and "--all" not in sys.argv: print("(%d functions match; showing the first - use a longer name or --all)" % len(hits)); break

if __name__ == "__main__":
    main()