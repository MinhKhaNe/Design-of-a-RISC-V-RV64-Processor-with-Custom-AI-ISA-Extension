// Load-use hazard detection, aware of the separate integer / FP register files.
module hazard_unit (
    input  logic        idex_mem_read,   // load (LW/LD/FLW...) in EX, gated with idex_valid at call site
    input  logic [4:0]  idex_rd,
    input  logic        idex_rd_fp,      // the load writes the FP register file (FLW)

    input  logic [4:0]  ifid_rs1,        // operands of the instruction in ID
    input  logic [4:0]  ifid_rs2,
    input  logic [4:0]  ifid_rs3,        // R4-type only (always an FP register)
    input  logic        ifid_rs1_used,
    input  logic        ifid_rs2_used,
    input  logic        ifid_rs3_used,
    input  logic        ifid_rs1_fp,     // operand is read from the FP register file
    input  logic        ifid_rs2_fp,

    output logic        stall
);

  logic m1, m2, m3;

  // x0 never creates a hazard; f0 does.
  assign m1 = ifid_rs1_used && (ifid_rs1_fp == idex_rd_fp) && (idex_rd == ifid_rs1);
  assign m2 = ifid_rs2_used && (ifid_rs2_fp == idex_rd_fp) && (idex_rd == ifid_rs2);
  assign m3 = ifid_rs3_used && idex_rd_fp                  && (idex_rd == ifid_rs3);

  assign stall = idex_mem_read && (idex_rd_fp || (idex_rd != 5'd0)) && (m1 || m2 || m3);

endmodule