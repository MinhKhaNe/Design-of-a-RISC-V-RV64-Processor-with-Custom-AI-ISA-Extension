// 32 x 32-bit floating-point register file (f0 is a normal register, NOT hard-wired to zero).
// 3 read ports (FMA needs rs3), 1 write port, write-through bypass like regfile.sv.
module fp_regfile (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [4:0]  rs1_addr,
    input  logic [4:0]  rs2_addr,
    input  logic [4:0]  rs3_addr,
    output logic [31:0] rs1_data,
    output logic [31:0] rs2_data,
    output logic [31:0] rs3_data,

    input  logic [4:0]  rd_addr,
    input  logic [31:0] rd_data,
    input  logic        rd_write_en
);

  logic [31:0] regs [0:31];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 32; i++) regs[i] <= 32'b0;
    end else if (rd_write_en) begin
      regs[rd_addr] <= rd_data;
    end
  end

  assign rs1_data = (rd_write_en && rd_addr == rs1_addr) ? rd_data : regs[rs1_addr];
  assign rs2_data = (rd_write_en && rd_addr == rs2_addr) ? rd_data : regs[rs2_addr];
  assign rs3_data = (rd_write_en && rd_addr == rs3_addr) ? rd_data : regs[rs3_addr];

endmodule