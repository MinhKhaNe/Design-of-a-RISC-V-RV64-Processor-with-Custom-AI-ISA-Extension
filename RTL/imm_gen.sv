import rv64im_pkg::*;

module imm_gen (
    input  logic [31:0] instr,
    input  imm_type_e   imm_type,
    output logic [63:0] imm_o
);

  always_comb begin
    case (imm_type)
      // I-type: loads, OP-IMM, JALR      imm[11:0] = instr[31:20]
      IMM_I: imm_o = {{52{instr[31]}}, instr[31:20]};

      // S-type: stores                   imm[11:5]=instr[31:25], imm[4:0]=instr[11:7]
      IMM_S: imm_o = {{52{instr[31]}}, instr[31:25], instr[11:7]};

      // B-type: branches                 bits scrambled for HW-friendly decode;
      //         imm[12|10:5|4:1|11] = instr[31|30:25|11:8|7], bit0 = 0
      IMM_B: imm_o = {{51{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};

      // U-type: LUI, AUIPC               imm[31:12] = instr[31:12], low 12 bits = 0
      IMM_U: imm_o = {{32{instr[31]}}, instr[31:12], 12'b0};

      // J-type: JAL                      imm[20|10:1|11|19:12] = instr[31|30:21|20|19:12], bit0=0
      IMM_J: imm_o = {{43{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

      default: imm_o = 64'b0;
    endcase
  end

endmodule