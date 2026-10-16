module fp_forward_unit (
    input  logic [4:0] idex_rs1,
    input  logic [4:0] idex_rs2,
    input  logic [4:0] idex_rs3,

    input  logic       exmem_fp_reg_write,
    input  logic [4:0] exmem_rd,

    input  logic       memwb_fp_reg_write,
    input  logic [4:0] memwb_rd,

    output logic [1:0] forward_a,   // 00 = none, 01 = EX/MEM, 10 = MEM/WB
    output logic [1:0] forward_b,
    output logic [1:0] forward_c
);

  function automatic logic [1:0] pick(input logic [4:0] src);
    if (exmem_fp_reg_write && exmem_rd == src)      pick = 2'b01;
    else if (memwb_fp_reg_write && memwb_rd == src) pick = 2'b10;
    else                                            pick = 2'b00;
  endfunction

  always_comb begin
    forward_a = pick(idex_rs1);
    forward_b = pick(idex_rs2);
    forward_c = pick(idex_rs3);
  end

endmodule