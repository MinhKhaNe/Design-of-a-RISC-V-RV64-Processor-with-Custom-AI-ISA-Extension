import rv64im_pkg::*;

module alu (
    input  alu_op_e     alu_op,
    input  logic [63:0] a,
    input  logic [63:0] b,
    output logic [63:0] result,
    output logic        zero        // result == 0, handy for some branch styles
);

  logic [31:0] a32, b32;
  logic [31:0] result32;

  assign a32 = a[31:0];
  assign b32 = b[31:0];

  always_comb begin
    case (alu_op)
      ALU_ADD:  result = a + b;
      ALU_SUB:  result = a - b;
      ALU_SLL:  result = a << b[5:0];               // shamt is 6 bits for RV64 shifts
      ALU_SLT:  result = {63'b0, ($signed(a) < $signed(b))};
      ALU_SLTU: result = {63'b0, (a < b)};
      ALU_XOR:  result = a ^ b;
      ALU_SRL:  result = a >> b[5:0];
      ALU_SRA:  result = $signed(a) >>> b[5:0];
      ALU_OR:   result = a | b;
      ALU_AND:  result = a & b;

      // ---- 32-bit "W" variants: compute on low 32 bits, sign-extend result ----
      ALU_ADDW: begin
        result32 = a32 + b32;
        result   = {{32{result32[31]}}, result32};
      end
      ALU_SUBW: begin
        result32 = a32 - b32;
        result   = {{32{result32[31]}}, result32};
      end
      ALU_SLLW: begin
        result32 = a32 << b[4:0];                    // shamt is 5 bits for *W shifts
        result   = {{32{result32[31]}}, result32};
      end
      ALU_SRLW: begin
        result32 = a32 >> b[4:0];
        result   = {{32{result32[31]}}, result32};
      end
      ALU_SRAW: begin
        result32 = $signed(a32) >>> b[4:0];
        result   = {{32{result32[31]}}, result32};
      end

      default: result = 64'b0;
    endcase
  end

  assign zero = (result == 64'b0);

endmodule