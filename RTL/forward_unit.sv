module forward_unit (
    input  logic [4:0] idex_rs1,
    input  logic [4:0] idex_rs2,

    input  logic       exmem_reg_write,
    input  logic [4:0] exmem_rd,

    input  logic       memwb_reg_write,
    input  logic [4:0] memwb_rd,

    output logic [1:0] forward_a,   // 00 = no forward (use idex_rs1_data)
    output logic [1:0] forward_b    // 01 = forward from EX/MEM, 10 = forward from MEM/WB
);

  always_comb begin
    if (exmem_reg_write && (exmem_rd != 5'd0) && (exmem_rd == idex_rs1))
      forward_a = 2'b01;
    else if (memwb_reg_write && (memwb_rd != 5'd0) && (memwb_rd == idex_rs1))
      forward_a = 2'b10;
    else
      forward_a = 2'b00;

    if (exmem_reg_write && (exmem_rd != 5'd0) && (exmem_rd == idex_rs2))
      forward_b = 2'b01;
    else if (memwb_reg_write && (memwb_rd != 5'd0) && (memwb_rd == idex_rs2))
      forward_b = 2'b10;
    else
      forward_b = 2'b00;
  end

endmodule