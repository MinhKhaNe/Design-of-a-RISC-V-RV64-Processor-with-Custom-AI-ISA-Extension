#!/usr/bin/env python3
"""Adds the pipelined Xai mode (AI_LAT = 3) to YOUR rv64imafc_top.sv by anchored text edits.

  python3 apply_ai_lat3_patch.py <rtl_dir> [--dry-run]

What changes in the core (nothing changes for AI_LAT = 1 or 2: AI_PIPE is a constant 0 there and the logic disappears):
  * an Xai instruction in EX is treated like a load by the hazard unit (one bubble only when the NEXT instruction uses its rd);
  * exmem_is_ai marks the instruction in MEM; its result (ai_unit.result, finished from the stage register) is written
    to memwb_alu_result instead of exmem_alu_result;
  * ex_result no longer contains ai_result when AI_LAT = 3 (that is what shortens the EX stage).

Prerequisite: ai_unit.sv in <rtl_dir> must be the new version (step8_pipe/rtl/ai_unit.sv, contains AI_LAT = 3).
Select the mode as before:  +define+AI_LAT_VAL=3  (if you ran enable_ai_lat_macro.py)  or edit  localparam int AI_LAT = 3;

All-or-nothing, a backup <file>.pre_lat3 is written, already-patched files are skipped (safe to run twice)."""
import os, re, shutil, sys

def edit(text, pattern, repl, what, flags=0):
    n = len(re.findall(pattern, text, flags))
    if n != 1:
        sys.exit("ANCHOR PROBLEM (%s): pattern found %d times, expected 1.\n  pattern: %s" % (what, n, pattern))
    return re.sub(pattern, repl, text, count=1, flags=flags)

def patch_top(t):
    # 1. declarations
    t = edit(t, r"(\n[ \t]*logic[ \t]+ai_req,[ \t]*ai_busy;[ \t]*\n)",
             lambda m: m.group(1) +
             "  logic           ai_pipe_ex;          // AI_LAT=3: the Xai instruction in EX behaves like a load for hazard detection\n"
             "  logic           exmem_is_ai;         // AI_LAT=3: the instruction in MEM is an Xai instruction (result finished in MEM)\n",
             "top: declarations")
    # 2. hazard unit: Xai in EX counts like a load
    t = edit(t, r"\.idex_mem_read\s*\(\s*idex_mem_read\s*&&\s*idex_valid\s*\)",
             lambda m: ".idex_mem_read ((idex_mem_read || ai_pipe_ex) && idex_valid)", "top: hazard unit")
    # 3. AI_PIPE constant right after the AI_LAT localparam (works for the plain and the `AI_LAT_VAL macro form)
    t = edit(t, r"(\n[ \t]*localparam[ \t]+int[ \t]+AI_LAT[ \t]*=[^;\n]+;[^\n]*\n)",
             lambda m: m.group(1) +
             "  localparam bit AI_PIPE = (AI_LAT == 3);     // 3 = pipelined EX/MEM, no stall; result finished in MEM (like a load)\n"
             "  assign ai_pipe_ex = AI_PIPE && idex_is_ai;\n",
             "top: AI_LAT localparam")
    # 4. EX result: not for AI_LAT = 3
    t = edit(t, r"assign ex_result\s*=\s*idex_is_ai\s*\?\s*ai_result\s*:",
             lambda m: "assign ex_result = (idex_is_ai && !AI_PIPE)    ? ai_result  :", "top: ex_result")
    # 5. EX/MEM register: reset, ex_busy bubble, normal capture
    t = edit(t, r"(exmem_is_sc\s*<=\s*1'b0;)(\s*end else if \(ex_busy\) begin)",
             lambda m: m.group(1) + "\n      exmem_is_ai         <= 1'b0;" + m.group(2), "top: exmem reset")
    t = edit(t, r"(exmem_is_sc\s*<=\s*1'b0;)(\s*end else begin)",
             lambda m: m.group(1) + "\n      exmem_is_ai        <= 1'b0;" + m.group(2), "top: exmem bubble")
    t = edit(t, r"(exmem_is_sc\s*<=\s*idex_is_sc\s*&&\s*idex_valid\s*&&\s*!ex_illegal;)",
             lambda m: m.group(1) + "\n      exmem_is_ai         <= AI_PIPE && idex_is_ai && idex_valid && !ex_illegal;", "top: exmem capture")
    # 6. MEM/WB register
    t = edit(t, r"memwb_alu_result\s*<=\s*exmem_alu_result;",
             lambda m: "memwb_alu_result <= exmem_is_ai ? ai_result : exmem_alu_result;   // AI_LAT=3: Xai result is finished in MEM",
             "top: memwb")
    return t

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry = "--dry-run" in sys.argv
    if len(args) != 1: sys.exit(__doc__)
    d = args[0]
    top = os.path.join(d, "rv64imafc_top.sv")
    unit = os.path.join(d, "ai_unit.sv")
    for p in (top, unit):
        if not os.path.isfile(p): sys.exit("missing file: %s" % p)
    if "g_lat3" not in open(unit).read():
        print("WARNING: %s is the OLD ai_unit (no AI_LAT = 3). Copy step8_pipe/rtl/ai_unit.sv over it before simulating." % unit)
    t = open(top).read()
    if "AI_PIPE" in t:
        print("skip (already patched):", top); return
    if "ai_unit_inst" not in t: sys.exit("%s does not contain the Xai unit: run step4_ai/patch/apply_ai_patch.py first" % top)
    new = patch_top(t)
    if dry:
        print("dry run OK: all anchors found; would modify", top); return
    shutil.copyfile(top, top + ".pre_lat3")
    open(top, "w").write(new)
    print("patched:", top, "(backup: %s.pre_lat3)" % os.path.basename(top))

if __name__ == "__main__":
    main()
