module regfile (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [4:0]  rs1_addr,
    input  logic [4:0]  rs2_addr,
    output logic [63:0] rs1_data,
    output logic [63:0] rs2_data,

    input  logic [4:0]  rd_addr,
    input  logic [63:0] rd_data,
    input  logic        rd_write_en
);

  logic [63:0] regs [1:31];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 1; i < 32; i++) regs[i] <= 64'b0;
    end else if (rd_write_en && rd_addr != 5'd0) begin
      regs[rd_addr] <= rd_data;
    end
  end

  assign rs1_data = (rs1_addr == 5'd0) ? 64'b0 :
                     (rd_write_en && rd_addr == rs1_addr) ? rd_data :
                     regs[rs1_addr];

  assign rs2_data = (rs2_addr == 5'd0) ? 64'b0 :
                     (rd_write_en && rd_addr == rs2_addr) ? rd_data :
                     regs[rs2_addr];

endmodule