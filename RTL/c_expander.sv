module c_expander (
    input  logic [15:0]     instr16,

    output logic [31:0]     instr32,
    output logic            c_illegal
);

  // Compressed 3-bit register fields address x8-x15 only.
  function automatic logic [4:0] creg(logic [2:0] r);
    creg = {2'b01, r};
  endfunction

  // Standard opcodes, kept local so this module has no package dependency
  // and can be reused/unit-tested on its own.
  localparam logic [6:0] OP_LOAD   = 7'b0000011;
  localparam logic [6:0] OP_STORE  = 7'b0100011;
  localparam logic [6:0] OP_IMM    = 7'b0010011;
  localparam logic [6:0] OP_IMM32  = 7'b0011011;
  localparam logic [6:0] OP_REG    = 7'b0110011;
  localparam logic [6:0] OP_REG32  = 7'b0111011;
  localparam logic [6:0] OP_LUI    = 7'b0110111;
  localparam logic [6:0] OP_JAL    = 7'b1101111;
  localparam logic [6:0] OP_JALR   = 7'b1100111;
  localparam logic [6:0] OP_BRANCH = 7'b1100011;
  localparam logic [6:0] OP_SYSTEM = 7'b1110011;

  function automatic logic [31:0] enc_r(logic [6:0] f7, logic [4:0] rs2, logic [4:0] rs1,
                                         logic [2:0] f3, logic [4:0] rd, logic [6:0] op);
    enc_r = {f7, rs2, rs1, f3, rd, op};
  endfunction
  function automatic logic [31:0] enc_i(logic [11:0] imm, logic [4:0] rs1, logic [2:0] f3,
                                         logic [4:0] rd, logic [6:0] op);
    enc_i = {imm, rs1, f3, rd, op};
  endfunction
  function automatic logic [31:0] enc_s(logic [11:0] imm, logic [4:0] rs2, logic [4:0] rs1,
                                         logic [2:0] f3, logic [6:0] op);
    enc_s = {imm[11:5], rs2, rs1, f3, imm[4:0], op};
  endfunction
  function automatic logic [31:0] enc_b(logic [12:0] imm, logic [4:0] rs2, logic [4:0] rs1,
                                         logic [2:0] f3, logic [6:0] op);
    enc_b = {imm[12], imm[10:5], rs2, rs1, f3, imm[4:1], imm[11], op};
  endfunction
  function automatic logic [31:0] enc_u(logic [19:0] imm20, logic [4:0] rd, logic [6:0] op);
    enc_u = {imm20, rd, op};
  endfunction
  function automatic logic [31:0] enc_j(logic [20:0] imm, logic [4:0] rd, logic [6:0] op);
    enc_j = {imm[20], imm[10:1], imm[11], imm[19:12], rd, op};
  endfunction

  // Field carve-outs shared across several compressed formats.
  logic [1:0] op_q;
  logic [2:0] funct3;
  logic [4:0] rd_rs1_5;   // instr[11:7]: full 5-bit register (CI/CR/CA "wide" field)
  logic [2:0] rd_rs1_3;   // instr[9:7]:  compressed 3-bit rd'/rs1' (CIW/CL/CS/CB/CA)
  logic [4:0] rs2_5;      // instr[6:2]:  full 5-bit register (CR/CI)
  logic [2:0] rs2_3;      // instr[4:2]:  compressed 3-bit rs2' (CL/CS/CA)

  assign op_q     = instr16[1:0];
  assign funct3   = instr16[15:13];
  assign rd_rs1_5 = instr16[11:7];
  assign rd_rs1_3 = instr16[9:7];
  assign rs2_5    = instr16[6:2];
  assign rs2_3    = instr16[4:2];

  always_comb begin
    instr32   = 32'h0000_0013;   // fallback: NOP
    c_illegal = 1'b0;

    case (op_q)
      // Quadrant 0
      2'b00: begin
        case (funct3)
          3'b000: begin // C.ADDI4SPN -> addi rd', x2, nzuimm
            logic [9:0] nzuimm;
            nzuimm = {instr16[10:7], instr16[12:11], instr16[5], instr16[6], 2'b00};
            instr32 = enc_i(nzuimm[9:0], 5'd2, 3'b000, creg(rs2_3), OP_IMM);
            if (nzuimm == 10'b0) c_illegal = 1'b1;   // reserved (also catches all-zero instr16)
          end
          3'b010: begin // C.LW -> lw rd', offset(rs1')
            logic [6:0] off;
            off = {instr16[5], instr16[12:10], instr16[6], 2'b00};
            instr32 = enc_i({5'b0, off}, creg(rd_rs1_3), 3'b010, creg(rs2_3), OP_LOAD);
          end
          3'b011: begin // C.LD (RV64) -> ld rd', offset(rs1')
            logic [7:0] off;
            off = {instr16[6:5], instr16[12:10], 3'b000};
            instr32 = enc_i({4'b0, off}, creg(rd_rs1_3), 3'b011, creg(rs2_3), OP_LOAD);
          end
          3'b110: begin // C.SW -> sw rs2', offset(rs1')
            logic [6:0] off;
            off = {instr16[5], instr16[12:10], instr16[6], 2'b00};
            instr32 = enc_s({5'b0, off}, creg(rs2_3), creg(rd_rs1_3), 3'b010, OP_STORE);
          end
          3'b111: begin // C.SD (RV64) -> sd rs2', offset(rs1')
            logic [7:0] off;
            off = {instr16[6:5], instr16[12:10], 3'b000};
            instr32 = enc_s({4'b0, off}, creg(rs2_3), creg(rd_rs1_3), 3'b011, OP_STORE);
          end
          default: c_illegal = 1'b1;   // C.FLD/C.LQ/C.FSD/C.SQ: no F/D/Q support
        endcase
      end

      // Quadrant 1
      2'b01: begin
        case (funct3)
          3'b000: begin // C.NOP (rd=0) / C.ADDI (rd!=0) -> addi rd,rd,nzimm
            logic [5:0] imm6;
            imm6 = {instr16[12], instr16[6:2]};
            instr32 = enc_i({{6{imm6[5]}}, imm6}, rd_rs1_5, 3'b000, rd_rs1_5, OP_IMM);
            // rd=0,imm!=0 and rd!=0,imm=0 are both legal HINTs -- not illegal.
          end
          3'b001: begin // C.ADDIW (RV64) -> addiw rd,rd,imm (rd=x0 is reserved)
            logic [5:0] imm6;
            imm6 = {instr16[12], instr16[6:2]};
            instr32 = enc_i({{6{imm6[5]}}, imm6}, rd_rs1_5, 3'b000, rd_rs1_5, OP_IMM32);
            if (rd_rs1_5 == 5'd0) c_illegal = 1'b1;
          end
          3'b010: begin // C.LI -> addi rd, x0, imm  (rd=0 is a legal HINT)
            logic [5:0] imm6;
            imm6 = {instr16[12], instr16[6:2]};
            instr32 = enc_i({{6{imm6[5]}}, imm6}, 5'd0, 3'b000, rd_rs1_5, OP_IMM);
          end
          3'b011: begin
            if (rd_rs1_5 == 5'd2) begin // C.ADDI16SP -> addi x2,x2,nzimm
              logic [9:0] imm10;
              imm10 = {instr16[12], instr16[4:3], instr16[5], instr16[2], instr16[6], 4'b0000};
              instr32 = enc_i({{2{imm10[9]}}, imm10}, 5'd2, 3'b000, 5'd2, OP_IMM);
              if (imm10 == 10'b0) c_illegal = 1'b1;   // reserved
            end else begin              // C.LUI -> lui rd, nzimm
              logic [5:0] nzimm6;       // = nzimm[17:12]
              logic [19:0] imm20;
              nzimm6 = {instr16[12], instr16[6:2]};
              imm20  = {{14{nzimm6[5]}}, nzimm6};
              instr32 = enc_u(imm20, rd_rs1_5, OP_LUI);
              if (nzimm6 == 6'b0) c_illegal = 1'b1;  // reserved
            end
          end
          3'b100: begin // MISC-ALU
            logic [1:0] funct2a, funct2b;
            funct2a = instr16[11:10];
            funct2b = instr16[6:5];
            case (funct2a)
              2'b00: begin // C.SRLI -> srli rd',rd',shamt
                logic [5:0] shamt;
                shamt = {instr16[12], instr16[6:2]};
                instr32 = enc_i({6'b0, shamt}, creg(rd_rs1_3), 3'b101, creg(rd_rs1_3), OP_IMM);
              end
              2'b01: begin // C.SRAI -> srai rd',rd',shamt
                logic [5:0] shamt;
                shamt = {instr16[12], instr16[6:2]};
                instr32 = enc_i({6'b010000, shamt}, creg(rd_rs1_3), 3'b101, creg(rd_rs1_3), OP_IMM);
              end
              2'b10: begin // C.ANDI -> andi rd',rd',imm
                logic [5:0] imm6;
                imm6 = {instr16[12], instr16[6:2]};
                instr32 = enc_i({{6{imm6[5]}}, imm6}, creg(rd_rs1_3), 3'b111, creg(rd_rs1_3), OP_IMM);
              end
              2'b11: begin
                if (!instr16[12]) begin
                  case (funct2b)
                    2'b00: instr32 = enc_r(7'b0100000, creg(rs2_3), creg(rd_rs1_3), 3'b000, creg(rd_rs1_3), OP_REG);   // C.SUB
                    2'b01: instr32 = enc_r(7'b0000000, creg(rs2_3), creg(rd_rs1_3), 3'b100, creg(rd_rs1_3), OP_REG);   // C.XOR
                    2'b10: instr32 = enc_r(7'b0000000, creg(rs2_3), creg(rd_rs1_3), 3'b110, creg(rd_rs1_3), OP_REG);   // C.OR
                    2'b11: instr32 = enc_r(7'b0000000, creg(rs2_3), creg(rd_rs1_3), 3'b111, creg(rd_rs1_3), OP_REG);   // C.AND
                  endcase
                end else begin
                  case (funct2b)
                    2'b00: instr32 = enc_r(7'b0100000, creg(rs2_3), creg(rd_rs1_3), 3'b000, creg(rd_rs1_3), OP_REG32); // C.SUBW
                    2'b01: instr32 = enc_r(7'b0000000, creg(rs2_3), creg(rd_rs1_3), 3'b000, creg(rd_rs1_3), OP_REG32); // C.ADDW
                    default: c_illegal = 1'b1;  // reserved (no XORW/ORW/ANDW)
                  endcase
                end
              end
            endcase
          end
          3'b101: begin // C.J -> jal x0, imm
            logic [11:0] imm12;
            imm12 = {instr16[12], instr16[8], instr16[10:9], instr16[6], instr16[7],
                     instr16[2], instr16[11], instr16[5:3], 1'b0};
            instr32 = enc_j({{9{imm12[11]}}, imm12}, 5'd0, OP_JAL);
          end
          3'b110: begin // C.BEQZ -> beq rs1',x0,imm
            logic [8:0] imm9;
            imm9 = {instr16[12], instr16[6:5], instr16[2], instr16[11:10], instr16[4:3], 1'b0};
            instr32 = enc_b({{4{imm9[8]}}, imm9}, 5'd0, creg(rd_rs1_3), 3'b000, OP_BRANCH);
          end
          3'b111: begin // C.BNEZ -> bne rs1',x0,imm
            logic [8:0] imm9;
            imm9 = {instr16[12], instr16[6:5], instr16[2], instr16[11:10], instr16[4:3], 1'b0};
            instr32 = enc_b({{4{imm9[8]}}, imm9}, 5'd0, creg(rd_rs1_3), 3'b001, OP_BRANCH);
          end
        endcase
      end
      // Quadrant 2
      2'b10: begin
        case (funct3)
          3'b000: begin // C.SLLI -> slli rd,rd,shamt (rd=0 is a legal HINT)
            logic [5:0] shamt;
            shamt = {instr16[12], instr16[6:2]};
            instr32 = enc_i({6'b0, shamt}, rd_rs1_5, 3'b001, rd_rs1_5, OP_IMM);
          end
          3'b010: begin // C.LWSP -> lw rd, offset(x2)  (rd=0 is reserved)
            logic [7:0] off;
            off = {instr16[3:2], instr16[12], instr16[6:4], 2'b00};
            instr32 = enc_i({4'b0, off}, 5'd2, 3'b010, rd_rs1_5, OP_LOAD);
            if (rd_rs1_5 == 5'd0) c_illegal = 1'b1;
          end
          3'b011: begin // C.LDSP (RV64) -> ld rd, offset(x2)  (rd=0 is reserved)
            logic [8:0] off;
            off = {instr16[4:2], instr16[12], instr16[6:5], 3'b000};
            instr32 = enc_i({3'b0, off}, 5'd2, 3'b011, rd_rs1_5, OP_LOAD);
            if (rd_rs1_5 == 5'd0) c_illegal = 1'b1;
          end
          3'b100: begin
            if (!instr16[12]) begin
              if (rs2_5 == 5'd0) begin // C.JR -> jalr x0, 0(rs1) (rs1=0 reserved)
                instr32 = enc_i(12'b0, rd_rs1_5, 3'b000, 5'd0, OP_JALR);
                if (rd_rs1_5 == 5'd0) c_illegal = 1'b1;
              end else begin            // C.MV -> add rd, x0, rs2 (rd=0 is a HINT)
                instr32 = enc_r(7'b0, rs2_5, 5'd0, 3'b000, rd_rs1_5, OP_REG);
              end
            end else begin
              if (rs2_5 == 5'd0 && rd_rs1_5 == 5'd0) begin  // C.EBREAK
                instr32 = enc_i(12'h001, 5'd0, 3'b000, 5'd0, OP_SYSTEM);
              end else if (rs2_5 == 5'd0) begin             // C.JALR -> jalr x1, 0(rs1)
                instr32 = enc_i(12'b0, rd_rs1_5, 3'b000, 5'd1, OP_JALR);
              end else begin                                // C.ADD -> add rd,rd,rs2 (rd=0 is a HINT)
                instr32 = enc_r(7'b0, rs2_5, rd_rs1_5, 3'b000, rd_rs1_5, OP_REG);
              end
            end
          end
          3'b110: begin // C.SWSP -> sw rs2, offset(x2)
            logic [7:0] off;
            off = {instr16[8:7], instr16[12:9], 2'b00};
            instr32 = enc_s({4'b0, off}, rs2_5, 5'd2, 3'b010, OP_STORE);
          end
          3'b111: begin // C.SDSP (RV64) -> sd rs2, offset(x2)
            logic [8:0] off;
            off = {instr16[9:7], instr16[12:10], 3'b000};
            instr32 = enc_s({3'b0, off}, rs2_5, 5'd2, 3'b011, OP_STORE);
          end
          default: begin
            c_illegal = 1'b1;
          end
        endcase
      end
      2'b11: begin
        c_illegal = 1'b1;
      end
    endcase
  end

endmodule