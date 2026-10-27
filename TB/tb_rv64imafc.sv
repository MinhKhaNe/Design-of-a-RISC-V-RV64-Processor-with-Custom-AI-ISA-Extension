// =============================================================================
// tb_rv64imafc.sv  --  self-checking regression for rv64imafc_top
//
// Covers : RV64I, M, A, F, C, Zicsr (fcsr/frm/fflags), Zicntr, FENCE,
//          forwarding / load-use / flush / multi-cycle stall behaviour,
//          illegal-instruction + misaligned-atomic traps.
//
// How it works
//   * Programs are assembled in the TB (SV functions ADD(), LW(), ... + emit_li()),
//     back-doored into imem.mem[], the core is reset and run until the
//     instruction at the halt PC reaches EX, then registers / memory / counters
//     are compared against expected values computed by SV reference models
//     (ALU, M, branch, AMO) or by a Python exact float32 model (fp_vectors.svh).
//   * Every program ends with a jump to TRAP_ADDR (0x7F0) where a "jal x0,0"
//     parks the core.  TRAP_PC of the DUT is also 0x7F0, so an illegal
//     instruction lands in the same place -- illegal_instr_o pulses are counted
//     to tell the two apart.
//   * dmem is never written from the TB (it is driven by always_ff); all data
//     is created by the programs themselves.
//
// Files needed in the compile: the rv64imafc_* RTL (NOT the rv64i_* files),
//   fp_vectors.svh on the include path.
// =============================================================================
`timescale 1ns/1ps

module tb_rv64imafc;

  // ---------------------------------------------------------------------------
  // Parameters / DUT
  // ---------------------------------------------------------------------------
  localparam logic [63:0] TRAP_ADDR  = 64'h7F0;
  localparam int          MAX_CYCLES = 30000;
  localparam bit          VERBOSE    = 1'b0;      // 1 = print a line per passing test

  logic        clk = 1'b0;
  logic        rst_n = 1'b0;
  logic [63:0] pc_o;
  logic        stall_o, flush_o, illegal_instr_o;

  always #5 clk = ~clk;

  rv64imafc_top #(
      .RESET_PC (64'h0),
      .TRAP_PC  (TRAP_ADDR)
  ) dut (
      .clk             (clk),
      .rst_n           (rst_n),
      .pc_o            (pc_o),
      .stall_o         (stall_o),
      .flush_o         (flush_o),
      .illegal_instr_o (illegal_instr_o)
  );

  // ---------------------------------------------------------------------------
  // Observability counters (reset per program run)
  // ---------------------------------------------------------------------------
  int ill_cnt, stall_cnt, flush_cnt;

  always @(posedge clk) begin
    if (rst_n === 1'b1) begin
      if (illegal_instr_o === 1'b1) ill_cnt++;
      if (stall_o         === 1'b1) stall_cnt++;
      if (flush_o         === 1'b1) flush_cnt++;
    end
  end

  // ---------------------------------------------------------------------------
  // Bookkeeping
  // ---------------------------------------------------------------------------
  string cur_name;
  int    test_fail;
  int    n_tests, n_tests_failed, n_checks;

  task automatic start_test(input string name);
    cur_name  = name;
    test_fail = 0;
  endtask

  task automatic end_test();
    n_tests++;
    if (test_fail != 0) n_tests_failed++;
    else if (VERBOSE)   $display("[PASS] %s", cur_name);
  endtask

  task automatic check64(input string what, input logic [63:0] got, input logic [63:0] exp);
    n_checks++;
    if (got !== exp) begin
      test_fail++;
      $display("[FAIL] %s | %s : got %h  expected %h", cur_name, what, got, exp);
    end
  endtask

  // ---------------------------------------------------------------------------
  // State readers (hierarchical back-door)
  // ---------------------------------------------------------------------------
  function automatic logic [63:0] rx(input int r);
    if (r == 0) rx = 64'd0;
    else        rx = dut.regfile_inst.regs[r];
  endfunction

  function automatic logic [31:0] rfp(input int r);
    rfp = dut.fp_regfile_inst.regs[r];
  endfunction

  function automatic logic [63:0] rm64(input int addr);
    for (int i = 0; i < 8; i++) rm64[8*i +: 8] = dut.dmem_inst.mem[addr + i];
  endfunction

  function automatic logic [31:0] rm32(input int addr);
    for (int i = 0; i < 4; i++) rm32[8*i +: 8] = dut.dmem_inst.mem[addr + i];
  endfunction

  task automatic chk_x(input int r, input logic [63:0] exp);
    check64($sformatf("x%0d", r), rx(r), exp);
  endtask

  task automatic chk_f(input int r, input logic [31:0] exp);
    check64($sformatf("f%0d", r), {32'b0, rfp(r)}, {32'b0, exp});
  endtask

  task automatic chk_m64(input int addr, input logic [63:0] exp);
    check64($sformatf("mem64[0x%0h]", addr), rm64(addr), exp);
  endtask

  task automatic chk_m32(input int addr, input logic [31:0] exp);
    check64($sformatf("mem32[0x%0h]", addr), {32'b0, rm32(addr)}, {32'b0, exp});
  endtask

  task automatic chk_ill(input int n);
    check64("illegal_instr_o pulses", 64'(ill_cnt), 64'(n));
  endtask

  // ---------------------------------------------------------------------------
  // Instruction encoders
  // ---------------------------------------------------------------------------
  function automatic logic [31:0] enc_r(input logic [6:0] f7, input int rs2, input int rs1,
                                        input logic [2:0] f3, input int rd, input logic [6:0] op);
    logic [4:0] r2, r1, d;
    r2 = rs2[4:0]; r1 = rs1[4:0]; d = rd[4:0];
    enc_r = {f7, r2, r1, f3, d, op};
  endfunction

  function automatic logic [31:0] enc_i(input int imm, input int rs1, input logic [2:0] f3,
                                        input int rd, input logic [6:0] op);
    logic [11:0] i12; logic [4:0] r1, d;
    i12 = imm[11:0]; r1 = rs1[4:0]; d = rd[4:0];
    enc_i = {i12, r1, f3, d, op};
  endfunction

  function automatic logic [31:0] enc_s(input int imm, input int rs2, input int rs1,
                                        input logic [2:0] f3, input logic [6:0] op);
    logic [11:0] i12; logic [4:0] r1, r2;
    i12 = imm[11:0]; r1 = rs1[4:0]; r2 = rs2[4:0];
    enc_s = {i12[11:5], r2, r1, f3, i12[4:0], op};
  endfunction

  function automatic logic [31:0] enc_b(input int off, input int rs2, input int rs1,
                                        input logic [2:0] f3);
    logic [12:0] o; logic [4:0] r1, r2;
    o = off[12:0]; r1 = rs1[4:0]; r2 = rs2[4:0];
    enc_b = {o[12], o[10:5], r2, r1, f3, o[4:1], o[11], 7'b1100011};
  endfunction

  function automatic logic [31:0] enc_u(input int imm20, input int rd, input logic [6:0] op);
    logic [19:0] i20; logic [4:0] d;
    i20 = imm20[19:0]; d = rd[4:0];
    enc_u = {i20, d, op};
  endfunction

  function automatic logic [31:0] enc_j(input int off, input int rd);
    logic [20:0] o; logic [4:0] d;
    o = off[20:0]; d = rd[4:0];
    enc_j = {o[20], o[10:1], o[11], o[19:12], d, 7'b1101111};
  endfunction

  // ---- RV64I register-register -------------------------------------------------
  function automatic logic [31:0] ADD  (input int rd, rs1, rs2); ADD   = enc_r(7'h00, rs2, rs1, 3'b000, rd, 7'h33); endfunction
  function automatic logic [31:0] SUB  (input int rd, rs1, rs2); SUB   = enc_r(7'h20, rs2, rs1, 3'b000, rd, 7'h33); endfunction
  function automatic logic [31:0] SLL  (input int rd, rs1, rs2); SLL   = enc_r(7'h00, rs2, rs1, 3'b001, rd, 7'h33); endfunction
  function automatic logic [31:0] SLT  (input int rd, rs1, rs2); SLT   = enc_r(7'h00, rs2, rs1, 3'b010, rd, 7'h33); endfunction
  function automatic logic [31:0] SLTU (input int rd, rs1, rs2); SLTU  = enc_r(7'h00, rs2, rs1, 3'b011, rd, 7'h33); endfunction
  function automatic logic [31:0] XOR  (input int rd, rs1, rs2); XOR   = enc_r(7'h00, rs2, rs1, 3'b100, rd, 7'h33); endfunction
  function automatic logic [31:0] SRL  (input int rd, rs1, rs2); SRL   = enc_r(7'h00, rs2, rs1, 3'b101, rd, 7'h33); endfunction
  function automatic logic [31:0] SRA  (input int rd, rs1, rs2); SRA   = enc_r(7'h20, rs2, rs1, 3'b101, rd, 7'h33); endfunction
  function automatic logic [31:0] OR   (input int rd, rs1, rs2); OR    = enc_r(7'h00, rs2, rs1, 3'b110, rd, 7'h33); endfunction
  function automatic logic [31:0] AND  (input int rd, rs1, rs2); AND   = enc_r(7'h00, rs2, rs1, 3'b111, rd, 7'h33); endfunction
  function automatic logic [31:0] ADDW (input int rd, rs1, rs2); ADDW  = enc_r(7'h00, rs2, rs1, 3'b000, rd, 7'h3B); endfunction
  function automatic logic [31:0] SUBW (input int rd, rs1, rs2); SUBW  = enc_r(7'h20, rs2, rs1, 3'b000, rd, 7'h3B); endfunction
  function automatic logic [31:0] SLLW (input int rd, rs1, rs2); SLLW  = enc_r(7'h00, rs2, rs1, 3'b001, rd, 7'h3B); endfunction
  function automatic logic [31:0] SRLW (input int rd, rs1, rs2); SRLW  = enc_r(7'h00, rs2, rs1, 3'b101, rd, 7'h3B); endfunction
  function automatic logic [31:0] SRAW (input int rd, rs1, rs2); SRAW  = enc_r(7'h20, rs2, rs1, 3'b101, rd, 7'h3B); endfunction

  // ---- RV64M ----------------------------------------------------------------------
  function automatic logic [31:0] MUL   (input int rd, rs1, rs2); MUL    = enc_r(7'h01, rs2, rs1, 3'b000, rd, 7'h33); endfunction
  function automatic logic [31:0] MULH  (input int rd, rs1, rs2); MULH   = enc_r(7'h01, rs2, rs1, 3'b001, rd, 7'h33); endfunction
  function automatic logic [31:0] MULHSU(input int rd, rs1, rs2); MULHSU = enc_r(7'h01, rs2, rs1, 3'b010, rd, 7'h33); endfunction
  function automatic logic [31:0] MULHU (input int rd, rs1, rs2); MULHU  = enc_r(7'h01, rs2, rs1, 3'b011, rd, 7'h33); endfunction
  function automatic logic [31:0] DIV   (input int rd, rs1, rs2); DIV    = enc_r(7'h01, rs2, rs1, 3'b100, rd, 7'h33); endfunction
  function automatic logic [31:0] DIVU  (input int rd, rs1, rs2); DIVU   = enc_r(7'h01, rs2, rs1, 3'b101, rd, 7'h33); endfunction
  function automatic logic [31:0] REM   (input int rd, rs1, rs2); REM    = enc_r(7'h01, rs2, rs1, 3'b110, rd, 7'h33); endfunction
  function automatic logic [31:0] REMU  (input int rd, rs1, rs2); REMU   = enc_r(7'h01, rs2, rs1, 3'b111, rd, 7'h33); endfunction
  function automatic logic [31:0] MULW  (input int rd, rs1, rs2); MULW   = enc_r(7'h01, rs2, rs1, 3'b000, rd, 7'h3B); endfunction
  function automatic logic [31:0] DIVW  (input int rd, rs1, rs2); DIVW   = enc_r(7'h01, rs2, rs1, 3'b100, rd, 7'h3B); endfunction
  function automatic logic [31:0] DIVUW (input int rd, rs1, rs2); DIVUW  = enc_r(7'h01, rs2, rs1, 3'b101, rd, 7'h3B); endfunction
  function automatic logic [31:0] REMW  (input int rd, rs1, rs2); REMW   = enc_r(7'h01, rs2, rs1, 3'b110, rd, 7'h3B); endfunction
  function automatic logic [31:0] REMUW (input int rd, rs1, rs2); REMUW  = enc_r(7'h01, rs2, rs1, 3'b111, rd, 7'h3B); endfunction

  // ---- immediates -------------------------------------------------------------------
  function automatic logic [31:0] ADDI  (input int rd, rs1, imm); ADDI  = enc_i(imm, rs1, 3'b000, rd, 7'h13); endfunction
  function automatic logic [31:0] SLTI  (input int rd, rs1, imm); SLTI  = enc_i(imm, rs1, 3'b010, rd, 7'h13); endfunction
  function automatic logic [31:0] SLTIU (input int rd, rs1, imm); SLTIU = enc_i(imm, rs1, 3'b011, rd, 7'h13); endfunction
  function automatic logic [31:0] XORI  (input int rd, rs1, imm); XORI  = enc_i(imm, rs1, 3'b100, rd, 7'h13); endfunction
  function automatic logic [31:0] ORI   (input int rd, rs1, imm); ORI   = enc_i(imm, rs1, 3'b110, rd, 7'h13); endfunction
  function automatic logic [31:0] ANDI  (input int rd, rs1, imm); ANDI  = enc_i(imm, rs1, 3'b111, rd, 7'h13); endfunction
  function automatic logic [31:0] SLLI  (input int rd, rs1, sh);  SLLI  = enc_i(sh & 63,          rs1, 3'b001, rd, 7'h13); endfunction
  function automatic logic [31:0] SRLI  (input int rd, rs1, sh);  SRLI  = enc_i(sh & 63,          rs1, 3'b101, rd, 7'h13); endfunction
  function automatic logic [31:0] SRAI  (input int rd, rs1, sh);  SRAI  = enc_i(12'h400 | (sh&63), rs1, 3'b101, rd, 7'h13); endfunction
  function automatic logic [31:0] ADDIW (input int rd, rs1, imm); ADDIW = enc_i(imm, rs1, 3'b000, rd, 7'h1B); endfunction
  function automatic logic [31:0] SLLIW (input int rd, rs1, sh);  SLLIW = enc_i(sh & 31,          rs1, 3'b001, rd, 7'h1B); endfunction
  function automatic logic [31:0] SRLIW (input int rd, rs1, sh);  SRLIW = enc_i(sh & 31,          rs1, 3'b101, rd, 7'h1B); endfunction
  function automatic logic [31:0] SRAIW (input int rd, rs1, sh);  SRAIW = enc_i(12'h400 | (sh&31), rs1, 3'b101, rd, 7'h1B); endfunction
  function automatic logic [31:0] NOP   ();                       NOP   = enc_i(0, 0, 3'b000, 0, 7'h13); endfunction

  function automatic logic [31:0] LUI   (input int rd, imm20);    LUI   = enc_u(imm20, rd, 7'h37); endfunction
  function automatic logic [31:0] AUIPC (input int rd, imm20);    AUIPC = enc_u(imm20, rd, 7'h17); endfunction
  function automatic logic [31:0] JAL   (input int rd, off);      JAL   = enc_j(off, rd); endfunction
  function automatic logic [31:0] JALR  (input int rd, rs1, imm); JALR  = enc_i(imm, rs1, 3'b000, rd, 7'h67); endfunction

  // ---- loads / stores : (reg, base, offset) -----------------------------------------
  function automatic logic [31:0] LB  (input int rd, rs1, imm); LB  = enc_i(imm, rs1, 3'b000, rd, 7'h03); endfunction
  function automatic logic [31:0] LH  (input int rd, rs1, imm); LH  = enc_i(imm, rs1, 3'b001, rd, 7'h03); endfunction
  function automatic logic [31:0] LW  (input int rd, rs1, imm); LW  = enc_i(imm, rs1, 3'b010, rd, 7'h03); endfunction
  function automatic logic [31:0] LD  (input int rd, rs1, imm); LD  = enc_i(imm, rs1, 3'b011, rd, 7'h03); endfunction
  function automatic logic [31:0] LBU (input int rd, rs1, imm); LBU = enc_i(imm, rs1, 3'b100, rd, 7'h03); endfunction
  function automatic logic [31:0] LHU (input int rd, rs1, imm); LHU = enc_i(imm, rs1, 3'b101, rd, 7'h03); endfunction
  function automatic logic [31:0] LWU (input int rd, rs1, imm); LWU = enc_i(imm, rs1, 3'b110, rd, 7'h03); endfunction
  function automatic logic [31:0] SB  (input int rs2, rs1, imm); SB  = enc_s(imm, rs2, rs1, 3'b000, 7'h23); endfunction
  function automatic logic [31:0] SH  (input int rs2, rs1, imm); SH  = enc_s(imm, rs2, rs1, 3'b001, 7'h23); endfunction
  function automatic logic [31:0] SW  (input int rs2, rs1, imm); SW  = enc_s(imm, rs2, rs1, 3'b010, 7'h23); endfunction
  function automatic logic [31:0] SD  (input int rs2, rs1, imm); SD  = enc_s(imm, rs2, rs1, 3'b011, 7'h23); endfunction
  function automatic logic [31:0] FLW (input int fd,  rs1, imm); FLW = enc_i(imm, rs1, 3'b010, fd, 7'h07); endfunction
  function automatic logic [31:0] FSW (input int fs2, rs1, imm); FSW = enc_s(imm, fs2, rs1, 3'b010, 7'h27); endfunction

  // ---- branches : (rs1, rs2, byte offset) ------------------------------------------------
  function automatic logic [31:0] BEQ  (input int rs1, rs2, off); BEQ  = enc_b(off, rs2, rs1, 3'b000); endfunction
  function automatic logic [31:0] BNE  (input int rs1, rs2, off); BNE  = enc_b(off, rs2, rs1, 3'b001); endfunction
  function automatic logic [31:0] BLT  (input int rs1, rs2, off); BLT  = enc_b(off, rs2, rs1, 3'b100); endfunction
  function automatic logic [31:0] BGE  (input int rs1, rs2, off); BGE  = enc_b(off, rs2, rs1, 3'b101); endfunction
  function automatic logic [31:0] BLTU (input int rs1, rs2, off); BLTU = enc_b(off, rs2, rs1, 3'b110); endfunction
  function automatic logic [31:0] BGEU (input int rs1, rs2, off); BGEU = enc_b(off, rs2, rs1, 3'b111); endfunction

  function automatic logic [31:0] enc_br(input int tp, input int rs1, input int rs2, input int off);
    case (tp)
      0: enc_br = BEQ (rs1, rs2, off);
      1: enc_br = BNE (rs1, rs2, off);
      2: enc_br = BLT (rs1, rs2, off);
      3: enc_br = BGE (rs1, rs2, off);
      4: enc_br = BLTU(rs1, rs2, off);
      default: enc_br = BGEU(rs1, rs2, off);
    endcase
  endfunction

  // ---- system / CSR / fence -----------------------------------------------------------------
  function automatic logic [31:0] CSRRW  (input int rd, csr, rs1);  CSRRW  = enc_i(csr, rs1, 3'b001, rd, 7'h73); endfunction
  function automatic logic [31:0] CSRRS  (input int rd, csr, rs1);  CSRRS  = enc_i(csr, rs1, 3'b010, rd, 7'h73); endfunction
  function automatic logic [31:0] CSRRC  (input int rd, csr, rs1);  CSRRC  = enc_i(csr, rs1, 3'b011, rd, 7'h73); endfunction
  function automatic logic [31:0] CSRRWI (input int rd, csr, zimm); CSRRWI = enc_i(csr, zimm, 3'b101, rd, 7'h73); endfunction
  function automatic logic [31:0] CSRRSI (input int rd, csr, zimm); CSRRSI = enc_i(csr, zimm, 3'b110, rd, 7'h73); endfunction
  function automatic logic [31:0] CSRRCI (input int rd, csr, zimm); CSRRCI = enc_i(csr, zimm, 3'b111, rd, 7'h73); endfunction
  function automatic logic [31:0] FENCE  (); FENCE  = enc_i(0, 0, 3'b000, 0, 7'h0F); endfunction
  function automatic logic [31:0] FENCEI (); FENCEI = enc_i(0, 0, 3'b001, 0, 7'h0F); endfunction

  // ---- RV64A ------------------------------------------------------------------------------------
  function automatic logic [31:0] AMO(input logic [4:0] f5, input int dw, input int rd, rs1, rs2);
    logic [4:0] r2, r1, d;
    r2 = rs2[4:0]; r1 = rs1[4:0]; d = rd[4:0];
    AMO = {f5, 2'b00, r2, r1, (dw != 0) ? 3'b011 : 3'b010, d, 7'h2F};
  endfunction
  function automatic logic [31:0] LRX(input int rd, rs1, dw);       LRX = AMO(5'b00010, dw, rd, rs1, 0);   endfunction
  function automatic logic [31:0] SCX(input int rd, rs1, rs2, dw);  SCX = AMO(5'b00011, dw, rd, rs1, rs2); endfunction

  // ---- RV64F : generic encoder ---------------------------------------------------------------
  localparam int OP_FADD=0,  OP_FSUB=1,  OP_FMUL=2,  OP_FDIV=3,  OP_FSQRT=4,
                 OP_FSGNJ=5, OP_FSGNJN=6, OP_FSGNJX=7, OP_FMIN=8, OP_FMAX=9,
                 OP_FCVT_W_S=10, OP_FCVT_WU_S=11, OP_FCVT_L_S=12, OP_FCVT_LU_S=13,
                 OP_FMV_X_W=14, OP_FCLASS=15, OP_FEQ=16, OP_FLT=17, OP_FLE=18,
                 OP_FCVT_S_W=19, OP_FCVT_S_WU=20, OP_FCVT_S_L=21, OP_FCVT_S_LU=22,
                 OP_FMV_W_X=23, OP_FMADD=24, OP_FMSUB=25, OP_FNMSUB=26, OP_FNMADD=27;

  function automatic logic [31:0] enc_fp(input int op, input int rd, input int rs1,
                                         input int rs2, input int rs3, input int rm);
    logic [2:0] f3; logic [6:0] f7; int r2; logic [6:0] opc;
    f3 = rm[2:0]; r2 = rs2; f7 = 7'b0;
    if (op >= OP_FMADD) begin
      case (op)
        OP_FMADD:  opc = 7'h43;
        OP_FMSUB:  opc = 7'h47;
        OP_FNMSUB: opc = 7'h4B;
        default:   opc = 7'h4F;
      endcase
      enc_fp = {rs3[4:0], 2'b00, rs2[4:0], rs1[4:0], f3, rd[4:0], opc};
    end else begin
      case (op)
        OP_FADD:      f7 = 7'b0000000;
        OP_FSUB:      f7 = 7'b0000100;
        OP_FMUL:      f7 = 7'b0001000;
        OP_FDIV:      f7 = 7'b0001100;
        OP_FSQRT:     begin f7 = 7'b0101100; r2 = 0; end
        OP_FSGNJ:     begin f7 = 7'b0010000; f3 = 3'b000; end
        OP_FSGNJN:    begin f7 = 7'b0010000; f3 = 3'b001; end
        OP_FSGNJX:    begin f7 = 7'b0010000; f3 = 3'b010; end
        OP_FMIN:      begin f7 = 7'b0010100; f3 = 3'b000; end
        OP_FMAX:      begin f7 = 7'b0010100; f3 = 3'b001; end
        OP_FCVT_W_S:  begin f7 = 7'b1100000; r2 = 0; end
        OP_FCVT_WU_S: begin f7 = 7'b1100000; r2 = 1; end
        OP_FCVT_L_S:  begin f7 = 7'b1100000; r2 = 2; end
        OP_FCVT_LU_S: begin f7 = 7'b1100000; r2 = 3; end
        OP_FMV_X_W:   begin f7 = 7'b1110000; r2 = 0; f3 = 3'b000; end
        OP_FCLASS:    begin f7 = 7'b1110000; r2 = 0; f3 = 3'b001; end
        OP_FEQ:       begin f7 = 7'b1010000; f3 = 3'b010; end
        OP_FLT:       begin f7 = 7'b1010000; f3 = 3'b001; end
        OP_FLE:       begin f7 = 7'b1010000; f3 = 3'b000; end
        OP_FCVT_S_W:  begin f7 = 7'b1101000; r2 = 0; end
        OP_FCVT_S_WU: begin f7 = 7'b1101000; r2 = 1; end
        OP_FCVT_S_L:  begin f7 = 7'b1101000; r2 = 2; end
        OP_FCVT_S_LU: begin f7 = 7'b1101000; r2 = 3; end
        OP_FMV_W_X:   begin f7 = 7'b1111000; r2 = 0; f3 = 3'b000; end
        default: ;
      endcase
      enc_fp = enc_r(f7, r2, rs1, f3, rd, 7'h53);
    end
  endfunction

  function automatic bit a_is_int(input int op);
    a_is_int = (op == OP_FCVT_S_W) || (op == OP_FCVT_S_WU) || (op == OP_FCVT_S_L) ||
               (op == OP_FCVT_S_LU) || (op == OP_FMV_W_X);
  endfunction
  function automatic bit uses_b(input int op);
    case (op)
      OP_FADD, OP_FSUB, OP_FMUL, OP_FDIV, OP_FSGNJ, OP_FSGNJN, OP_FSGNJX, OP_FMIN, OP_FMAX,
      OP_FEQ, OP_FLT, OP_FLE, OP_FMADD, OP_FMSUB, OP_FNMSUB, OP_FNMADD: uses_b = 1'b1;
      default: uses_b = 1'b0;
    endcase
  endfunction
  function automatic bit uses_c(input int op);
    uses_c = (op >= OP_FMADD);
  endfunction
  function automatic bit dest_is_int(input int op);
    case (op)
      OP_FCVT_W_S, OP_FCVT_WU_S, OP_FCVT_L_S, OP_FCVT_LU_S, OP_FMV_X_W, OP_FCLASS,
      OP_FEQ, OP_FLT, OP_FLE: dest_is_int = 1'b1;
      default: dest_is_int = 1'b0;
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Tiny assembler
  // ---------------------------------------------------------------------------
  logic [15:0] prog [0:2047];
  int          ip;                       // next free 16-bit parcel

  function automatic int pcb();          // current byte address
    pcb = ip * 2;
  endfunction

  task automatic begin_prog();
    ip = 0;
    for (int i = 0; i < 2048; i++) prog[i] = 16'h0000;
  endtask

  task automatic e(input logic [31:0] w);
    if (ip >= (int'(TRAP_ADDR) / 2) - 2) begin
      $display("TB ERROR: program overflows into the trap handler (test '%s')", cur_name);
      $fatal(1);
    end
    prog[ip]   = w[15:0];
    prog[ip+1] = w[31:16];
    ip += 2;
  endtask

  task automatic ec(input logic [15:0] h);
    prog[ip] = h;
    ip += 1;
  endtask

  task automatic e_end();
    e(JAL(0, int'(TRAP_ADDR) - 2*ip));
  endtask

  // load a full 64-bit constant (lui/addiw/slli/addi sequence)
  task automatic emit_li(input int rd, input logic [63:0] v);
    logic signed [63:0] sv, lo12, hi;
    sv = v;
    if (sv >= -64'sd2048 && sv <= 64'sd2047) begin
      e(ADDI(rd, 0, int'(sv)));
    end else if (sv >= -64'sd2147483648 && sv <= 64'sd2147483647) begin
      lo12 = {{52{sv[11]}}, sv[11:0]};
      hi   = (sv - lo12) >>> 12;
      e(LUI(rd, int'(hi[19:0])));
      if (lo12 != 0) e(ADDIW(rd, rd, int'(lo12)));
    end else begin
      lo12 = {{52{sv[11]}}, sv[11:0]};
      hi   = (sv - lo12) >>> 12;
      emit_li(rd, hi);
      e(SLLI(rd, rd, 12));
      if (lo12 != 0) e(ADDI(rd, rd, int'(lo12)));
    end
  endtask

  function automatic logic [63:0] sext32(input logic [31:0] x);
    sext32 = {{32{x[31]}}, x};
  endfunction

  // ---------------------------------------------------------------------------
  // Program loader / runner
  // ---------------------------------------------------------------------------
  task automatic load_imem();
    for (int i = 0; i < 2048; i++) dut.imem_inst.mem[i] = prog[i];
    dut.imem_inst.mem[int'(TRAP_ADDR) / 2]     = 16'h006F;   // jal x0, 0  (park)
    dut.imem_inst.mem[int'(TRAP_ADDR) / 2 + 1] = 16'h0000;
  endtask

  task automatic run_prog(input bit do_load = 1'b1, input logic [63:0] hpc = TRAP_ADDR);
    int cyc;
    bit halted;
    rst_n = 1'b0;
    @(negedge clk);
    if (do_load) load_imem();
    ill_cnt = 0; stall_cnt = 0; flush_cnt = 0;
    repeat (2) @(negedge clk);
    rst_n = 1'b1;
    halted = 1'b0;
    cyc    = 0;
    while (!halted && cyc < MAX_CYCLES) begin
      @(posedge clk);
      cyc++;
      if (dut.idex_valid === 1'b1 && dut.idex_pc === hpc) halted = 1'b1;
    end
    if (!halted) begin
      test_fail++;
      $display("[FAIL] %s | TIMEOUT after %0d cycles (pc=%h)", cur_name, cyc, pc_o);
    end
    repeat (10) @(posedge clk);          // drain MEM/WB
  endtask

  // ---------------------------------------------------------------------------
  // Reference models
  // ---------------------------------------------------------------------------
  localparam int O_ADD=0, O_SUB=1, O_SLL=2, O_SLT=3, O_SLTU=4, O_XOR=5, O_SRL=6, O_SRA=7,
                 O_OR=8, O_AND=9, O_ADDW=10, O_SUBW=11, O_SLLW=12, O_SRLW=13, O_SRAW=14;

  function automatic logic [63:0] ref_alu(input int op, input logic [63:0] a, input logic [63:0] b);
    logic [31:0] a32, b32, r32;
    a32 = a[31:0]; b32 = b[31:0]; r32 = 32'b0;
    case (op)
      O_ADD:  ref_alu = a + b;
      O_SUB:  ref_alu = a - b;
      O_SLL:  ref_alu = a << b[5:0];
      O_SLT:  ref_alu = {63'b0, ($signed(a) < $signed(b))};
      O_SLTU: ref_alu = {63'b0, (a < b)};
      O_XOR:  ref_alu = a ^ b;
      O_SRL:  ref_alu = a >> b[5:0];
      O_SRA:  ref_alu = $signed(a) >>> b[5:0];
      O_OR:   ref_alu = a | b;
      O_AND:  ref_alu = a & b;
      O_ADDW: begin r32 = a32 + b32;                  ref_alu = {{32{r32[31]}}, r32}; end
      O_SUBW: begin r32 = a32 - b32;                  ref_alu = {{32{r32[31]}}, r32}; end
      O_SLLW: begin r32 = a32 << b[4:0];              ref_alu = {{32{r32[31]}}, r32}; end
      O_SRLW: begin r32 = a32 >> b[4:0];              ref_alu = {{32{r32[31]}}, r32}; end
      O_SRAW: begin r32 = $signed(a32) >>> b[4:0];    ref_alu = {{32{r32[31]}}, r32}; end
      default: ref_alu = 64'b0;
    endcase
  endfunction

  function automatic logic [31:0] enc_alu_r(input int op, input int rd, input int rs1, input int rs2);
    case (op)
      O_ADD:  enc_alu_r = ADD (rd, rs1, rs2);
      O_SUB:  enc_alu_r = SUB (rd, rs1, rs2);
      O_SLL:  enc_alu_r = SLL (rd, rs1, rs2);
      O_SLT:  enc_alu_r = SLT (rd, rs1, rs2);
      O_SLTU: enc_alu_r = SLTU(rd, rs1, rs2);
      O_XOR:  enc_alu_r = XOR (rd, rs1, rs2);
      O_SRL:  enc_alu_r = SRL (rd, rs1, rs2);
      O_SRA:  enc_alu_r = SRA (rd, rs1, rs2);
      O_OR:   enc_alu_r = OR  (rd, rs1, rs2);
      O_AND:  enc_alu_r = AND (rd, rs1, rs2);
      O_ADDW: enc_alu_r = ADDW(rd, rs1, rs2);
      O_SUBW: enc_alu_r = SUBW(rd, rs1, rs2);
      O_SLLW: enc_alu_r = SLLW(rd, rs1, rs2);
      O_SRLW: enc_alu_r = SRLW(rd, rs1, rs2);
      default:enc_alu_r = SRAW(rd, rs1, rs2);
    endcase
  endfunction

  localparam int M_MUL=0, M_MULH=1, M_MULHSU=2, M_MULHU=3, M_DIV=4, M_DIVU=5, M_REM=6, M_REMU=7,
                 M_MULW=8, M_DIVW=9, M_DIVUW=10, M_REMW=11, M_REMUW=12;

  function automatic logic [31:0] enc_m(input int op, input int rd, input int rs1, input int rs2);
    case (op)
      M_MUL:    enc_m = MUL   (rd, rs1, rs2);
      M_MULH:   enc_m = MULH  (rd, rs1, rs2);
      M_MULHSU: enc_m = MULHSU(rd, rs1, rs2);
      M_MULHU:  enc_m = MULHU (rd, rs1, rs2);
      M_DIV:    enc_m = DIV   (rd, rs1, rs2);
      M_DIVU:   enc_m = DIVU  (rd, rs1, rs2);
      M_REM:    enc_m = REM   (rd, rs1, rs2);
      M_REMU:   enc_m = REMU  (rd, rs1, rs2);
      M_MULW:   enc_m = MULW  (rd, rs1, rs2);
      M_DIVW:   enc_m = DIVW  (rd, rs1, rs2);
      M_DIVUW:  enc_m = DIVUW (rd, rs1, rs2);
      M_REMW:   enc_m = REMW  (rd, rs1, rs2);
      default:  enc_m = REMUW (rd, rs1, rs2);
    endcase
  endfunction

  function automatic logic [63:0] ref_m(input int op, input logic [63:0] a, input logic [63:0] b);
    logic signed [127:0] sa, sb, sp;
    logic        [127:0] up;
    logic signed [63:0]  da, db;
    logic signed [31:0]  wa, wb, wq;
    logic        [31:0]  ua, ub, r32;
    da = a; db = b; wa = a[31:0]; wb = b[31:0]; ua = a[31:0]; ub = b[31:0];
    sa = {{64{a[63]}}, a};
    sb = {{64{b[63]}}, b};
    sp = 128'sd0; up = 128'd0; wq = 32'sd0; r32 = 32'd0;
    case (op)
      M_MUL:    ref_m = a * b;
      M_MULH:   begin sp = sa * sb;                          ref_m = sp[127:64]; end
      M_MULHSU: begin sp = sa * $signed({64'b0, b});         ref_m = sp[127:64]; end
      M_MULHU:  begin up = {64'b0, a} * {64'b0, b};          ref_m = up[127:64]; end
      M_DIV: begin
        if (b == 64'd0)                                   ref_m = '1;
        else if (a == 64'h8000_0000_0000_0000 && b == '1) ref_m = a;
        else                                              ref_m = da / db;
      end
      M_DIVU: ref_m = (b == 64'd0) ? '1 : (a / b);
      M_REM: begin
        if (b == 64'd0)                                   ref_m = a;
        else if (a == 64'h8000_0000_0000_0000 && b == '1) ref_m = 64'd0;
        else                                              ref_m = da % db;
      end
      M_REMU: ref_m = (b == 64'd0) ? a : (a % b);
      M_MULW: begin r32 = ua * ub; ref_m = {{32{r32[31]}}, r32}; end
      M_DIVW: begin
        if (ub == 32'd0)                                   ref_m = '1;
        else if (wa == 32'sh8000_0000 && wb == -32'sd1)    ref_m = {{32{ua[31]}}, ua};
        else begin wq = wa / wb;                           ref_m = {{32{wq[31]}}, wq}; end
      end
      M_DIVUW: begin
        if (ub == 32'd0) ref_m = '1;
        else begin r32 = ua / ub; ref_m = {{32{r32[31]}}, r32}; end
      end
      M_REMW: begin
        if (ub == 32'd0)                                   ref_m = {{32{ua[31]}}, ua};
        else if (wa == 32'sh8000_0000 && wb == -32'sd1)    ref_m = 64'd0;
        else begin wq = wa % wb;                           ref_m = {{32{wq[31]}}, wq}; end
      end
      default: begin   // M_REMUW
        if (ub == 32'd0) ref_m = {{32{ua[31]}}, ua};
        else begin r32 = ua % ub; ref_m = {{32{r32[31]}}, r32}; end
      end
    endcase
  endfunction

  function automatic bit ref_br(input int tp, input logic [63:0] a, input logic [63:0] b);
    case (tp)
      0: ref_br = (a == b);
      1: ref_br = (a != b);
      2: ref_br = ($signed(a) <  $signed(b));
      3: ref_br = ($signed(a) >= $signed(b));
      4: ref_br = (a <  b);
      default: ref_br = (a >= b);
    endcase
  endfunction

  // AMO reference: returns {rd_value, new_mem64} through two calls
  function automatic logic [63:0] ref_amo_new(input int k, input int dw, input logic [63:0] old, input logic [63:0] src);
    logic [63:0] o, s, n;
    o = (dw != 0) ? old : {{32{old[31]}}, old[31:0]};
    s = (dw != 0) ? src : {{32{src[31]}}, src[31:0]};
    case (k)
      0: n = s;                                   // SWAP
      1: n = o + s;                               // ADD
      2: n = o ^ s;                               // XOR
      3: n = o & s;                               // AND
      4: n = o | s;                               // OR
      5: n = ($signed(o) < $signed(s)) ? o : s;   // MIN
      6: n = ($signed(o) > $signed(s)) ? o : s;   // MAX
      7: n = (o < s) ? o : s;                     // MINU
      default: n = (o > s) ? o : s;               // MAXU
    endcase
    if (dw != 0) ref_amo_new = n;
    else         ref_amo_new = {old[63:32], n[31:0]};
  endfunction

  function automatic logic [4:0] amo_f5(input int k);
    case (k)
      0: amo_f5 = 5'b00001;   // swap
      1: amo_f5 = 5'b00000;   // add
      2: amo_f5 = 5'b00100;   // xor
      3: amo_f5 = 5'b01100;   // and
      4: amo_f5 = 5'b01000;   // or
      5: amo_f5 = 5'b10000;   // min
      6: amo_f5 = 5'b10100;   // max
      7: amo_f5 = 5'b11000;   // minu
      default: amo_f5 = 5'b11100;   // maxu
    endcase
  endfunction

  // operand pools -----------------------------------------------------------------------------
  localparam int NV = 12;
  function automatic logic [63:0] vval(input int i);
    case (i)
      0:  vval = 64'h0000_0000_0000_0000;
      1:  vval = 64'h0000_0000_0000_0001;
      2:  vval = 64'hFFFF_FFFF_FFFF_FFFF;
      3:  vval = 64'h0000_0000_0000_0002;
      4:  vval = 64'h7FFF_FFFF_FFFF_FFFF;
      5:  vval = 64'h8000_0000_0000_0000;
      6:  vval = 64'h0000_0000_FFFF_FFFF;
      7:  vval = 64'h0000_0000_8000_0000;
      8:  vval = 64'hFFFF_FFFF_8000_0000;
      9:  vval = 64'h1234_5678_9ABC_DEF0;
      10: vval = 64'hDEAD_BEEF_CAFE_F00D;
      default: vval = 64'h0000_0000_0000_003F;
    endcase
  endfunction

  function automatic int imm_arith(input int k);
    case (k) 0: imm_arith = 0; 1: imm_arith = 1; 2: imm_arith = -1; 3: imm_arith = 2047;
             4: imm_arith = -2048; default: imm_arith = 12'h5A5; endcase
  endfunction
  function automatic int shamt64(input int k);
    case (k) 0: shamt64 = 0; 1: shamt64 = 1; 2: shamt64 = 13; 3: shamt64 = 31;
             4: shamt64 = 32; default: shamt64 = 63; endcase
  endfunction
  function automatic int shamt32(input int k);
    case (k) 0: shamt32 = 0; 1: shamt32 = 1; 2: shamt32 = 13; 3: shamt32 = 31;
             4: shamt32 = 16; default: shamt32 = 30; endcase
  endfunction

  function automatic logic [63:0] sext_i(input int imm);
    sext_i = {{32{imm[31]}}, imm[31:0]};
  endfunction

  // ===========================================================================
  // TESTS
  // ===========================================================================

  // ---- T0: existing C-extension program that lives in imem.sv ------------------------------
  task automatic t_c_default();
    start_test("C ext: default program in imem.sv");
    run_prog(1'b0, 64'hA4);
    chk_x(1,  64'h6E);   chk_x(2,  64'h120);  chk_x(3,  64'hB0);   chk_x(4,  64'h1000);
    chk_x(5,  64'hFFFF_FFFF_FFFF_F000);
    chk_x(6,  64'h0);    chk_x(7,  64'h0);    chk_x(8,  64'h0);    chk_x(9,  64'h3);
    chk_x(10, 64'h2A);   chk_x(11, 64'h15);   chk_x(12, 64'hFFFF_FFFF_FFFF_FFFF);
    chk_x(13, 64'hFFFF_FFFF_FFFF_FFFE);       chk_x(14, 64'h15);
    chk_x(15, 64'hFFFF_FFFF_FFFF_FFFE);       chk_x(16, 64'h124);  chk_x(17, 64'h1);
    chk_x(18, 64'h0);    chk_x(19, 64'h7);    chk_x(20, 64'h0);    chk_x(21, 64'h0);
    chk_x(22, 64'h9);    chk_x(23, 64'h0);    chk_x(24, 64'h72);   chk_x(25, 64'h6E);
    chk_x(26, 64'h7E);   chk_x(27, 64'h0);    chk_x(28, 64'h3);    chk_x(29, 64'd36);
    chk_x(30, 64'd18);   chk_x(31, 64'd21);
    chk_m64(32'h128, 64'h15);
    chk_m32(32'h138, 32'h15);
    chk_m32(32'h140, 32'hFFFF_FFFE);
    chk_ill(0);
    end_test();
  endtask

  // ---- RV64I register-register ALU + RV64M, table driven over operand pairs --------------
  task automatic t_alu_m_pairs();
    for (int i = 0; i < NV; i++) begin
      for (int j = 0; j < NV; j++) begin
        start_test($sformatf("ALU+M a=%h b=%h", vval(i), vval(j)));
        begin_prog();
        emit_li(1, vval(i));
        emit_li(2, vval(j));
        for (int k = 0; k < 15; k++) e(enc_alu_r(k, 3 + k, 1, 2));     // x3..x17
        for (int m = 0; m < 13; m++) e(enc_m(m, 18 + m, 1, 2));        // x18..x30
        e_end();
        run_prog();
        for (int k = 0; k < 15; k++) chk_x(3 + k,  ref_alu(k, vval(i), vval(j)));
        for (int m = 0; m < 13; m++) chk_x(18 + m, ref_m  (m, vval(i), vval(j)));
        chk_ill(0);
        end_test();
      end
    end
  endtask

  // ---- RV64I immediate ALU ops ------------------------------------------------------------------
  task automatic t_imm_ops();
    int ia, sh, shw;
    logic [63:0] a, immx;
    for (int i = 0; i < NV; i++) begin
      for (int k = 0; k < 6; k++) begin
        a = vval(i); ia = imm_arith(k); sh = shamt64(k); shw = shamt32(k);
        immx = sext_i(ia);
        start_test($sformatf("OP-IMM a=%h imm=%0d sh=%0d shw=%0d", a, ia, sh, shw));
        begin_prog();
        emit_li(1, a);
        e(ADDI (2, 1, ia));  e(SLTI (3, 1, ia));  e(SLTIU(4, 1, ia));
        e(XORI (5, 1, ia));  e(ORI  (6, 1, ia));  e(ANDI (7, 1, ia));
        e(SLLI (8, 1, sh));  e(SRLI (9, 1, sh));  e(SRAI (10, 1, sh));
        e(ADDIW(11, 1, ia));
        e(SLLIW(12, 1, shw)); e(SRLIW(13, 1, shw)); e(SRAIW(14, 1, shw));
        e_end();
        run_prog();
        chk_x(2,  ref_alu(O_ADD,  a, immx));
        chk_x(3,  ref_alu(O_SLT,  a, immx));
        chk_x(4,  ref_alu(O_SLTU, a, immx));
        chk_x(5,  ref_alu(O_XOR,  a, immx));
        chk_x(6,  ref_alu(O_OR,   a, immx));
        chk_x(7,  ref_alu(O_AND,  a, immx));
        chk_x(8,  ref_alu(O_SLL,  a, 64'(sh)));
        chk_x(9,  ref_alu(O_SRL,  a, 64'(sh)));
        chk_x(10, ref_alu(O_SRA,  a, 64'(sh)));
        chk_x(11, ref_alu(O_ADDW, a, immx));
        chk_x(12, ref_alu(O_SLLW, a, 64'(shw)));
        chk_x(13, ref_alu(O_SRLW, a, 64'(shw)));
        chk_x(14, ref_alu(O_SRAW, a, 64'(shw)));
        chk_ill(0);
        end_test();
      end
    end
  endtask

  // ---- LUI / AUIPC / x0 -------------------------------------------------------------------------------
  task automatic t_upper();
    int a1, a2;
    start_test("LUI / AUIPC / x0 hardwired");
    begin_prog();
    e(LUI(1, 20'h12345));
    e(LUI(2, 20'hFFFFF));
    e(LUI(3, 20'h80000));
    e(LUI(4, 20'h7FFFF));
    a1 = pcb(); e(AUIPC(5, 20'h00001));
    a2 = pcb(); e(AUIPC(6, 20'hFFFFF));
    e(ADDI(0, 0, 5));            // write to x0 must be dropped
    e(ADD (7, 0, 0));
    e(LUI (0, 20'h55555));
    e(ADD (8, 0, 0));
    e_end();
    run_prog();
    chk_x(1, 64'h0000_0000_1234_5000);
    chk_x(2, 64'hFFFF_FFFF_FFFF_F000);
    chk_x(3, 64'hFFFF_FFFF_8000_0000);
    chk_x(4, 64'h0000_0000_7FFF_F000);
    chk_x(5, 64'(a1) + 64'h1000);
    chk_x(6, 64'(a2) - 64'h1000);
    chk_x(7, 64'h0);
    chk_x(8, 64'h0);
    chk_ill(0);
    end_test();
  endtask

  // ---- data hazards / forwarding -----------------------------------------------------------------------
  task automatic t_forwarding();
    start_test("forwarding: EX/MEM, MEM/WB, regfile bypass, x0");
    begin_prog();
    e(ADDI(1, 0, 1));
    e(ADD (2, 1, 1));      // EX/MEM fwd on both operands
    e(ADD (3, 2, 1));      // rs1 from EX/MEM, rs2 from MEM/WB
    e(ADD (4, 3, 2));
    e(ADD (5, 4, 3));
    e(ADD (6, 5, 4));
    e(SUB (7, 6, 5));
    e(ADDI(9, 0, 9));
    e(NOP());
    e(NOP());
    e(ADD (10, 9, 9));     // distance 3: regfile write-through bypass
    e(ADDI(0, 0, 5));
    e(ADD (11, 0, 0));     // must be 0
    e(ADDI(12, 0, 7));
    e(ADD (0, 12, 12));    // write to x0
    e(ADD (13, 0, 12));    // x0 must not be forwarded: 0 + 7
    e(ADDI(14, 0, 3));
    e(SLLI(14, 14, 2));    // 12
    e(ADDI(14, 14, 1));    // 13
    e(XORI(14, 14, 5));    // 8
    e_end();
    run_prog();
    chk_x(1, 1);  chk_x(2, 2);  chk_x(3, 3);  chk_x(4, 5);  chk_x(5, 8);  chk_x(6, 13);
    chk_x(7, 5);  chk_x(9, 9);  chk_x(10, 18); chk_x(11, 0); chk_x(12, 7); chk_x(13, 7);
    chk_x(14, 8);
    check64("stall cycles", 64'(stall_cnt), 0);
    chk_ill(0);
    end_test();
  endtask

  // ---- loads / stores --------------------------------------------------------------------------------------
  task automatic t_ldst();
    start_test("loads / stores / sign-zero extension / adjacency");
    begin_prog();
    e(ADDI(10, 0, 1024));
    emit_li(1, 64'h8899_AABB_CCDD_EEFF);
    e(SD(1, 10, 0));
    e(LB (2, 10, 0));  e(LBU(3, 10, 0));  e(LH (4, 10, 0));  e(LHU(5, 10, 0));
    e(LW (6, 10, 0));  e(LWU(7, 10, 0));  e(LD (8, 10, 0));
    e(LB (9, 10, 7));  e(LBU(11, 10, 7)); e(LH (12, 10, 6)); e(LHU(13, 10, 6));
    e(LW (14, 10, 4)); e(LWU(15, 10, 4));
    e(SD (0, 10, 16));
    emit_li(20, 64'h0123_4567_89AB_CDEF);
    e(SB (20, 10, 16));
    e(SH (20, 10, 18));
    e(SW (20, 10, 20));
    e(LD (21, 10, 16));
    e(SD (20, 10, 24));
    e(LD (22, 10, 24));
    e(ADDI(23, 10, 32));
    e(LD (24, 23, -32));          // negative offset
    e(SD (1, 10, 40));
    e(LD (25, 10, 40));           // store immediately followed by load
    e(SD (0, 10, 48));
    e(SB (20, 10, 48));
    e(LBU(26, 10, 48));
    e(SW (20, 10, 56));
    e(LW (27, 10, 56));
    e_end();
    run_prog();
    chk_x(2,  64'hFFFF_FFFF_FFFF_FFFF);
    chk_x(3,  64'h0000_0000_0000_00FF);
    chk_x(4,  64'hFFFF_FFFF_FFFF_EEFF);
    chk_x(5,  64'h0000_0000_0000_EEFF);
    chk_x(6,  64'hFFFF_FFFF_CCDD_EEFF);
    chk_x(7,  64'h0000_0000_CCDD_EEFF);
    chk_x(8,  64'h8899_AABB_CCDD_EEFF);
    chk_x(9,  64'hFFFF_FFFF_FFFF_FF88);
    chk_x(11, 64'h0000_0000_0000_0088);
    chk_x(12, 64'hFFFF_FFFF_FFFF_8899);
    chk_x(13, 64'h0000_0000_0000_8899);
    chk_x(14, 64'hFFFF_FFFF_8899_AABB);
    chk_x(15, 64'h0000_0000_8899_AABB);
    chk_x(21, 64'h89AB_CDEF_CDEF_00EF);
    chk_x(22, 64'h0123_4567_89AB_CDEF);
    chk_x(24, 64'h8899_AABB_CCDD_EEFF);
    chk_x(25, 64'h8899_AABB_CCDD_EEFF);
    chk_x(26, 64'h0000_0000_0000_00EF);
    chk_x(27, 64'hFFFF_FFFF_89AB_CDEF);
    chk_ill(0);
    end_test();
  endtask

  // ---- load-use hazard: exactly one bubble per dependent pair ----------------------------------------
  task automatic t_load_use();
    start_test("load-use hazard (1 stall each)");
    begin_prog();
    e(ADDI(10, 0, 1024));
    e(ADDI(1, 0, 21));
    e(SD  (1, 10, 0));
    e(LD  (2, 10, 0));
    e(ADD (3, 2, 2));          // stall 1
    e(SD  (3, 10, 8));
    e(LD  (4, 10, 8));
    e(SD  (4, 10, 16));        // stall 2 (store data is the loaded value)
    e(LD  (5, 10, 16));
    e(ADDI(6, 5, 1));          // stall 3
    e(LW  (7, 10, 0));
    e(BEQ (7, 1, 8));          // stall 4 (branch operand), taken
    e(ADDI(8, 0, 99));         // skipped
    e(ADDI(9, 0, 5));
    e(ADDI(13, 0, 1024));
    e(SD  (13, 10, 32));
    e(LD  (11, 10, 32));       // x11 = 0x400
    e(LD  (12, 11, 0));        // stall 5 (load -> address), x12 = 21
    e_end();
    run_prog();
    chk_x(2, 21); chk_x(3, 42); chk_x(4, 42); chk_x(5, 42); chk_x(6, 43); chk_x(7, 21);
    chk_x(8, 0);  chk_x(9, 5);  chk_x(11, 64'h400); chk_x(12, 21);
    chk_m64(32'h408, 42);
    chk_m64(32'h410, 42);
    check64("stall cycles", 64'(stall_cnt), 5);
    chk_ill(0);
    end_test();
  endtask

  // ---- branches: 6 types x 12 operand pairs, operands arrive by forwarding ----------------------------
  function automatic logic [63:0] bpa(input int k);
    case (k)
      0: bpa = 64'd0;                    1: bpa = 64'd1;                 2: bpa = 64'd2;
      3: bpa = 64'hFFFF_FFFF_FFFF_FFFF;  4: bpa = 64'd1;                 5: bpa = 64'hFFFF_FFFF_FFFF_FFFF;
      6: bpa = 64'h8000_0000_0000_0000;  7: bpa = 64'd1;                 8: bpa = 64'h7FFF_FFFF_FFFF_FFFF;
      9: bpa = 64'h8000_0000_0000_0000;  10: bpa = 64'h0000_0000_FFFF_FFFF;
      default: bpa = 64'h1234_5678_9ABC_DEF0;
    endcase
  endfunction
  function automatic logic [63:0] bpb(input int k);
    case (k)
      0: bpb = 64'd0;                    1: bpb = 64'd2;                 2: bpb = 64'd1;
      3: bpb = 64'd1;                    4: bpb = 64'hFFFF_FFFF_FFFF_FFFF; 5: bpb = 64'hFFFF_FFFF_FFFF_FFFF;
      6: bpb = 64'd1;                    7: bpb = 64'h8000_0000_0000_0000; 8: bpb = 64'h8000_0000_0000_0000;
      9: bpb = 64'h7FFF_FFFF_FFFF_FFFF;  10: bpb = 64'h0000_0001_0000_0000;
      default: bpb = 64'h1234_5678_9ABC_DEF0;
    endcase
  endfunction

  function automatic string brname(input int tp);
    case (tp) 0: brname="BEQ"; 1: brname="BNE"; 2: brname="BLT"; 3: brname="BGE"; 4: brname="BLTU"; default: brname="BGEU"; endcase
  endfunction

  task automatic t_branches();
    for (int tp = 0; tp < 6; tp++) begin
      start_test($sformatf("branch %s (taken/not-taken, 12 pairs)", brname(tp)));
      begin_prog();
      for (int k = 0; k < 12; k++) begin
        emit_li(1, bpa(k));
        e(ADDI(10 + k, 0, 1));
        emit_li(2, bpb(k));                  // last instruction writes x2 right before the branch
        e(enc_br(tp, 1, 2, 8));              // taken -> skip the clearing ADDI
        e(ADDI(10 + k, 0, 0));
      end
      e_end();
      run_prog();
      for (int k = 0; k < 12; k++) chk_x(10 + k, 64'(ref_br(tp, bpa(k), bpb(k))));
      chk_ill(0);
      end_test();
    end
  endtask

  // ---- JAL / JALR / loops ----------------------------------------------------------------------------------
  task automatic t_jumps();
    int a0, p, q, s, r;
    start_test("JAL / JALR / call-return / loops / backward jump");
    begin_prog();
    a0 = pcb(); e(JAL(1, 12));                 // skip two instrs
    e(ADDI(2, 0, 1));                          // skipped
    e(ADDI(3, 0, 1));                          // skipped
    e(ADDI(4, 0, 4));
    // call / return
    p = pcb();  e(JAL(5, 12));                 // -> F, x5 = p+4
    e(ADDI(6, 0, 6));                          // return point
    e(JAL(0, 12));                             // -> END
    e(ADDI(7, 0, 5));                          // F:
    e(JALR(0, 5, 0));                          // ret
    // JALR clears bit 0 of the target
    q = pcb();  e(AUIPC(9, 0));
    e(ADDI(9, 9, 17));
    e(JALR(10, 9, 0));                         // -> q+16, x10 = q+12
    e(ADDI(11, 0, 1));                         // skipped
    e(ADDI(12, 0, 12));
    // JALR with non-zero immediate: target = x13 + 8
    r = pcb();  e(AUIPC(13, 0));               // x13 = r
    e(JALR(14, 13, 12));                       // -> r+12, x14 = r+8
    e(ADDI(15, 0, 1));                         // skipped
    e(ADDI(16, 0, 16));
    // backward JAL
    s = pcb();  e(JAL(0, 8));                  // s -> s+8
    e(JAL(0, 12));                             // s+4 -> s+16 (END)
    e(ADDI(21, 0, 21));                        // s+8
    e(JAL(0, -8));                             // s+12 -> s+4
    // counted loop: sum 1..10
    e(ADDI(20, 0, 0));
    e(ADDI(22, 0, 10));
    e(ADDI(23, 0, 0));
    e(ADDI(20, 20, 1));                        // L
    e(ADD (23, 23, 20));
    e(BNE (20, 22, -8));                       // -> L
    e_end();
    run_prog();
    chk_x(1, 64'(a0) + 4);
    chk_x(2, 0); chk_x(3, 0); chk_x(4, 4);
    chk_x(5, 64'(p) + 4);
    chk_x(6, 6); chk_x(7, 5);
    chk_x(9, 64'(q) + 17);
    chk_x(10, 64'(q) + 12);
    chk_x(11, 0); chk_x(12, 12);
    chk_x(13, 64'(r));
    chk_x(14, 64'(r) + 8);
    chk_x(15, 0); chk_x(16, 16);
    chk_x(21, 21);
    chk_x(20, 10); chk_x(22, 10); chk_x(23, 55);
    chk_ill(0);
    end_test();
  endtask

  // ---- M extension: dependent chains through the multi-cycle unit ---------------------------------------
  task automatic t_mdu_chain();
    start_test("M ext: MDU result forwarding / back-to-back");
    begin_prog();
    e(ADDI(1, 0, 7));
    e(ADDI(2, 0, 6));
    e(MUL (3, 1, 2));        // 42
    e(ADD (4, 3, 3));        // 84  (consumes MDU result immediately)
    e(MUL (5, 3, 3));        // 1764 (MDU result forwarded into MDU)
    e(DIV (6, 5, 3));        // 42
    e(REM (7, 4, 1));        // 0
    e(DIVU(8, 4, 2));        // 14
    e(REMU(9, 4, 5));        // 84
    e(MULH(10, 3, 3));       // 0
    e(ADDI(11, 6, 1));       // 43 (consumes DIV)
    e(BNE (11, 0, 8));       // taken, branch operand from MDU consumer
    e(ADDI(12, 0, 99));      // skipped
    e(ADDI(13, 0, 13));
    e_end();
    run_prog();
    chk_x(3, 42); chk_x(4, 84); chk_x(5, 1764); chk_x(6, 42); chk_x(7, 0); chk_x(8, 14);
    chk_x(9, 84); chk_x(10, 0); chk_x(11, 43); chk_x(12, 0); chk_x(13, 13);
    chk_ill(0);
    end_test();
  endtask

  // ---- A extension: AMO ops (.W/.D) against reference model -----------------------------------------------
  task automatic t_amo(input int combo);
    logic [63:0] old, src;
    logic [63:0] exp_new, o_rd;
    int off, rd;
    case (combo)
      0: begin old = 64'hFFFF_FFFF_FFFF_FFF0; src = 64'd5; end
      1: begin old = 64'd5;                   src = 64'hFFFF_FFFF_FFFF_FFF0; end
      2: begin old = 64'h8000_0000_0000_0001; src = 64'h7FFF_FFFF_FFFF_FFFF; end
      default: begin old = 64'h1234_5678_0000_0007; src = 64'h9ABC_DEF0_FFFF_FFF8; end
    endcase
    start_test($sformatf("AMO ops combo %0d (old=%h src=%h)", combo, old, src));
    begin_prog();
    e(ADDI(10, 0, 1024));
    emit_li(2, src);
    emit_li(3, old);
    for (int dw = 0; dw < 2; dw++) begin
      for (int k = 0; k < 9; k++) begin
        off = dw*256 + 16*k;
        rd  = dw ? 21 + k : 12 + k;
        e(ADDI(11, 10, off));
        e(SD  (3, 11, 0));
        e(AMO (amo_f5(k), dw, rd, 11, 2));
      end
    end
    e(ADD(30, 29, 29));          // consumer of the last AMO (load-use stall)
    e_end();
    run_prog();
    for (int dw = 0; dw < 2; dw++) begin
      for (int k = 0; k < 9; k++) begin
        off     = dw*256 + 16*k;
        rd      = dw ? 21 + k : 12 + k;
        o_rd    = (dw != 0) ? old : {{32{old[31]}}, old[31:0]};
        exp_new = ref_amo_new(k, dw, old, src);
        chk_x(rd, o_rd);
        chk_m64(32'h400 + off, exp_new);
      end
    end
    chk_x(30, old + old);                  // x29 holds the old value (rd of the last AMO.D)
    chk_ill(0);
    end_test();
  endtask

  // ---- A extension: LR/SC -------------------------------------------------------------------------------------
  task automatic t_lrsc();
    start_test("LR/SC: success, no-reservation, wrong granule, store/AMO break reservation");
    begin_prog();
    e(ADDI(10, 0, 1024));
    e(ADDI(1, 0, 1));
    emit_li(20, 64'h8877_6655_4433_2211);  e(SD(20, 10, 0));
    emit_li(21, 64'hCAFE_BABE_DEAD_BEEF);  e(SD(21, 10, 8));
    emit_li(4,  64'h0000_0000_AAAA_BBBB);
    emit_li(6,  64'h0000_0000_DEAD_BEEF);
    emit_li(8,  64'h0000_0000_1234_5678);
    emit_li(13, 64'h0102_0304_0506_0708);
    e(ADDI(15, 10, 8));
    e(LRX(2, 10, 0));            // x2  = 0x44332211
    e(ADD(22, 2, 2));            // load-use on LR
    e(SCX(3, 10, 4, 0));         // success -> x3 = 0
    e(SCX(5, 10, 6, 0));         // no reservation -> x5 = 1, mem unchanged
    e(LRX(7, 10, 1));            // x7 = 0x88776655AAAABBBB
    e(SW (8, 10, 0));            // normal store to reserved granule
    e(SCX(9, 10, 13, 1));        // fails -> x9 = 1
    e(LRX(11, 10, 1));           // x11 = 0x8877665512345678
    e(SCX(12, 15, 13, 1));       // different granule -> x12 = 1
    e(SCX(14, 10, 13, 1));       // reservation already consumed -> x14 = 1
    e(LRX(18, 10, 1));
    e(SCX(19, 10, 13, 1));       // success -> x19 = 0, mem = 0x0102030405060708
    e(LRX(16, 10, 0));           // x16 = 0x05060708
    e(AMO(5'b00000, 0, 0, 10, 1));  // amoadd.w x0, x1, (x10)  -> breaks reservation
    e(SCX(17, 10, 4, 0));        // fails -> x17 = 1
    e_end();
    run_prog();
    chk_x(2,  64'h0000_0000_4433_2211);
    chk_x(22, 64'h0000_0000_8866_4422);
    chk_x(3,  0);
    chk_x(5,  1);
    chk_x(7,  64'h8877_6655_AAAA_BBBB);
    chk_x(9,  1);
    chk_x(11, 64'h8877_6655_1234_5678);
    chk_x(12, 1);
    chk_x(14, 1);
    chk_x(18, 64'h8877_6655_1234_5678);
    chk_x(19, 0);
    chk_x(16, 64'h0000_0000_0506_0708);
    chk_x(17, 1);
    chk_m64(32'h400, 64'h0102_0304_0506_0709);
    chk_m64(32'h408, 64'hCAFE_BABE_DEAD_BEEF);
    chk_ill(0);
    end_test();
  endtask

  // ---- F extension: FPU chain, forwarding, FMA family ----------------------------------------------------------
  task automatic t_fp_chain();
    start_test("F ext: dependent FP chain (add/mul/sub/sqrt/div/FMA family)");
    begin_prog();
    e(ADDI(10, 0, 1024));
    emit_li(1, 64'h3FC0_0000);  e(SW(1, 10, 0));      // 1.5
    emit_li(1, 64'h4010_0000);  e(SW(1, 10, 4));      // 2.25
    e(FLW(1, 10, 0));
    e(FLW(2, 10, 4));
    e(enc_fp(OP_FADD,  4, 1, 2, 0, 0));    // 3.75
    e(enc_fp(OP_FMUL,  5, 4, 4, 0, 0));    // 14.0625
    e(enc_fp(OP_FSUB,  6, 5, 4, 0, 0));    // 10.3125
    e(enc_fp(OP_FSQRT, 7, 5, 0, 0, 0));    // 3.75
    e(enc_fp(OP_FDIV,  8, 6, 4, 0, 0));    // 2.75
    e(enc_fp(OP_FMADD,  9, 1, 2, 4, 0));   //  1.5*2.25 + 3.75 =  7.125
    e(enc_fp(OP_FMSUB, 10, 1, 2, 4, 0));   //  1.5*2.25 - 3.75 = -0.375
    e(enc_fp(OP_FNMSUB,11, 1, 2, 4, 0));   // -1.5*2.25 + 3.75 =  0.375
    e(enc_fp(OP_FNMADD,12, 1, 2, 4, 0));   // -1.5*2.25 - 3.75 = -7.125
    e(FSW(9, 10, 16));
    e(LW (3, 10, 16));
    e_end();
    run_prog();
    chk_f(4,  32'h4070_0000);  chk_f(5,  32'h4161_0000);  chk_f(6,  32'h4125_0000);
    chk_f(7,  32'h4070_0000);  chk_f(8,  32'h4030_0000);  chk_f(9,  32'h40E4_0000);
    chk_f(10, 32'hBEC0_0000);  chk_f(11, 32'h3EC0_0000);  chk_f(12, 32'hC0E4_0000);
    chk_x(3, 64'h0000_0000_40E4_0000);
    check64("fflags", {59'b0, dut.fcsr_inst.fflags}, 0);
    chk_ill(0);
    end_test();
  endtask

  task automatic t_fp_int_moves();
    start_test("F ext: int<->FP moves, converts, compares, FCLASS, forwarding between files");
    begin_prog();
    e(ADDI(10, 0, 1024));
    emit_li(1, 64'h3FC0_0000);  e(SW(1, 10, 0));
    emit_li(2, 64'h4010_0000);  e(SW(2, 10, 4));
    e(FLW(1, 10, 0));                         // f1 = 1.5
    e(FLW(2, 10, 4));                         // f2 = 2.25
    e(ADDI(5, 0, 7));
    e(enc_fp(OP_FCVT_S_W, 13, 5, 0, 0, 0));   // f13 = 7.0   (int operand forwarded)
    e(enc_fp(OP_FCVT_W_S,  6, 13, 0, 0, 0));   // x6  = 7     (FP operand forwarded)
    e(enc_fp(OP_FMV_X_W,   7, 1, 0, 0, 0));    // x7  = 0x3FC00000
    e(LUI(8, 20'hBF800));                      // x8  = 0xFFFFFFFFBF800000
    e(enc_fp(OP_FMV_W_X,  14, 8, 0, 0, 0));    // f14 = -1.0
    e(enc_fp(OP_FMV_X_W,   9, 14, 0, 0, 0));   // x9  = sign-extended
    e(enc_fp(OP_FEQ,      11, 1, 1, 0, 0));    // 1
    e(enc_fp(OP_FLT,      12, 1, 2, 0, 0));    // 1
    e(ADD(15, 11, 12));                        // 2  (FPU int result forwarded)
    e(enc_fp(OP_FLE,      16, 2, 1, 0, 0));    // 0
    e(enc_fp(OP_FCLASS,   17, 14, 0, 0, 0));   // negative normal -> bit 1
    e_end();
    run_prog();
    chk_f(13, 32'h40E0_0000);
    chk_x(6, 7);
    chk_x(7, 64'h0000_0000_3FC0_0000);
    chk_x(8, 64'hFFFF_FFFF_BF80_0000);
    chk_f(14, 32'hBF80_0000);
    chk_x(9, 64'hFFFF_FFFF_BF80_0000);
    chk_x(11, 1); chk_x(12, 1); chk_x(15, 2); chk_x(16, 0); chk_x(17, 64'h2);
    chk_ill(0);
    end_test();
  endtask

  task automatic t_fp_hazards();
    start_test("F ext: FP load-use, FP store data, rs3 hazard, int/FP register-number aliasing");
    begin_prog();
    e(ADDI(10, 0, 1024));
    emit_li(1, 64'h3FC0_0000);  e(SW(1, 10, 0));          // 1.5
    e(ADDI(5, 0, 3));
    e(FLW(5, 10, 0));                  // f5 = 1.5, x5 stays 3
    e(ADD(6, 5, 5));                   // x6 = 6   (must not see the FLW)
    e(enc_fp(OP_FMV_W_X, 7, 1, 0, 0, 0));   // f7 = 1.5
    e(LW(7, 10, 0));                   // x7 = 0x3FC00000
    e(enc_fp(OP_FADD, 8, 7, 7, 0, 0)); // f8 = 3.0 (reads f7, not x7)
    e(FLW(9, 10, 0));
    e(enc_fp(OP_FADD, 10, 9, 9, 0, 0));// f10 = 3.0 (FP load-use)
    e(FLW(11, 10, 0));
    e(FSW(11, 10, 8));                 // FP store data load-use
    e(LW(12, 10, 8));
    e(FLW(13, 10, 0));
    e(enc_fp(OP_FMADD, 14, 13, 13, 13, 0)); // 1.5*1.5+1.5 = 3.75 (rs1,rs2,rs3 hazard)
    e(FLW(15, 10, 0));
    e(enc_fp(OP_FMADD, 16, 13, 13, 15, 0)); // rs3-only hazard
    e_end();
    run_prog();
    chk_x(5, 3);  chk_f(5, 32'h3FC0_0000);
    chk_x(6, 6);
    chk_x(7, 64'h0000_0000_3FC0_0000);
    chk_f(8, 32'h4040_0000);
    chk_f(10, 32'h4040_0000);
    chk_x(12, 64'h0000_0000_3FC0_0000);
    chk_f(14, 32'h4070_0000);
    chk_f(16, 32'h4070_0000);
    chk_ill(0);
    end_test();
  endtask

  task automatic t_fcsr();
    start_test("Zicsr: fflags / frm / fcsr read-modify-write semantics, flag accumulation");
    begin_prog();
    e(LUI(1, 20'h3F800));
    e(enc_fp(OP_FMV_W_X, 1, 1, 0, 0, 0));        // f1 = 1.0
    e(enc_fp(OP_FMV_W_X, 0, 0, 0, 0, 0));        // f0 = 0.0 (f0 is an ordinary register)
    e(enc_fp(OP_FDIV, 2, 1, 0, 0, 0));           // 1/0 -> DZ
    e(CSRRS(5, 12'h001, 0));                     // x5 = 0x08
    emit_li(2, 64'h3DCC_CCCD);
    e(enc_fp(OP_FMV_W_X, 3, 2, 0, 0, 0));        // f3 = 0.1f
    e(enc_fp(OP_FMUL, 4, 3, 3, 0, 0));           // inexact
    e(CSRRS(6, 12'h001, 0));                     // x6 = 0x09
    e(CSRRWI(0, 12'h002, 3));                    // frm = 3
    e(CSRRS(7, 12'h002, 0));                     // x7 = 3
    e(CSRRS(8, 12'h003, 0));                     // x8 = 0x69
    e(CSRRCI(9, 12'h001, 8));                    // x9 = 0x09, fflags = 0x01
    e(CSRRS(10, 12'h001, 0));                    // x10 = 0x01
    e(CSRRSI(11, 12'h001, 16));                  // x11 = 0x01, fflags = 0x11
    e(CSRRS(12, 12'h003, 0));                    // x12 = 0x71
    emit_li(14, 64'h45);
    e(CSRRW(13, 12'h003, 14));                   // x13 = 0x71, fcsr = 0x45
    e(CSRRS(15, 12'h003, 0));                    // x15 = 0x45
    e(CSRRS(16, 12'h002, 0));                    // x16 = 2
    e(CSRRC(17, 12'h001, 14));                   // x17 = 0x05, fflags = 0x05 & ~0x45 = 0
    e(CSRRS(18, 12'h001, 0));                    // x18 = 0
    e(CSRRS(19, 12'h002, 0));                    // read with rs1=x0 must not write
    e_end();
    run_prog();
    chk_f(2, 32'h7F80_0000);
    chk_x(5, 64'h08);  chk_x(6, 64'h09);  chk_x(7, 3);      chk_x(8, 64'h69);
    chk_x(9, 64'h09);  chk_x(10, 64'h01); chk_x(11, 64'h01); chk_x(12, 64'h71);
    chk_x(13, 64'h71); chk_x(15, 64'h45); chk_x(16, 2);     chk_x(17, 64'h05);
    chk_x(18, 0);      chk_x(19, 2);
    chk_ill(0);
    end_test();
  endtask

  task automatic t_dynrm();
    start_test("F ext: dynamic rounding mode (frm) vs static rm");
    begin_prog();
    e(LUI(1, 20'h3F800));                         // 1.0
    e(enc_fp(OP_FMV_W_X, 1, 1, 0, 0, 0));
    e(LUI(2, 20'h40400));                         // 3.0
    e(enc_fp(OP_FMV_W_X, 2, 2, 0, 0, 0));
    for (int k = 0; k < 5; k++) begin
      e(CSRRWI(0, 12'h002, k));
      e(enc_fp(OP_FDIV, 10 + k, 1, 2, 0, 7));     // rm = DYN
    end
    e(enc_fp(OP_FDIV, 15, 1, 2, 0, 1));           // static RTZ
    e(enc_fp(OP_FDIV, 16, 1, 2, 0, 3));           // static RUP
    e_end();
    run_prog();
    chk_f(10, 32'h3EAAAAAB);   // RNE
    chk_f(11, 32'h3EAAAAAA);   // RTZ
    chk_f(12, 32'h3EAAAAAA);   // RDN
    chk_f(13, 32'h3EAAAAAB);   // RUP
    chk_f(14, 32'h3EAAAAAB);   // RMM
    chk_f(15, 32'h3EAAAAAA);
    chk_f(16, 32'h3EAAAAAB);
    chk_ill(0);
    end_test();
  endtask

  // ---- Zicntr ----------------------------------------------------------------------------------------------------
  task automatic t_zicntr();
    start_test("Zicntr: cycle/time/instret exact deltas, write via mcycle/minstret");
    begin_prog();
    e(CSRRS(1, 12'hC00, 0));
    e(NOP()); e(NOP()); e(NOP());
    e(CSRRS(2, 12'hC00, 0));                       // +4 cycles
    e(CSRRS(3, 12'hC02, 0));
    e(NOP()); e(NOP());
    e(CSRRS(4, 12'hC02, 0));                       // +3 instructions
    e(CSRRS(5, 12'hC01, 0));                       // time aliases cycle
    e(CSRRS(6, 12'hC00, 0));                       // next cycle
    emit_li(7, 64'd1000);
    e(CSRRW(0, 12'hB00, 7));                       // mcycle <= 1000
    e(CSRRS(8, 12'hC00, 0));                       // reads 1000
    emit_li(9, 64'd500);
    e(CSRRW(0, 12'hB02, 9));                       // minstret <= 500
    e(CSRRS(10, 12'hC02, 0));                      // reads 500
    e_end();
    run_prog();
    check64("cycle delta",   rx(2) - rx(1), 4);
    check64("instret delta", rx(4) - rx(3), 3);
    check64("time-cycle",    rx(6) - rx(5), 1);
    chk_x(8, 1000);
    chk_x(10, 500);
    chk_ill(0);
    end_test();
  endtask

  task automatic t_fence();
    start_test("FENCE / FENCE.I are no-ops");
    begin_prog();
    e(FENCE());
    e(ADDI(1, 0, 5));
    e(FENCEI());
    e(ADDI(2, 1, 1));
    e(FENCE());
    e_end();
    run_prog();
    chk_x(1, 5); chk_x(2, 6);
    chk_ill(0);
    end_test();
  endtask

  // ---- illegal / trapping instructions --------------------------------------------------------------------------
  // mode 0: none, 1: x10 = 0x402 (misaligned for .W/.D), 2: frm = 5 (invalid), 3: x10 = 0x404 (aligned .W, misaligned .D)
  task automatic t_ill32(input string name, input logic [31:0] ins, input int mode = 0);
    start_test({"illegal: ", name});
    begin_prog();
    e(ADDI(6, 0, 7));
    case (mode)
      1: e(ADDI(10, 0, 1026));
      2: e(CSRRWI(0, 12'h002, 5));
      3: e(ADDI(10, 0, 1028));
      default: ;
    endcase
    e(ins);
    e(ADDI(5, 0, 1));                 // younger instruction: must be squashed
    e_end();
    run_prog();
    chk_ill(1);
    chk_x(5, 0);
    chk_x(6, 7);
    chk_x(7, 0);                      // trapping instruction must not write rd
    end_test();
  endtask

  task automatic t_ill16(input string name, input logic [15:0] c);
    start_test({"illegal (RVC): ", name});
    begin_prog();
    e(ADDI(6, 0, 7));
    ec(c);
    e(ADDI(5, 0, 1));
    e_end();
    run_prog();
    chk_ill(1);
    chk_x(5, 0);
    chk_x(6, 7);
    end_test();
  endtask

  task automatic t_illegal_store_gating();
    start_test("illegal STORE funct3 must not modify memory");
    begin_prog();
    e(ADDI(10, 0, 1024));
    emit_li(1, 64'h1122_3344_5566_7788);
    e(SD(1, 10, 0));
    e(ADDI(2, 0, 85));
    e(enc_s(0, 2, 10, 3'b100, 7'h23));      // illegal store
    e(ADDI(5, 0, 1));
    e_end();
    run_prog();
    chk_ill(1);
    chk_m64(32'h400, 64'h1122_3344_5566_7788);
    chk_x(5, 0);
    end_test();
  endtask

  task automatic t_illegal_amo_gating();
    start_test("misaligned AMO must not modify memory or rd");
    begin_prog();
    e(ADDI(10, 0, 1024));
    emit_li(1, 64'h1122_3344_5566_7788);
    e(SD(1, 10, 0));
    e(SD(1, 10, 8));
    e(ADDI(2, 0, 1));
    e(ADDI(11, 10, 2));                       // 0x402: misaligned
    e(AMO(5'b00000, 0, 7, 11, 2));            // amoadd.w x7, x2, (0x402)
    e_end();
    run_prog();
    chk_ill(1);
    chk_x(7, 0);
    chk_m64(32'h400, 64'h1122_3344_5566_7788);
    chk_m64(32'h408, 64'h1122_3344_5566_7788);
    end_test();
  endtask

  // ---- FP vector regression (exact reference from fp_vectors.svh) ------------------------------------------
  localparam int MAXV = 1200;
  int          vop  [MAXV];
  logic [2:0]  vrm  [MAXV];
  logic [63:0] va   [MAXV];
  logic [63:0] vb   [MAXV];
  logic [63:0] vc   [MAXV];
  logic [63:0] vres [MAXV];
  logic [4:0]  vfl  [MAXV];
  int          nvec;

  task automatic addv(input int op, input logic [2:0] rm, input logic [63:0] a, input logic [63:0] b,
                      input logic [63:0] c, input logic [63:0] res, input logic [4:0] fl);
    vop[nvec] = op; vrm[nvec] = rm; va[nvec] = a; vb[nvec] = b; vc[nvec] = c;
    vres[nvec] = res; vfl[nvec] = fl;
    nvec++;
  endtask

  task automatic init_vectors();
    nvec = 0;
`include "fp_vectors.svh"
  endtask

  function automatic string opname(input int op);
    case (op)
      OP_FADD: opname="FADD";   OP_FSUB: opname="FSUB";   OP_FMUL: opname="FMUL";   OP_FDIV: opname="FDIV";
      OP_FSQRT: opname="FSQRT"; OP_FSGNJ: opname="FSGNJ"; OP_FSGNJN: opname="FSGNJN"; OP_FSGNJX: opname="FSGNJX";
      OP_FMIN: opname="FMIN";   OP_FMAX: opname="FMAX";
      OP_FCVT_W_S: opname="FCVT.W.S"; OP_FCVT_WU_S: opname="FCVT.WU.S";
      OP_FCVT_L_S: opname="FCVT.L.S"; OP_FCVT_LU_S: opname="FCVT.LU.S";
      OP_FMV_X_W: opname="FMV.X.W"; OP_FCLASS: opname="FCLASS";
      OP_FEQ: opname="FEQ"; OP_FLT: opname="FLT"; OP_FLE: opname="FLE";
      OP_FCVT_S_W: opname="FCVT.S.W"; OP_FCVT_S_WU: opname="FCVT.S.WU";
      OP_FCVT_S_L: opname="FCVT.S.L"; OP_FCVT_S_LU: opname="FCVT.S.LU";
      OP_FMV_W_X: opname="FMV.W.X";
      OP_FMADD: opname="FMADD"; OP_FMSUB: opname="FMSUB"; OP_FNMSUB: opname="FNMSUB"; OP_FNMADD: opname="FNMADD";
      default: opname="?";
    endcase
  endfunction

  localparam int FP_BATCH = 12;

  task automatic run_fp_batch(input int s, input int n);
    int i, A, op;
    start_test($sformatf("FP vectors %0d..%0d", s, s + n - 1));
    begin_prog();
    e(ADDI(10, 0, 1024));
    for (int k = 0; k < n; k++) begin
      i = s + k; A = 32 * k; op = vop[i];
      // operand data -> memory (dmem is only ever written by the program)
      if (a_is_int(op)) begin emit_li(6, va[i]);          e(SD(6, 10, A));      end
      else              begin emit_li(6, sext32(va[i][31:0])); e(SW(6, 10, A)); end
      if (uses_b(op))   begin emit_li(6, sext32(vb[i][31:0])); e(SW(6, 10, A + 8));  end
      if (uses_c(op))   begin emit_li(6, sext32(vc[i][31:0])); e(SW(6, 10, A + 16)); end
      e(SD(0, 10, A + 24));                               // clear result slot
      e(SD(0, 10, 12'h300 + 8*k));                        // clear flag slot
      // load operands
      if (a_is_int(op)) e(LD(6, 10, A)); else e(FLW(1, 10, A));
      if (uses_b(op))   e(FLW(2, 10, A + 8));
      if (uses_c(op))   e(FLW(3, 10, A + 16));
      // the operation under test
      if (dest_is_int(op)) begin
        e(enc_fp(op, 7, a_is_int(op) ? 6 : 1, 2, 3, int'(vrm[i])));
        e(SD(7, 10, A + 24));
      end else begin
        e(enc_fp(op, 4, a_is_int(op) ? 6 : 1, 2, 3, int'(vrm[i])));
        e(FSW(4, 10, A + 24));
      end
      e(CSRRW(5, 12'h001, 0));                            // read + clear fflags
      e(SD(5, 10, 12'h300 + 8*k));
    end
    e_end();
    run_prog();
    for (int k = 0; k < n; k++) begin
      i = s + k; A = 32 * k;
      check64($sformatf("vec#%0d %s rm=%0d a=%h b=%h c=%h  result", i, opname(vop[i]), vrm[i], va[i], vb[i], vc[i]),
              rm64(32'h400 + A + 24), vres[i]);
      check64($sformatf("vec#%0d %s rm=%0d a=%h b=%h c=%h  fflags", i, opname(vop[i]), vrm[i], va[i], vb[i], vc[i]),
              rm64(32'h700 + 8*k), {59'b0, vfl[i]});
    end
    chk_ill(0);
    end_test();
  endtask

  task automatic t_fp_vectors();
    for (int s = 0; s < nvec; s += FP_BATCH)
      run_fp_batch(s, ((nvec - s) < FP_BATCH) ? (nvec - s) : FP_BATCH);
  endtask

  // ===========================================================================
  // Main
  // ===========================================================================
  initial begin
    init_vectors();
    rst_n = 1'b0;
    #1;                                   // let imem.sv's initial block run

    // ---- C extension (existing program) --------------------------------------
    t_c_default();

    // ---- RV64I ------------------------------------------------------------------
    t_forwarding();
    t_upper();
    t_imm_ops();
    t_ldst();
    t_load_use();
    t_branches();
    t_jumps();
    t_fence();

    // ---- RV64M ------------------------------------------------------------------
    t_alu_m_pairs();      // also exhaustively checks the base R-type ALU ops
    t_mdu_chain();

    // ---- RV64A ------------------------------------------------------------------
    for (int c = 0; c < 4; c++) t_amo(c);
    t_lrsc();

    // ---- RV64F + Zicsr -----------------------------------------------------------
    t_fp_chain();
    t_fp_int_moves();
    t_fp_hazards();
    t_fcsr();
    t_dynrm();
    t_fp_vectors();

    // ---- Zicntr -------------------------------------------------------------------
    t_zicntr();

    // ---- traps -----------------------------------------------------------------------
    t_ill32("opcode 1111111",                 32'hFFFF_FFFF);
    // custom-0 is the Xai extension (dot8 / qrelu / max8): only its RESERVED encodings are illegal now
    t_ill32("custom-0 reserved funct3=3",          enc_i(0,       0, 3'b011, 7, 7'h0B));
    t_ill32("custom-0 reserved funct3=7",          enc_i(0,       0, 3'b111, 7, 7'h0B));
    t_ill32("custom-0 dot8 with funct7!=0",        enc_i(12'h020, 0, 3'b000, 7, 7'h0B));
    t_ill32("custom-0 qrelu with funct7[6:5]!=0",  enc_i(12'h400, 0, 3'b001, 7, 7'h0B));
    t_ill32("custom-0 max8 with funct7!=0",        enc_i(12'h020, 0, 3'b010, 7, 7'h0B));
    t_ill32("custom-1 opcode",                     enc_i(0,       0, 3'b000, 7, 7'h2B));
    t_ill32("JALR funct3=1",                  enc_i(0, 1, 3'b001, 7, 7'h67));
    t_ill32("BRANCH funct3=2",                enc_b(8, 2, 1, 3'b010));
    t_ill32("BRANCH funct3=3",                enc_b(8, 2, 1, 3'b011));
    t_ill32("LOAD funct3=7",                  enc_i(0, 10, 3'b111, 7, 7'h03));
    t_ill32("STORE funct3=4",                 enc_s(0, 1, 10, 3'b100, 7'h23));
    t_ill32("SLLI with imm[10] set",          enc_i(12'h401, 1, 3'b001, 7, 7'h13));
    t_ill32("SRLI with imm[7] set",           enc_i(12'h081, 1, 3'b101, 7, 7'h13));
    t_ill32("OP-IMM-32 funct3=2",             enc_i(1, 1, 3'b010, 7, 7'h1B));
    t_ill32("SLLIW shamt[5]=1",               enc_i(32, 1, 3'b001, 7, 7'h1B));
    t_ill32("SRLIW shamt[5]=1",               enc_i(32, 1, 3'b101, 7, 7'h1B));
    t_ill32("SRAIW shamt[5]=1",               enc_i(12'h420, 1, 3'b101, 7, 7'h1B));
    t_ill32("OP SLL funct7=0x20",             enc_r(7'h20, 2, 1, 3'b001, 7, 7'h33));
    t_ill32("OP funct7=0x10",                 enc_r(7'h10, 2, 1, 3'b000, 7, 7'h33));
    t_ill32("OP-32 funct7=1 funct3=1",        enc_r(7'h01, 2, 1, 3'b001, 7, 7'h3B));
    t_ill32("OP-32 funct3=2",                 enc_r(7'h00, 2, 1, 3'b010, 7, 7'h3B));
    t_ill32("SYSTEM funct3=4",                enc_i(1, 1, 3'b100, 7, 7'h73));
    t_ill32("MISC-MEM funct3=2",              enc_i(0, 0, 3'b010, 7, 7'h0F));
    t_ill32("AMO funct3=0",                   {5'b00001, 2'b00, 5'd2, 5'd10, 3'b000, 5'd7, 7'h2F});
    t_ill32("AMO unknown funct5",             {5'b01111, 2'b00, 5'd2, 5'd10, 3'b010, 5'd7, 7'h2F});
    t_ill32("LR with rs2 != 0",               AMO(5'b00010, 0, 7, 10, 2));
    t_ill32("misaligned AMOADD.W",            AMO(5'b00000, 0, 7, 10, 2), 1);
    t_ill32("misaligned AMOADD.D",            AMO(5'b00000, 1, 7, 10, 2), 3);
    t_ill32("misaligned LR.W",                LRX(7, 10, 0), 1);
    t_ill32("misaligned LR.D",                LRX(7, 10, 1), 3);
    t_ill32("misaligned SC.W",                SCX(7, 10, 2, 0), 1);
    t_ill32("misaligned SC.D",                SCX(7, 10, 2, 1), 3);
    t_ill32("FADD.D (fmt=1)",                 enc_r(7'b0000001, 2, 1, 3'b000, 3, 7'h53));
    t_ill32("FLD",                            enc_i(0, 10, 3'b011, 7, 7'h07));
    t_ill32("FSD",                            enc_s(0, 1, 10, 3'b011, 7'h27));
    t_ill32("FLW funct3=0",                   enc_i(0, 10, 3'b000, 7, 7'h07));
    t_ill32("FADD rm=101",                    enc_r(7'b0000000, 2, 1, 3'b101, 3, 7'h53));
    t_ill32("FADD rm=110",                    enc_r(7'b0000000, 2, 1, 3'b110, 3, 7'h53));
    t_ill32("FSQRT rs2 != 0",                 enc_r(7'b0101100, 1, 1, 3'b000, 3, 7'h53));
    t_ill32("FCVT.W.S rs2=4",                 enc_r(7'b1100000, 4, 1, 3'b000, 7, 7'h53));
    t_ill32("FCVT.S.W rs2=4",                 enc_r(7'b1101000, 4, 1, 3'b000, 3, 7'h53));
    t_ill32("FMV.X.W funct3=2",               enc_r(7'b1110000, 0, 1, 3'b010, 7, 7'h53));
    t_ill32("FMV.W.X rs2 != 0",               enc_r(7'b1111000, 1, 1, 3'b000, 3, 7'h53));
    t_ill32("FSGNJ funct3=3",                 enc_r(7'b0010000, 2, 1, 3'b011, 3, 7'h53));
    t_ill32("FMIN funct3=2",                  enc_r(7'b0010100, 2, 1, 3'b010, 3, 7'h53));
    t_ill32("FEQ funct3=3",                   enc_r(7'b1010000, 2, 1, 3'b011, 7, 7'h53));
    t_ill32("OP-FP unknown funct5",           enc_r(7'b0111000, 2, 1, 3'b000, 3, 7'h53));
    t_ill32("FMADD fmt=1",                    {5'd3, 2'b01, 5'd2, 5'd1, 3'b000, 5'd4, 7'h43});
    t_ill32("FMADD rm=101",                   {5'd3, 2'b00, 5'd2, 5'd1, 3'b101, 5'd4, 7'h43});
    t_ill32("FADD dynamic rm with frm=5",     enc_fp(OP_FADD, 3, 1, 2, 0, 7), 2);
    t_ill32("CSRRW to read-only cycle CSR",   CSRRW (7, 12'hC00, 1));
    t_ill32("CSRRSI to read-only instret CSR",CSRRSI(7, 12'hC02, 1));
    t_illegal_store_gating();
    t_illegal_amo_gating();

    t_ill16("all-zero parcel",                16'h0000);
    t_ill16("C.ADDI4SPN nzuimm=0",            16'h0004);
    t_ill16("C.FLD (no D ext)",               16'h2000);
    t_ill16("C.FSD (no D ext)",               16'hA000);
    t_ill16("C.ADDIW rd=x0",                  16'h2001);
    t_ill16("C.ADDI16SP nzimm=0",             16'h6101);
    t_ill16("C.LUI nzimm=0",                  16'h6081);
    t_ill16("reserved CA (funct2b=10, bit12=1)", 16'h9C41);
    t_ill16("C.FLDSP (no D ext)",             16'h2002);
    t_ill16("C.LWSP rd=x0",                   16'h4002);
    t_ill16("C.LDSP rd=x0",                   16'h6002);
    t_ill16("C.JR rs1=x0",                    16'h8002);
    t_ill16("C.FSDSP (no D ext)",             16'hA002);

    // ---- summary -------------------------------------------------------------------------
    $display("------------------------------------------------------------------");
    $display("tb_rv64imafc : %0d programs run, %0d checks, %0d programs FAILED",
             n_tests, n_checks, n_tests_failed);
    if (n_tests_failed == 0) $display("*** ALL TESTS PASSED ***");
    else                     $display("*** SOME TESTS FAILED ***");
    $display("------------------------------------------------------------------");
    $finish;
  end

  // global watchdog
  initial begin
    #200_000_000;
    $display("TB ERROR: global watchdog expired");
    $finish;
  end

endmodule