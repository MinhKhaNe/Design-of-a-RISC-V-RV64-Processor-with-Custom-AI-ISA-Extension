#!/usr/bin/env python3
"""Adds the Xai (custom-0: dot8 / qrelu / max8) extension to YOUR copies of
    rv64imafc_pkg.sv, decoder.sv, rv64imafc_top.sv
by anchored text edits, so any other changes you made (memory parameters, debug, ...) are kept.

  python3 apply_ai_patch.py <rtl_dir> [--dry-run]

 * all-or-nothing: if any anchor is missing or ambiguous nothing is written;
 * a backup <file>.pre_ai is written next to each file;
 * already-patched files are skipped, so it is safe to run twice.
After patching, add ai_unit.sv to your rtl.f (after rv64imafc_pkg.sv).
"""
import os, re, sys, shutil

def edit(text, pattern, repl, what, flags=0):
    n = len(re.findall(pattern, text, flags))
    if n != 1:
        sys.exit("ANCHOR PROBLEM (%s): pattern found %d times, expected 1.\n  pattern: %s" % (what, n, pattern))
    return re.sub(pattern, lambda m: repl(m), text, count=1, flags=flags)

def after(line_pat, new):            # insert `new` right after the (single) line matching line_pat
    return (r"(\n[ \t]*" + line_pat + r"[ \t]*\n)", lambda m: m.group(1) + new)

PKG_ADD = """  // Xai: AI-acceleration extension in the custom-0 opcode space (dot8 / qrelu / max8)
  localparam logic [6:0] OP_CUSTOM0 = 7'b0001011;

  typedef enum logic [2:0] {
    AI_DOT8  = 3'd0,   // funct3 = 000
    AI_QRELU = 3'd1,   // funct3 = 001, shift in funct7[4:0]
    AI_MAX8  = 3'd2    // funct3 = 010
  } ai_op_e;

"""

DEC_CASE = """      // ---------------------------------------------------------------
      // Xai (custom-0), R-type, funct3 selects the operation:
      //   000 dot8   rd = sum of 8 signed int8 products                      funct7 = 0
      //   001 qrelu  4 x int32 (rs1,rs2) -> 4 x int8 in rd[31:0], shift = funct7[4:0], funct7[6:5] = 0
      //   010 max8   per-byte signed max                                     funct7 = 0
      OP_CUSTOM0: begin
        is_ai     = 1'b1;
        rs1_used  = 1'b1;
        rs2_used  = 1'b1;
        reg_write = 1'b1;
        wb_sel    = WB_ALU;
        case (funct3)
          3'b000: begin ai_op = AI_DOT8;  if (funct7 != 7'b0)        illegal_instr = 1'b1; end
          3'b001: begin ai_op = AI_QRELU; if (funct7[6:5] != 2'b00)  illegal_instr = 1'b1; end
          3'b010: begin ai_op = AI_MAX8;  if (funct7 != 7'b0)        illegal_instr = 1'b1; end
          default: illegal_instr = 1'b1;
        endcase
      end

"""

AI_INST = """  // ---------------- Xai: AI instructions (custom-0) ----------------
  localparam int AI_LAT = 2;                  // 1 = combinational in EX, 2 = operands registered (one stall cycle)
  assign ai_req = idex_valid && idex_is_ai && !ex_illegal;

  ai_unit #(.AI_LAT(AI_LAT)) ai_unit_inst (
      .clk    (clk),
      .rst_n  (rst_n),
      .req    (ai_req),
      .op     (idex_ai_op),
      .shamt  (idex_ai_shamt),
      .a      (fwd_rs1),
      .b      (fwd_rs2),
      .busy   (ai_busy),
      .result (ai_result)
  );

"""

def patch_pkg(t):
    i = t.rfind("endpackage")
    if i < 0: sys.exit("ANCHOR PROBLEM (pkg): no 'endpackage'")
    return t[:i] + PKG_ADD + t[i:]

def patch_decoder(t):
    t = edit(t, *after(r"output logic\s+is_csr,",
        "    // Xai control\n    output logic          is_ai,         // custom-0 AI instruction (result rides the ALU-result field)\n    output ai_op_e        ai_op,\n"), "decoder: ports")
    t = edit(t, *after(r"is_csr\s*=\s*1'b0;", "    is_ai         = 1'b0;\n    ai_op         = AI_DOT8;\n"), "decoder: defaults")
    t = edit(t, r"\n([ \t]*OP_MISC_MEM: begin)", lambda m: "\n" + DEC_CASE + m.group(1), "decoder: case")
    return t

def patch_top(t):
    t = edit(t, *after(r"logic\s+id_is_amo, id_is_lr, id_is_sc;",
        "  logic           id_is_ai;\n  ai_op_e         id_ai_op;\n  logic [4:0]     id_ai_shamt;\n"), "top: id decls")
    t = edit(t, *after(r"logic\s+idex_is_amo, idex_is_lr, idex_is_sc;",
        "  logic           idex_is_ai;\n  ai_op_e         idex_ai_op;\n  logic [4:0]     idex_ai_shamt;\n"), "top: idex decls")
    t = edit(t, *after(r"logic\s+fpu_req, fpu_busy, ex_busy;",
        "  logic           ai_req, ai_busy;\n  logic [63:0]    ai_result;\n"), "top: ex decls")
    t = edit(t, r"assign ex_busy(\s*)=\s*mdu_busy \|\| fpu_busy;", lambda m: "assign ex_busy%s= mdu_busy || fpu_busy || ai_busy;" % m.group(1), "top: ex_busy")
    t = edit(t, *after(r"\.is_csr\s*\(id_is_csr\),", "      .is_ai         (id_is_ai),\n      .ai_op         (id_ai_op),\n"), "top: decoder ports")
    t = edit(t, *after(r"assign id_funct3\s*=\s*ifid_instr\[14:12\];", "  assign id_ai_shamt = ifid_instr[29:25];          // qrelu shift amount\n"), "top: ai shamt")
    t = edit(t, *after(r"idex_is_csr\s*<=\s*id_is_csr;",
        "      idex_is_ai        <= id_is_ai;\n      idex_ai_op        <= id_ai_op;\n      idex_ai_shamt     <= id_ai_shamt;\n"), "top: idex regs")
    t = edit(t, r"([ \t]*)assign ex_result = idex_is_fpu",
             lambda m: AI_INST + m.group(1) + "assign ex_result = idex_is_ai                    ? ai_result  :\n" + m.group(1) + "                   idex_is_fpu", "top: ex_result")
    return t

FILES = [("rv64imafc_pkg.sv", patch_pkg, "OP_CUSTOM0"), ("decoder.sv", patch_decoder, "is_ai"), ("rv64imafc_top.sv", patch_top, "ai_unit_inst")]

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry = "--dry-run" in sys.argv
    if len(args) != 1: sys.exit(__doc__)
    d = args[0]
    out = {}
    for name, fn, marker in FILES:
        p = os.path.join(d, name)
        if not os.path.isfile(p): sys.exit("missing file: %s" % p)
        t = open(p).read()
        if marker in t:
            print("skip (already patched):", name); continue
        out[p] = fn(t)
    if dry:
        print("dry run OK: all anchors found; would modify:", [os.path.basename(p) for p in out]); return
    for p, t in out.items():
        shutil.copyfile(p, p + ".pre_ai")
        open(p, "w").write(t)
        print("patched:", p, "(backup: %s.pre_ai)" % os.path.basename(p))

if __name__ == "__main__":
    main()