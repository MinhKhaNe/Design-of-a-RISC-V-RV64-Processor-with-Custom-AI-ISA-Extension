module hazard_unit (
    input  logic       idex_mem_read,   // load currently sitting in EX (gate with idex_valid at call site)
    input  logic [4:0] idex_rd,
    input  logic [4:0] ifid_rs1,        // rs1/rs2 of the instruction currently in ID
    input  logic [4:0] ifid_rs2,
    input  logic        ifid_rs1_used,   // does the ID-stage instruction actually read rs1/rs2?
    input  logic        ifid_rs2_used,   // (LUI/AUIPC/JAL don't; avoids false stalls on don't-care fields)
    output logic       stall
);

  assign stall = idex_mem_read && (idex_rd != 5'd0) &&
                 ((ifid_rs1_used && (idex_rd == ifid_rs1)) ||
                  (ifid_rs2_used && (idex_rd == ifid_rs2)));

endmodule