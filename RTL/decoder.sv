import rv64imafc_pkg::*;

module decoder (
    input  logic [31:0]  instr,

    // register / immediate field extraction
    output logic [4:0]   rs1,
    output logic [4:0]   rs2,
    output logic [4:0]   rd,
    output imm_type_e    imm_type,

    // rs1 / rs2? (LUI/AUIPC/JAL don't; JALR/loads/OP-IMM only read rs1)
    output logic          rs1_used,
    output logic          rs2_used,
    output logic          rs3_used,      // R4-type FMA: rs3 = instr[31:27], always an FP register
    output logic          rs1_fp,        // rs1 is read from the FP register file
    output logic          rs2_fp,        // rs2 is read from the FP register file

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

    // RV64F control
    output logic          is_fpu,        // executes in the FPU (result rides the ALU-result field)
    output fpu_op_e       fpu_op,
    output logic          uses_rm,       // funct3 is a rounding mode (resolved to frm when 111)
    output logic          fp_reg_write,  // destination is an FP register (reg_write is integer-only)
    output logic          is_csr,
    // Xai control
    output logic          is_ai,         // custom-0 AI instruction (result rides the ALU-result field)
    output ai_op_e        ai_op,

    // RV64A control
    output logic          is_amo,        // AMOxxx.W/D: read-modify-write in MEM
    output logic          is_lr,         // LR.W/D
    output logic          is_sc,         // SC.W/D
    output amo_op_e       amo_op,        // Zicsr instruction (only fcsr/frm/fflags are implemented)

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
    imm_type      = IMM_X;
    rs1_used      = 1'b0;
    rs2_used      = 1'b0;
    rs3_used      = 1'b0;
    rs1_fp        = 1'b0;
    rs2_fp        = 1'b0;
    is_fpu        = 1'b0;
    fpu_op        = FPU_ADD;
    uses_rm       = 1'b0;
    fp_reg_write  = 1'b0;
    is_csr        = 1'b0;
    is_ai         = 1'b0;
    ai_op         = AI_DOT8;
    is_amo        = 1'b0;
    is_lr         = 1'b0;
    is_sc         = 1'b0;
    amo_op        = AMO_SWAP;
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
      OP_LUI: begin              // rd = imm_U
        imm_type  = IMM_U;
        alu_a_sel = ALU_A_ZERO;
        alu_b_sel = ALU_B_IMM;
        alu_op    = ALU_ADD;
        reg_write = 1'b1;
        wb_sel    = WB_ALU;
      end
      OP_AUIPC: begin            // rd = PC + imm_U
        imm_type  = IMM_U;
        alu_a_sel = ALU_A_PC;
        alu_b_sel = ALU_B_IMM;
        alu_op    = ALU_ADD;
        reg_write = 1'b1;
        wb_sel    = WB_ALU;
      end
      OP_JAL: begin               // rd = PC+4; PC = PC + imm_J
        imm_type  = IMM_J;
        is_jal    = 1'b1;
        reg_write = 1'b1;
        wb_sel    = WB_PC4;
      end
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
      OP_REG: begin                 // R-type: base ALU ops, or RV64M
        alu_a_sel = ALU_A_REG;
        alu_b_sel = ALU_B_REG;
        rs1_used  = 1'b1;
        rs2_used  = 1'b1;
        reg_write = 1'b1;
        if (funct7 == FUNCT7_MEXT) begin
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
      OP_REG_32: begin              // ADDW/SUBW/... (RV64 only), or RV64M *W
        alu_a_sel = ALU_A_REG;
        alu_b_sel = ALU_B_REG;
        rs1_used  = 1'b1;
        rs2_used  = 1'b1;
        reg_write = 1'b1;
        if (funct7 == FUNCT7_MEXT) begin
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
      OP_SYSTEM: begin
        if (funct3 == 3'b000) begin
          reg_write = 1'b0;                 // ECALL/EBREAK/xRET/WFI: still stubbed as no-op
        end else if (funct3 == 3'b100) begin
          illegal_instr = 1'b1;
        end else begin                      // CSRRW/S/C and the *I forms
          is_csr    = 1'b1;
          rs1_used  = !funct3[2];           // *I forms carry a 5-bit immediate in the rs1 field
          reg_write = 1'b1;
          wb_sel    = WB_ALU;
        end
      end
      OP_AMO: begin
        imm_type  = IMM_X;
        alu_a_sel = ALU_A_REG;
        alu_b_sel = ALU_B_IMM;
        alu_op    = ALU_ADD;
        rs1_used  = 1'b1;
        reg_write = 1'b1;
        wb_sel    = WB_MEM;
        mem_read  = 1'b1;
        case (funct3)
          3'b010:  mem_width = MEM_W;
          3'b011:  mem_width = MEM_D;
          default: illegal_instr = 1'b1;
        endcase
        case (funct7[6:2])
          5'b00010: begin                          // LR
            is_lr = 1'b1;
            if (rs2 != 5'd0) illegal_instr = 1'b1;
          end
          5'b00011: begin                          // SC
            is_sc = 1'b1; rs2_used = 1'b1; mem_write = 1'b1;
          end
          5'b00001: begin is_amo = 1'b1; amo_op = AMO_SWAP; rs2_used = 1'b1; mem_write = 1'b1; end
          5'b00000: begin is_amo = 1'b1; amo_op = AMO_ADD;  rs2_used = 1'b1; mem_write = 1'b1; end
          5'b00100: begin is_amo = 1'b1; amo_op = AMO_XOR;  rs2_used = 1'b1; mem_write = 1'b1; end
          5'b01100: begin is_amo = 1'b1; amo_op = AMO_AND;  rs2_used = 1'b1; mem_write = 1'b1; end
          5'b01000: begin is_amo = 1'b1; amo_op = AMO_OR;   rs2_used = 1'b1; mem_write = 1'b1; end
          5'b10000: begin is_amo = 1'b1; amo_op = AMO_MIN;  rs2_used = 1'b1; mem_write = 1'b1; end
          5'b10100: begin is_amo = 1'b1; amo_op = AMO_MAX;  rs2_used = 1'b1; mem_write = 1'b1; end
          5'b11000: begin is_amo = 1'b1; amo_op = AMO_MINU; rs2_used = 1'b1; mem_write = 1'b1; end
          5'b11100: begin is_amo = 1'b1; amo_op = AMO_MAXU; rs2_used = 1'b1; mem_write = 1'b1; end
          default:  illegal_instr = 1'b1;
        endcase
      end
      // ---------------------------------------------------------------
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

      OP_MISC_MEM: begin                          
        if (funct3 != 3'b000 && funct3 != 3'b001) illegal_instr = 1'b1;
      end
      OP_LOAD_FP: begin                     // FLW
        imm_type     = IMM_I;
        alu_a_sel    = ALU_A_REG;
        alu_b_sel    = ALU_B_IMM;
        alu_op       = ALU_ADD;
        mem_read     = 1'b1;
        mem_width    = MEM_W;
        rs1_used     = 1'b1;
        fp_reg_write = 1'b1;
        wb_sel       = WB_MEM;
        if (funct3 != 3'b010) illegal_instr = 1'b1;   // FLD etc. need the D extension
      end
      OP_STORE_FP: begin                    // FSW
        imm_type  = IMM_S;
        alu_a_sel = ALU_A_REG;
        alu_b_sel = ALU_B_IMM;
        alu_op    = ALU_ADD;
        mem_write = 1'b1;
        mem_width = MEM_W;
        rs1_used  = 1'b1;
        rs2_used  = 1'b1;
        rs2_fp    = 1'b1;
        if (funct3 != 3'b010) illegal_instr = 1'b1;
      end
      OP_FMADD, OP_FMSUB, OP_FNMSUB, OP_FNMADD: begin
        is_fpu       = 1'b1;
        rs1_used     = 1'b1;
        rs2_used     = 1'b1;
        rs3_used     = 1'b1;
        rs1_fp       = 1'b1;
        rs2_fp       = 1'b1;
        fp_reg_write = 1'b1;
        uses_rm      = 1'b1;
        wb_sel       = WB_ALU;
        case (opcode)
          OP_FMADD:  fpu_op = FPU_MADD;
          OP_FMSUB:  fpu_op = FPU_MSUB;
          OP_FNMSUB: fpu_op = FPU_NMSUB;
          default:   fpu_op = FPU_NMADD;
        endcase
        if (funct7[1:0] != 2'b00) illegal_instr = 1'b1;               // fmt must be S
        if (funct3 == 3'b101 || funct3 == 3'b110) illegal_instr = 1'b1; // reserved rm
      end
      OP_FP: begin
        is_fpu    = 1'b1;
        rs1_used  = 1'b1;
        wb_sel    = WB_ALU;
        if (funct7[1:0] != 2'b00) illegal_instr = 1'b1;               // fmt must be S
        case (funct7[6:2])
          5'b00000: begin fpu_op = FPU_ADD; rs2_used = 1'b1; rs1_fp = 1'b1; rs2_fp = 1'b1; fp_reg_write = 1'b1; uses_rm = 1'b1; end
          5'b00001: begin fpu_op = FPU_SUB; rs2_used = 1'b1; rs1_fp = 1'b1; rs2_fp = 1'b1; fp_reg_write = 1'b1; uses_rm = 1'b1; end
          5'b00010: begin fpu_op = FPU_MUL; rs2_used = 1'b1; rs1_fp = 1'b1; rs2_fp = 1'b1; fp_reg_write = 1'b1; uses_rm = 1'b1; end
          5'b00011: begin fpu_op = FPU_DIV; rs2_used = 1'b1; rs1_fp = 1'b1; rs2_fp = 1'b1; fp_reg_write = 1'b1; uses_rm = 1'b1; end
          5'b01011: begin                                              // FSQRT.S
            fpu_op = FPU_SQRT; rs1_fp = 1'b1; fp_reg_write = 1'b1; uses_rm = 1'b1;
            if (rs2 != 5'd0) illegal_instr = 1'b1;
          end
          5'b00100: begin                                              // FSGNJ/FSGNJN/FSGNJX
            rs2_used = 1'b1; rs1_fp = 1'b1; rs2_fp = 1'b1; fp_reg_write = 1'b1;
            case (funct3)
              3'b000:  fpu_op = FPU_SGNJ;
              3'b001:  fpu_op = FPU_SGNJN;
              3'b010:  fpu_op = FPU_SGNJX;
              default: illegal_instr = 1'b1;
            endcase
          end
          5'b00101: begin                                              // FMIN/FMAX
            rs2_used = 1'b1; rs1_fp = 1'b1; rs2_fp = 1'b1; fp_reg_write = 1'b1;
            case (funct3)
              3'b000:  fpu_op = FPU_MIN;
              3'b001:  fpu_op = FPU_MAX;
              default: illegal_instr = 1'b1;
            endcase
          end
          5'b11000: begin                                              // FCVT.{W,WU,L,LU}.S  (int rd)
            rs1_fp = 1'b1; reg_write = 1'b1; uses_rm = 1'b1;
            case (rs2)
              5'd0:    fpu_op = FPU_CVT_W_S;
              5'd1:    fpu_op = FPU_CVT_WU_S;
              5'd2:    fpu_op = FPU_CVT_L_S;
              5'd3:    fpu_op = FPU_CVT_LU_S;
              default: illegal_instr = 1'b1;
            endcase
          end
          5'b11010: begin                                              // FCVT.S.{W,WU,L,LU}  (int rs1)
            fp_reg_write = 1'b1; uses_rm = 1'b1;
            case (rs2)
              5'd0:    fpu_op = FPU_CVT_S_W;
              5'd1:    fpu_op = FPU_CVT_S_WU;
              5'd2:    fpu_op = FPU_CVT_S_L;
              5'd3:    fpu_op = FPU_CVT_S_LU;
              default: illegal_instr = 1'b1;
            endcase
          end
          5'b11100: begin                                              // FMV.X.W / FCLASS.S
            rs1_fp = 1'b1; reg_write = 1'b1;
            if (rs2 != 5'd0) illegal_instr = 1'b1;
            case (funct3)
              3'b000:  fpu_op = FPU_MV_X_W;
              3'b001:  fpu_op = FPU_CLASS;
              default: illegal_instr = 1'b1;
            endcase
          end
          5'b11110: begin                                              // FMV.W.X
            fp_reg_write = 1'b1;
            fpu_op = FPU_MV_W_X;
            if (rs2 != 5'd0 || funct3 != 3'b000) illegal_instr = 1'b1;
          end
          5'b10100: begin                                              // FEQ/FLT/FLE
            rs2_used = 1'b1; rs1_fp = 1'b1; rs2_fp = 1'b1; reg_write = 1'b1;
            case (funct3)
              3'b010:  fpu_op = FPU_EQ;
              3'b001:  fpu_op = FPU_LT;
              3'b000:  fpu_op = FPU_LE;
              default: illegal_instr = 1'b1;
            endcase
          end
          default: illegal_instr = 1'b1;
        endcase
        if (uses_rm && (funct3 == 3'b101 || funct3 == 3'b110)) illegal_instr = 1'b1;
      end
      default: illegal_instr = 1'b1;
    endcase
  end

endmodule