package rv64im_pkg;

  // ---------------------------------------------------------------------
  // Immediate format selector (feeds imm_gen)
  // ---------------------------------------------------------------------
  typedef enum logic [2:0] {
    IMM_I = 3'b000,
    IMM_S = 3'b001,
    IMM_B = 3'b010,
    IMM_U = 3'b011,
    IMM_J = 3'b100,
    IMM_X = 3'b111   // don't-care (e.g. R-type has no immediate)
  } imm_type_e;

  // ---------------------------------------------------------------------
  // ALU operation selector
  // ---------------------------------------------------------------------
  typedef enum logic [3:0] {
    ALU_ADD  = 4'd0,
    ALU_SUB  = 4'd1,
    ALU_SLL  = 4'd2,
    ALU_SLT  = 4'd3,
    ALU_SLTU = 4'd4,
    ALU_XOR  = 4'd5,
    ALU_SRL  = 4'd6,
    ALU_SRA  = 4'd7,
    ALU_OR   = 4'd8,
    ALU_AND  = 4'd9,
    ALU_ADDW = 4'd10,
    ALU_SUBW = 4'd11,
    ALU_SLLW = 4'd12,
    ALU_SRLW = 4'd13,
    ALU_SRAW = 4'd14
  } alu_op_e;

  // ALU operand A source
  typedef enum logic [1:0] {
    ALU_A_REG  = 2'b00,  // rs1
    ALU_A_PC   = 2'b01,  // PC        (AUIPC, branch/jump target calc)
    ALU_A_ZERO = 2'b10   // 0         (LUI: rd = 0 + imm)
  } alu_a_sel_e;

  // ALU operand B source
  typedef enum logic [0:0] {
    ALU_B_REG = 1'b0,  // rs2
    ALU_B_IMM = 1'b1   // decoded immediate
  } alu_b_sel_e;

  // ---------------------------------------------------------------------
  // RV64M: multiply operation selector
  // (word (*W) variant folded in, same pattern as ALU_ADDW/etc above)
  // ---------------------------------------------------------------------
  typedef enum logic [2:0] {
    MUL_MUL    = 3'b000,  // low 64 bits of rs1*rs2
    MUL_MULH   = 3'b001,  // high 64 bits, signed x signed
    MUL_MULHSU = 3'b010,  // high 64 bits, signed(rs1) x unsigned(rs2)
    MUL_MULHU  = 3'b011,  // high 64 bits, unsigned x unsigned
    MUL_MULW   = 3'b100   // low 32 bits of rs1[31:0]*rs2[31:0], sign-extended
  } mul_op_e;

  // ---------------------------------------------------------------------
  // RV64M: divide/remainder operation selector
  // (word (*W) variants included; each is a normal signed/unsigned
  // op operating on the low 32 bits, sign-extended to 64 at the end)
  // ---------------------------------------------------------------------
  typedef enum logic [2:0] {
    DIV_DIV    = 3'b000,
    DIV_DIVU   = 3'b001,
    DIV_REM    = 3'b010,
    DIV_REMU   = 3'b011,
    DIV_DIVW   = 3'b100,
    DIV_DIVUW  = 3'b101,
    DIV_REMW   = 3'b110,
    DIV_REMUW  = 3'b111
  } div_op_e;

  // Writeback mux selector
  typedef enum logic [1:0] {
    WB_ALU  = 2'b00,  // ALU result
    WB_MEM  = 2'b01,  // load data from data memory
    WB_PC4  = 2'b10,  // PC + 4 (JAL / JALR link value)
    WB_MEXT = 2'b11   // RV64M multiply/divide unit result
  } wb_sel_e;

  // Branch comparator function (mirrors funct3 encoding for branches)
  typedef enum logic [2:0] {
    BR_EQ  = 3'b000,
    BR_NE  = 3'b001,
    BR_LT  = 3'b100,
    BR_GE  = 3'b101,
    BR_LTU = 3'b110,
    BR_GEU = 3'b111,
    BR_NONE = 3'b010   // not a branch instruction
  } branch_type_e;

  // Memory access width (mirrors funct3 encoding for load/store)
  typedef enum logic [2:0] {
    MEM_B  = 3'b000,
    MEM_H  = 3'b001,
    MEM_W  = 3'b010,
    MEM_D  = 3'b011,
    MEM_BU = 3'b100,
    MEM_HU = 3'b101,
    MEM_WU = 3'b110
  } mem_width_e;

  // Opcodes actually used below (RV64I base only)
  localparam logic [6:0] OP_LUI      = 7'b0110111;
  localparam logic [6:0] OP_AUIPC    = 7'b0010111;
  localparam logic [6:0] OP_JAL      = 7'b1101111;
  localparam logic [6:0] OP_JALR     = 7'b1100111;
  localparam logic [6:0] OP_BRANCH   = 7'b1100011;
  localparam logic [6:0] OP_LOAD     = 7'b0000011;
  localparam logic [6:0] OP_STORE    = 7'b0100011;
  localparam logic [6:0] OP_IMM      = 7'b0010011;
  localparam logic [6:0] OP_IMM_32   = 7'b0011011;
  localparam logic [6:0] OP_REG      = 7'b0110011;
  localparam logic [6:0] OP_REG_32   = 7'b0111011;
  localparam logic [6:0] OP_SYSTEM   = 7'b1110011;

  // funct7 pattern that marks an RV64M instruction inside OP_REG / OP_REG_32
  localparam logic [6:0] FUNCT7_MEXT = 7'b0000001;

endpackage