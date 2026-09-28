import rv64im_pkg::*;

module decoder (
    input  logic [31:0]  instr,

    // register / immediate field extraction
    output logic [4:0]   rs1,
    output logic [4:0]   rs2,
    output logic [4:0]   rd,
    output imm_type_e    imm_type,

    // hazard-detection helpers: does this instruction actually *read*
    // rs1 / rs2? (LUI/AUIPC/JAL don't; JALR/loads/OP-IMM only read rs1)
    output logic          rs1_used,
    output logic          rs2_used,

    // ALU control
    output alu_op_e       alu_op,
    output alu_a_sel_e    alu_a_sel,
    output alu_b_sel_e    alu_b_sel,

    // RV64M control (mutually exclusive with each other and with the ALU
    // for any given instruction; qualified by wb_sel == WB_MEXT)
    output logic          is_mul,
    output logic          is_div,
    output mul_op_e       mul_op,
    output div_op_e       div_op,

    // branch / jump control
    output branch_type_e  branch_type,
    output logic          is_jal,
    output logic          is_jalr,

    // memory control
    output logic          mem_read,
    output logic          mem_write,
    output mem_width_e    mem_width,

    // writeback control
    output logic          reg_write,
    output wb_sel_e        wb_sel,

    // decode-error flag (illegal / unimplemented instruction)
    output logic          illegal_instr
);

  logic [6:0] opcode;
  logic [2:0] funct3;
  logic [6:0] funct7;

  assign opcode = instr[6:0];
  assign funct3 = instr[14:12];
  assign funct7 = instr[31:25];
  assign rs1    = instr[19:15];
  assign rs2    = instr[24:20];
  assign rd     = instr[11:7];

  always_comb begin
    // ---- safe defaults (NOP-like / no side effects) ----
    imm_type      = IMM_X;
    rs1_used      = 1'b0;
    rs2_used      = 1'b0;
    alu_op        = ALU_ADD;
    alu_a_sel     = ALU_A_REG;
    alu_b_sel     = ALU_B_IMM;
    is_mul        = 1'b0;
    is_div        = 1'b0;
    mul_op        = MUL_MUL;
    div_op        = DIV_DIV;
    branch_type   = BR_NONE;
    is_jal        = 1'b0;
    is_jalr       = 1'b0;
    mem_read      = 1'b0;
    mem_write     = 1'b0;
    mem_width     = MEM_W;
    reg_write     = 1'b0;
    wb_sel        = WB_ALU;
    illegal_instr = 1'b0;

    case (opcode)

      // ---------------------------------------------------------------
      OP_LUI: begin              // rd = imm_U
        imm_type  = IMM_U;
        alu_a_sel = ALU_A_ZERO;
        alu_b_sel = ALU_B_IMM;
        alu_op    = ALU_ADD;
        reg_write = 1'b1;
        wb_sel    = WB_ALU;
      end

      // ---------------------------------------------------------------
      OP_AUIPC: begin            // rd = PC + imm_U
        imm_type  = IMM_U;
        alu_a_sel = ALU_A_PC;
        alu_b_sel = ALU_B_IMM;
        alu_op    = ALU_ADD;
        reg_write = 1'b1;
        wb_sel    = WB_ALU;
      end

      // ---------------------------------------------------------------
      OP_JAL: begin               // rd = PC+4; PC = PC + imm_J
        imm_type  = IMM_J;
        is_jal    = 1'b1;
        reg_write = 1'b1;
        wb_sel    = WB_PC4;
      end

      // ---------------------------------------------------------------
      OP_JALR: begin               // rd = PC+4; PC = (rs1 + imm_I) & ~1
        imm_type  = IMM_I;
        is_jalr   = 1'b1;
        rs1_used  = 1'b1;
        alu_a_sel = ALU_A_REG;     // ALU computes rs1+imm for target calc
        alu_b_sel = ALU_B_IMM;
        alu_op    = ALU_ADD;
        reg_write = 1'b1;
        wb_sel    = WB_PC4;
        if (funct3 != 3'b000) illegal_instr = 1'b1;   // only funct3=000 is defined for JALR
      end

      // ---------------------------------------------------------------
      OP_BRANCH: begin
        imm_type    = IMM_B;
        alu_a_sel   = ALU_A_PC;    // target = PC + imm_B, computed on ALU
        alu_b_sel   = ALU_B_IMM;
        alu_op      = ALU_ADD;
        reg_write   = 1'b0;
        rs1_used    = 1'b1;
        rs2_used    = 1'b1;
        case (funct3)
          3'b000, 3'b001, 3'b100, 3'b101, 3'b110, 3'b111:
            branch_type = branch_type_e'(funct3);
          default: begin                         // funct3 = 010/011: reserved, unencoded
            branch_type   = BR_NONE;
            illegal_instr = 1'b1;
          end
        endcase
      end

      // ---------------------------------------------------------------
      OP_LOAD: begin
        imm_type  = IMM_I;
        alu_a_sel = ALU_A_REG;
        alu_b_sel = ALU_B_IMM;
        alu_op    = ALU_ADD;       // address = rs1 + imm_I
        mem_read  = 1'b1;
        rs1_used  = 1'b1;
        reg_write = 1'b1;
        wb_sel    = WB_MEM;
        case (funct3)
          3'b000, 3'b001, 3'b010, 3'b011, 3'b100, 3'b101, 3'b110:
            mem_width = mem_width_e'(funct3);
          default: begin                         // funct3 = 111: reserved
            mem_width     = MEM_W;
            illegal_instr = 1'b1;
          end
        endcase
      end

      // ---------------------------------------------------------------
      OP_STORE: begin
        imm_type  = IMM_S;
        alu_a_sel = ALU_A_REG;
        alu_b_sel = ALU_B_IMM;
        alu_op    = ALU_ADD;       // address = rs1 + imm_S
        mem_write = 1'b1;
        rs1_used  = 1'b1;
        rs2_used  = 1'b1;
        reg_write = 1'b0;
        case (funct3)
          3'b000, 3'b001, 3'b010, 3'b011:         // SB/SH/SW/SD only
            mem_width = mem_width_e'(funct3);
          default: begin                          // 100-111: no unsigned stores exist
            mem_width     = MEM_W;
            illegal_instr = 1'b1;
          end
        endcase
      end

      // ---------------------------------------------------------------
      OP_IMM: begin                // ADDI/SLTI/.../ANDI, SLLI/SRLI/SRAI
        imm_type  = IMM_I;
        alu_a_sel = ALU_A_REG;
        alu_b_sel = ALU_B_IMM;
        rs1_used  = 1'b1;
        reg_write = 1'b1;
        wb_sel    = WB_ALU;
        case (funct3)
          3'b000: alu_op = ALU_ADD;   // ADDI
          3'b010: alu_op = ALU_SLT;   // SLTI
          3'b011: alu_op = ALU_SLTU;  // SLTIU
          3'b100: alu_op = ALU_XOR;   // XORI
          3'b110: alu_op = ALU_OR;    // ORI
          3'b111: alu_op = ALU_AND;   // ANDI
          3'b001: begin                // SLLI (shamt = imm[5:0])
            alu_op = ALU_SLL;
            if (funct7[6:1] != 6'b0) illegal_instr = 1'b1;  // funct7[5:0] must be 0 (bit6 always 0)
          end
          3'b101: begin               // SRAI/SRLI
            if (funct7[5]) alu_op = ALU_SRA;
            else           alu_op = ALU_SRL;
            if (funct7[6] || funct7[4:1] != 4'b0) illegal_instr = 1'b1;
          end
          default: illegal_instr = 1'b1;
        endcase
      end

      // ---------------------------------------------------------------
      OP_IMM_32: begin             // ADDIW/SLLIW/SRLIW/SRAIW (32b, RV64 only)
        imm_type  = IMM_I;
        alu_a_sel = ALU_A_REG;
        alu_b_sel = ALU_B_IMM;
        rs1_used  = 1'b1;
        reg_write = 1'b1;
        wb_sel    = WB_ALU;
        case (funct3)
          3'b000: alu_op = ALU_ADDW;  // ADDIW
          3'b001: begin                // SLLIW (shamt = imm[4:0])
            alu_op = ALU_SLLW;
            if (funct7 != 7'b0) illegal_instr = 1'b1;
          end
          3'b101: begin                // SRAIW/SRLIW
            if (funct7[5]) alu_op = ALU_SRAW;
            else           alu_op = ALU_SRLW;
            if (funct7[6] || funct7[4:0] != 5'b0) illegal_instr = 1'b1;
          end
          default: illegal_instr = 1'b1;
        endcase
      end

      // ---------------------------------------------------------------
      OP_REG: begin                 // R-type: base ALU ops, or RV64M
        alu_a_sel = ALU_A_REG;
        alu_b_sel = ALU_B_REG;
        rs1_used  = 1'b1;
        rs2_used  = 1'b1;
        reg_write = 1'b1;

        if (funct7 == FUNCT7_MEXT) begin
          // ---- RV64M: MUL/MULH/MULHSU/MULHU/DIV/DIVU/REM/REMU ----
          wb_sel = WB_MEXT;
          case (funct3)
            3'b000: begin is_mul = 1'b1; mul_op = MUL_MUL;    end
            3'b001: begin is_mul = 1'b1; mul_op = MUL_MULH;   end
            3'b010: begin is_mul = 1'b1; mul_op = MUL_MULHSU; end
            3'b011: begin is_mul = 1'b1; mul_op = MUL_MULHU;  end
            3'b100: begin is_div = 1'b1; div_op = DIV_DIV;    end
            3'b101: begin is_div = 1'b1; div_op = DIV_DIVU;   end
            3'b110: begin is_div = 1'b1; div_op = DIV_REM;    end
            3'b111: begin is_div = 1'b1; div_op = DIV_REMU;   end
            default: illegal_instr = 1'b1;   // unreachable: funct3 is 3 bits, all 8 covered above
          endcase
        end else begin
          // ---- base RV64I R-type integer ops ----
          wb_sel = WB_ALU;
          case ({funct7, funct3})
            {7'b0000000, 3'b000}: alu_op = ALU_ADD;   // ADD
            {7'b0100000, 3'b000}: alu_op = ALU_SUB;   // SUB
            {7'b0000000, 3'b001}: alu_op = ALU_SLL;   // SLL
            {7'b0000000, 3'b010}: alu_op = ALU_SLT;   // SLT
            {7'b0000000, 3'b011}: alu_op = ALU_SLTU;  // SLTU
            {7'b0000000, 3'b100}: alu_op = ALU_XOR;   // XOR
            {7'b0000000, 3'b101}: alu_op = ALU_SRL;   // SRL
            {7'b0100000, 3'b101}: alu_op = ALU_SRA;   // SRA
            {7'b0000000, 3'b110}: alu_op = ALU_OR;    // OR
            {7'b0000000, 3'b111}: alu_op = ALU_AND;   // AND
            default: illegal_instr = 1'b1;
          endcase
        end
      end

      // ---------------------------------------------------------------
      OP_REG_32: begin              // ADDW/SUBW/... (RV64 only), or RV64M *W
        alu_a_sel = ALU_A_REG;
        alu_b_sel = ALU_B_REG;
        rs1_used  = 1'b1;
        rs2_used  = 1'b1;
        reg_write = 1'b1;

        if (funct7 == FUNCT7_MEXT) begin
          // ---- RV64M word ops: MULW/DIVW/DIVUW/REMW/REMUW ----
          wb_sel = WB_MEXT;
          case (funct3)
            3'b000: begin is_mul = 1'b1; mul_op = MUL_MULW;  end
            3'b100: begin is_div = 1'b1; div_op = DIV_DIVW;  end
            3'b101: begin is_div = 1'b1; div_op = DIV_DIVUW; end
            3'b110: begin is_div = 1'b1; div_op = DIV_REMW;  end
            3'b111: begin is_div = 1'b1; div_op = DIV_REMUW; end
            default: illegal_instr = 1'b1;   // 001/010/011: no MULHW-style ops exist
          endcase
        end else begin
          wb_sel = WB_ALU;
          case ({funct7, funct3})
            {7'b0000000, 3'b000}: alu_op = ALU_ADDW;
            {7'b0100000, 3'b000}: alu_op = ALU_SUBW;
            {7'b0000000, 3'b001}: alu_op = ALU_SLLW;
            {7'b0000000, 3'b101}: alu_op = ALU_SRLW;
            {7'b0100000, 3'b101}: alu_op = ALU_SRAW;
            default: illegal_instr = 1'b1;
          endcase
        end
      end

      // ---------------------------------------------------------------
      OP_SYSTEM: begin
        // ECALL/EBREAK/CSR ops: stubbed as no-op here. Wire into your
        // trap/CSR unit when you add M-mode support (Step 6 of the
        // pipeline plan). Not treated as illegal so the pipeline doesn't
        // stall on it while you're still bringing up the base ISA.
        reg_write = 1'b0;
      end

      default: illegal_instr = 1'b1;

    endcase
  end

endmodule