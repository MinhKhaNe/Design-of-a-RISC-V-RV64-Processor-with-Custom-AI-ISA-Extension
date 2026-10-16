module tb_rv64imcf;
  import rv64imafc_pkg::*;

  logic        clk = 1'b0;
  logic        rst_n = 1'b0;
  logic [63:0] pc_o;
  logic        stall_o, flush_o, illegal_o;

  rv64imafc_top dut (
      .clk(clk), .rst_n(rst_n), .pc_o(pc_o),
      .stall_o(stall_o), .flush_o(flush_o), .illegal_instr_o(illegal_o)
  );

  always #5 clk = ~clk;

  // ---------------------------------------------------------------- bookkeeping
  int unsigned n_checks = 0;
  int unsigned n_fail   = 0;
  int unsigned s_checks, s_fail;
  string       sect;
  localparam int MAX_PRINT = 60;

  task automatic begin_sect(input string name);
    sect = name; s_checks = n_checks; s_fail = n_fail;
    $display("---- %s", name);
  endtask

  task automatic end_sect();
    $display("     => %0d checks, %0d FAILED", n_checks - s_checks, n_fail - s_fail);
  endtask

  task automatic chk(input string what, input logic [63:0] got, input logic [63:0] exp);
    n_checks++;
    if (got !== exp) begin
      n_fail++;
      if (n_fail <= MAX_PRINT)
        $display("  FAIL [%s] %s: got %h expected %h", sect, what, got, exp);
    end
  endtask

  task automatic chk1(input string what, input bit cond);
    n_checks++;
    if (!cond) begin
      n_fail++;
      if (n_fail <= MAX_PRINT) $display("  FAIL [%s] %s", sect, what);
    end
  endtask

  // ---------------------------------------------------------------- state access
  function automatic logic [63:0] gx(input int n);
    if (n == 0) gx = 64'd0; else gx = dut.regfile_inst.regs[n];
  endfunction
  function automatic logic [31:0] gf(input int n);
    gf = dut.fp_regfile_inst.regs[n];
  endfunction
  function automatic logic [31:0] gm32(input int a);
    gm32 = {dut.dmem_inst.mem[a+3], dut.dmem_inst.mem[a+2],
            dut.dmem_inst.mem[a+1], dut.dmem_inst.mem[a]};
  endfunction

  // ---------------------------------------------------------------- RNG (simulator independent)
  int unsigned rng_s = 32'h1234_5678;
  function automatic int unsigned rnd();
    rng_s = rng_s ^ (rng_s << 13);
    rng_s = rng_s ^ (rng_s >> 17);
    rng_s = rng_s ^ (rng_s << 5);
    rnd = rng_s;
  endfunction
  function automatic int rnd_range(input int n);
    rnd_range = int'(rnd() % n);
  endfunction

  // ---------------------------------------------------------------- instruction encoders
  function automatic [31:0] encI(input int imm, input int rs1, input [2:0] f3, input int rd, input [6:0] opc);
    encI = {imm[11:0], rs1[4:0], f3, rd[4:0], opc};
  endfunction
  function automatic [31:0] encR(input [6:0] f7, input int rs2, input int rs1, input [2:0] f3, input int rd, input [6:0] opc);
    encR = {f7, rs2[4:0], rs1[4:0], f3, rd[4:0], opc};
  endfunction
  function automatic [31:0] encS(input int imm, input int rs2, input int rs1, input [2:0] f3, input [6:0] opc);
    encS = {imm[11:5], rs2[4:0], rs1[4:0], f3, imm[4:0], opc};
  endfunction
  function automatic [31:0] encB(input int off, input int rs2, input int rs1, input [2:0] f3);
    encB = {off[12], off[10:5], rs2[4:0], rs1[4:0], f3, off[4:1], off[11], 7'b1100011};
  endfunction
  function automatic [31:0] encU(input [19:0] imm, input int rd, input [6:0] opc);
    encU = {imm, rd[4:0], opc};
  endfunction
  function automatic [31:0] encR4(input [6:0] opc, input int rs3, input int rs2, input int rs1, input [2:0] rm, input int rd);
    encR4 = {rs3[4:0], 2'b00, rs2[4:0], rs1[4:0], rm, rd[4:0], opc};
  endfunction

  // integer
  function automatic [31:0] ADDI (input int rd, input int rs1, input int imm); ADDI  = encI(imm, rs1, 3'b000, rd, OP_IMM); endfunction
  function automatic [31:0] ADDIW(input int rd, input int rs1, input int imm); ADDIW = encI(imm, rs1, 3'b000, rd, OP_IMM_32); endfunction
  function automatic [31:0] SLLI (input int rd, input int rs1, input int sh);  SLLI  = encI(sh,  rs1, 3'b001, rd, OP_IMM); endfunction
  function automatic [31:0] SRLI (input int rd, input int rs1, input int sh);  SRLI  = encI(sh,  rs1, 3'b101, rd, OP_IMM); endfunction
  function automatic [31:0] OR_  (input int rd, input int rs1, input int rs2); OR_   = encR(7'h00, rs2, rs1, 3'b110, rd, OP_REG); endfunction
  function automatic [31:0] ADD  (input int rd, input int rs1, input int rs2); ADD   = encR(7'h00, rs2, rs1, 3'b000, rd, OP_REG); endfunction
  function automatic [31:0] MUL  (input int rd, input int rs1, input int rs2); MUL   = encR(7'h01, rs2, rs1, 3'b000, rd, OP_REG); endfunction
  function automatic [31:0] DIV  (input int rd, input int rs1, input int rs2); DIV   = encR(7'h01, rs2, rs1, 3'b100, rd, OP_REG); endfunction
  function automatic [31:0] LW   (input int rd, input int rs1, input int imm); LW    = encI(imm, rs1, 3'b010, rd, OP_LOAD); endfunction
  function automatic [31:0] SD   (input int rs2, input int rs1, input int imm); SD   = encS(imm, rs2, rs1, 3'b011, OP_STORE); endfunction
  function automatic [31:0] AUIPC(input int rd, input int imm20); AUIPC = encU(imm20[19:0], rd, OP_AUIPC); endfunction
  function automatic [31:0] JALR (input int rd, input int rs1, input int imm); JALR  = encI(imm, rs1, 3'b000, rd, OP_JALR); endfunction
  function automatic [31:0] BEQ  (input int rs1, input int rs2, input int off); BEQ = encB(off, rs2, rs1, 3'b000); endfunction
  function automatic [31:0] BNE  (input int rs1, input int rs2, input int off); BNE = encB(off, rs2, rs1, 3'b001); endfunction
  function automatic [31:0] BLT  (input int rs1, input int rs2, input int off); BLT = encB(off, rs2, rs1, 3'b100); endfunction
  function automatic [31:0] NOP32();  NOP32 = 32'h00000013; endfunction

  // CSR
  localparam int FFLAGS = 12'h001, FRM = 12'h002, FCSR = 12'h003;
  function automatic [31:0] CSRRW (input int rd, input int csr, input int rs1);  CSRRW  = encI(csr, rs1, 3'b001, rd, OP_SYSTEM); endfunction
  function automatic [31:0] CSRRS (input int rd, input int csr, input int rs1);  CSRRS  = encI(csr, rs1, 3'b010, rd, OP_SYSTEM); endfunction
  function automatic [31:0] CSRRC (input int rd, input int csr, input int rs1);  CSRRC  = encI(csr, rs1, 3'b011, rd, OP_SYSTEM); endfunction
  function automatic [31:0] CSRRWI(input int rd, input int csr, input int imm);  CSRRWI = encI(csr, imm, 3'b101, rd, OP_SYSTEM); endfunction
  function automatic [31:0] CSRRSI(input int rd, input int csr, input int imm);  CSRRSI = encI(csr, imm, 3'b110, rd, OP_SYSTEM); endfunction
  function automatic [31:0] CSRRCI(input int rd, input int csr, input int imm);  CSRRCI = encI(csr, imm, 3'b111, rd, OP_SYSTEM); endfunction

  // floating point (static rm = RNE unless noted)
  function automatic [31:0] FLW   (input int fd, input int rs1, input int imm); FLW = encI(imm, rs1, 3'b010, fd, OP_LOAD_FP); endfunction
  function automatic [31:0] FSW   (input int fs, input int rs1, input int imm); FSW = encS(imm, fs, rs1, 3'b010, OP_STORE_FP); endfunction
  function automatic [31:0] FADD  (input int fd, input int fa, input int fb); FADD  = encR(7'h00, fb, fa, 3'b000, fd, OP_FP); endfunction
  function automatic [31:0] FSUB  (input int fd, input int fa, input int fb); FSUB  = encR(7'h04, fb, fa, 3'b000, fd, OP_FP); endfunction
  function automatic [31:0] FMUL  (input int fd, input int fa, input int fb); FMUL  = encR(7'h08, fb, fa, 3'b000, fd, OP_FP); endfunction
  function automatic [31:0] FDIV  (input int fd, input int fa, input int fb); FDIV  = encR(7'h0C, fb, fa, 3'b000, fd, OP_FP); endfunction
  function automatic [31:0] FSQRT (input int fd, input int fa);               FSQRT = encR(7'h2C, 0,  fa, 3'b000, fd, OP_FP); endfunction
  function automatic [31:0] FMADD (input int fd, input int fa, input int fb, input int fc); FMADD = encR4(OP_FMADD, fc, fb, fa, 3'b000, fd); endfunction
  function automatic [31:0] FSGNJ (input int fd, input int fa, input int fb); FSGNJ = encR(7'h10, fb, fa, 3'b000, fd, OP_FP); endfunction
  function automatic [31:0] FEQ   (input int rd, input int fa, input int fb); FEQ   = encR(7'h50, fb, fa, 3'b010, rd, OP_FP); endfunction
  function automatic [31:0] FLT   (input int rd, input int fa, input int fb); FLT   = encR(7'h50, fb, fa, 3'b001, rd, OP_FP); endfunction
  function automatic [31:0] FCVT_W_S (input int rd, input int fa); FCVT_W_S  = encR(7'h60, 0, fa, 3'b000, rd, OP_FP); endfunction
  function automatic [31:0] FCVT_S_W (input int fd, input int rs); FCVT_S_W  = encR(7'h68, 0, rs, 3'b000, fd, OP_FP); endfunction
  function automatic [31:0] FCVT_S_WU(input int fd, input int rs); FCVT_S_WU = encR(7'h68, 1, rs, 3'b000, fd, OP_FP); endfunction
  function automatic [31:0] FMV_X_W  (input int rd, input int fa); FMV_X_W   = encR(7'h70, 0, fa, 3'b000, rd, OP_FP); endfunction
  function automatic [31:0] FMV_W_X  (input int fd, input int rs); FMV_W_X   = encR(7'h78, 0, rs, 3'b000, fd, OP_FP); endfunction

  // compressed
  function automatic [15:0] C_NOP();  C_NOP = 16'h0001; endfunction
  function automatic [15:0] C_ADDI(input int rd, input int imm); C_ADDI = {3'b000, imm[5], rd[4:0], imm[4:0], 2'b01}; endfunction
  function automatic [15:0] C_LI  (input int rd, input int imm); C_LI   = {3'b010, imm[5], rd[4:0], imm[4:0], 2'b01}; endfunction
  function automatic [15:0] C_SLLI(input int rd, input int sh);  C_SLLI = {3'b000, sh[5], rd[4:0], sh[4:0], 2'b10}; endfunction
  function automatic [15:0] C_MV  (input int rd, input int rs2); C_MV   = {4'b1000, rd[4:0], rs2[4:0], 2'b10}; endfunction
  function automatic [15:0] C_ADD (input int rd, input int rs2); C_ADD  = {4'b1001, rd[4:0], rs2[4:0], 2'b10}; endfunction
  function automatic [15:0] C_ALU (input int f2, input int rd3, input int rs23); C_ALU = {6'b100011, rd3[2:0], f2[1:0], rs23[2:0], 2'b01}; endfunction
  function automatic [15:0] C_LDSP(input int rd, input int off);  C_LDSP = {3'b011, off[5], rd[4:0], off[4:3], off[8:6], 2'b10}; endfunction
  function automatic [15:0] C_SDSP(input int rs2, input int off); C_SDSP = {3'b111, off[5:3], off[8:6], rs2[4:0], 2'b10}; endfunction
  function automatic [15:0] C_LWSP(input int rd, input int off);  C_LWSP = {3'b010, off[5], rd[4:0], off[4:2], off[7:6], 2'b10}; endfunction
  function automatic [15:0] C_SWSP(input int rs2, input int off); C_SWSP = {3'b110, off[5:2], off[7:6], rs2[4:0], 2'b10}; endfunction

  // ---------------------------------------------------------------- program buffer / runner
  logic [15:0] prog [0:2047];
  int          plen;                 // in 16-bit parcels
  logic [63:0] sent_pc;
  bit          timed_out;
  int          illegal_cnt;
  logic [63:0] ill_pc;

  task automatic pclear(); plen = 0; endtask
  task automatic e32(input logic [31:0] w); prog[plen] = w[15:0]; prog[plen+1] = w[31:16]; plen = plen + 2; endtask
  task automatic e16(input logic [15:0] h); prog[plen] = h; plen = plen + 1; endtask
  task automatic pend(); sent_pc = plen * 2; e32(32'h0000006F); endtask      // jal x0,0

  task automatic li32(input int rd, input logic [31:0] v);
    logic [31:0] hi; logic [11:0] lo;
    hi = (v + 32'h800) >> 12;
    lo = v[11:0];
    e32(encU(hi[19:0], rd, OP_LUI));
    e32(ADDIW(rd, rd, int'(lo)));
  endtask

  task automatic li64(input int rd, input logic [63:0] v);
    if (v[63:32] == {32{v[31]}}) li32(rd, v[31:0]);
    else begin
      li32(rd, v[63:32]);  e32(SLLI(rd, rd, 32));
      li32(28, v[31:0]);   e32(SLLI(28, 28, 32)); e32(SRLI(28, 28, 32));
      e32(OR_(rd, rd, 28));
    end
  endtask

  task automatic setf(input int fd, input logic [31:0] bits);
    li32(29, bits);
    e32(FMV_W_X(fd, 29));
  endtask

  always @(posedge clk) begin
    if (rst_n && illegal_o === 1'b1) begin
      if (illegal_cnt == 0) ill_pc <= dut.idex_pc;
      illegal_cnt <= illegal_cnt + 1;
    end
  end

  task automatic start_cpu();
    int i;
    rst_n = 1'b0;
    repeat (2) @(negedge clk);
    for (i = 0; i < plen + 6 && i < 2048; i++) dut.imem_inst.mem[i] = prog[i];
    illegal_cnt = 0;
    ill_pc      = 64'hx;
    repeat (2) @(negedge clk);
    rst_n = 1'b1;
  endtask

  task automatic run_end(input int max_cyc);
    int c;
    c = 0;
    timed_out = 1'b0;
    while (!(dut.idex_valid === 1'b1 && dut.idex_pc === sent_pc) && c < max_cyc) begin
      @(posedge clk); #1; c = c + 1;
    end
    if (c >= max_cyc) timed_out = 1'b1;
    repeat (6) @(posedge clk);
    #1;
  endtask

  task automatic exec(input int max_cyc);
    start_cpu();
    run_end(max_cyc);
    chk1("program reached its end (no timeout)", !timed_out);
  endtask

  // =============================================================================
  //  T1: reset / bring-up
  // =============================================================================
  task automatic t_bringup();
    begin_sect("bring-up and reset");
    // first instruction after reset reads a register (catches un-reset exmem/memwb *_reg_write)
    pclear(); e32(ADDI(5, 1, 0)); e32(FADD(4, 1, 2)); e32(FMV_X_W(6, 4)); pend();
    exec(100);
    chk("x5 (first instr reads x1 right after reset)", gx(5), 64'd0);
    chk("f4 (fadd of reset regs)", gf(4), 32'd0);
    chk("x6", gx(6), 64'd0);
    pclear(); e32(FADD(4, 1, 2)); e32(FMV_X_W(6, 4)); pend();     // FP op as the very first instruction
    exec(100);
    chk("f4 (FP op is the first instruction)", gf(4), 32'd0);
    chk1("pc_o not X after reset", (^pc_o) !== 1'bx);

    pclear();
    e32(ADDI(5, 0, 5)); e32(ADDI(6, 5, 3)); e32(ADD(7, 6, 5)); e32(ADDI(31, 0, 32'h100));
    e32(SD(7, 31, 0)); e32(LW(8, 31, 0)); e32(ADDI(9, 8, 1));
    pend();
    exec(100);
    chk("x6 fwd", gx(6), 64'd8);  chk("x7 fwd", gx(7), 64'd13);
    chk("x8 st/ld", gx(8), 64'd13); chk("x9 load-use", gx(9), 64'd14);
    end_sect();
  endtask

  // =============================================================================
  //  T2: directed FP pipeline tests
  // =============================================================================
  task automatic t_fp_directed();
    begin_sect("FP load/store, NaN preservation, f0 is a normal register");
    pclear();
    e32(ADDI(31, 0, 32'h100));
    setf(1, 32'h7F800001);
    e32(FSW(1, 31, 0)); e32(FLW(2, 31, 0)); e32(FSW(2, 31, 4));
    e32(LW(5, 31, 0));  e32(LW(6, 31, 4));
    setf(3, 32'hFFC01234); e32(FSW(3, 31, 8)); e32(LW(7, 31, 8));
    e32(ADDI(27, 31, 32)); e32(FLW(4, 27, -32));              // negative offset
    setf(0, 32'h40400000); e32(FADD(5, 0, 0));                // f0 writable / readable
    e32(CSRRS(10, FFLAGS, 0));
    pend(); exec(300);
    chk("x5 (sNaN payload kept by fsw)", gx(5), 64'h7F800001);
    chk("x6 (flw/fsw round trip)", gx(6), 64'h7F800001);
    chk("x7 (lw sign-extends)", gx(7), 64'hFFFFFFFFFFC01234);
    chk("f2", gf(2), 32'h7F800001); chk("f4 (flw -32)", gf(4), 32'h7F800001);
    chk("f0 + f0", gf(5), 32'h40C00000);
    chk("fflags (flw/fsw/fadd 3+3 raise nothing)", gx(10), 64'd0);
    end_sect();

    begin_sect("FP forwarding (EX/MEM, MEM/WB, WB bypass, rs1/rs2/rs3, int<->fp)");
    pclear();
    setf(1, 32'h3F800000); setf(2, 32'h40000000);
    e32(FADD(4, 1, 2));          // 3
    e32(FADD(5, 4, 1));          // 4   rs1 from EX/MEM
    e32(FADD(6, 1, 5));          // 5   rs2 from EX/MEM
    e32(FADD(7, 1, 1));          // 2
    e32(FADD(8, 6, 2));          // 7   rs1 from MEM/WB
    e32(FADD(9, 2, 7));          // 4   rs2 from MEM/WB
    e32(FADD(10, 1, 1)); e32(FADD(10, 1, 2)); e32(FADD(11, 10, 1));    // newest writer wins: 4
    e32(FADD(12, 1, 2)); e32(NOP32()); e32(NOP32()); e32(FADD(13, 12, 1));   // WB bypass: 4
    e32(FADD(14, 1, 2)); e32(FMADD(15, 1, 2, 14));                    // rs3 EX/MEM: 5
    e32(FADD(16, 2, 2)); e32(FADD(17, 1, 1)); e32(FMADD(18, 1, 2, 16));     // rs3 MEM/WB: 6
    e32(FADD(21, 1, 2)); e32(FMADD(22, 21, 2, 1));                    // 3*2+1 = 7 (rs1 fwd)
    e32(FADD(23, 1, 2)); e32(FMADD(24, 2, 23, 1));                    // 2*3+1 = 7 (rs2 fwd)
    e32(ADDI(5, 0, 7)); e32(FCVT_S_W(19, 5)); e32(FCVT_W_S(6, 19)); e32(ADDI(7, 6, 1));
    e32(FMV_W_X(20, 7)); e32(FEQ(8, 19, 19));
    e32(BNE(8, 0, 8)); e32(ADDI(9, 0, 99)); e32(ADDI(12, 0, 1));    // fp-compare result straight into a branch
    pend(); exec(400);
    chk("f4", gf(4), 32'h40400000);  chk("f5", gf(5), 32'h40800000);  chk("f6", gf(6), 32'h40A00000);
    chk("f8", gf(8), 32'h40E00000);  chk("f9", gf(9), 32'h40800000);  chk("f11", gf(11), 32'h40800000);
    chk("f13", gf(13), 32'h40800000); chk("f15", gf(15), 32'h40A00000); chk("f18", gf(18), 32'h40C00000);
    chk("f22", gf(22), 32'h40E00000); chk("f24", gf(24), 32'h40E00000);
    chk("f19 = (float)7", gf(19), 32'h40E00000); chk("x6 = fcvt.w.s", gx(6), 64'd7); chk("x7", gx(7), 64'd8);
    chk("f20 = fmv.w.x(8)", gf(20), 32'd8); chk("x8 = feq", gx(8), 64'd1);
    chk("x9 skipped by branch", gx(9), 64'd0); chk("x12 executed", gx(12), 64'd1);
    end_sect();

    begin_sect("FP load-use hazards");
    pclear();
    e32(ADDI(31, 0, 32'h100)); setf(1, 32'h3F800000); e32(FSW(1, 31, 0));
    e32(FLW(2, 31, 0)); e32(FADD(3, 2, 2));                  // flw -> fadd rs1,rs2
    e32(FLW(4, 31, 0)); e32(FSW(4, 31, 8));                  // flw -> fsw store data
    e32(FLW(5, 31, 0)); e32(FMADD(6, 1, 1, 5));              // flw -> fmadd rs3
    e32(LW(5, 31, 0));  e32(FMV_W_X(7, 5));                  // lw  -> fmv.w.x
    e32(FLW(8, 31, 0)); e32(FMV_X_W(6, 8));                  // flw -> fmv.x.w
    e32(LW(9, 31, 8));
    pend(); exec(300);
    chk("f3", gf(3), 32'h40000000); chk("x9 (stored loaded value)", gx(9), 64'h3F800000);
    chk("f7", gf(7), 32'h3F800000); chk("x6", gx(6), 64'h3F800000);
    chk("f5 (flw)", gf(5), 32'h3F800000);
    end_sect();

    begin_sect("multi-cycle FP ops (fdiv/fsqrt) and M-extension interplay");
    pclear();
    setf(1, 32'h3F800000); setf(2, 32'h40400000);
    e32(FDIV(3, 1, 2)); e32(FADD(4, 3, 3)); e32(FSQRT(5, 4)); e32(FMUL(6, 5, 5));
    e32(FDIV(7, 2, 1)); e32(FSQRT(8, 2));
    e32(CSRRS(10, FFLAGS, 0));
    pend(); exec(400);
    chk("f3 = 1/3", gf(3), 32'h3EAAAAAB); chk("f4 = 2/3", gf(4), 32'h3F2AAAAB);
    chk("f5 = sqrt(2/3)", gf(5), 32'h3F5105EC); chk("f6", gf(6), 32'h3F2AAAAB);
    chk("f7 = 3/1", gf(7), 32'h40400000); chk("f8 = sqrt(3)", gf(8), 32'h3FDDB3D7);
    chk("fflags = NX", gx(10), 64'd1);

    pclear();
    setf(3, 32'h40400000);
    e32(ADDI(6, 0, 100)); e32(ADDI(7, 0, 7));
    e32(DIV(5, 6, 7)); e32(FCVT_S_W(1, 5)); e32(FDIV(2, 1, 3));          // M result -> FPU -> slow op
    e32(MUL(8, 5, 5)); e32(FCVT_S_WU(4, 8)); e32(FSQRT(5, 4)); e32(FCVT_W_S(9, 5));
    pend(); exec(600);
    chk("x5 = 100/7", gx(5), 64'd14); chk("f1", gf(1), 32'h41600000); chk("f2 = 14/3", gf(2), 32'h40955555);
    chk("x8 = 196", gx(8), 64'd196); chk("f4", gf(4), 32'h43440000); chk("f5 = 14.0", gf(5), 32'h41600000);
    chk("x9 = 14", gx(9), 64'd14);

    pclear();
    setf(1, 32'h41600000); setf(2, 32'h40400000);
    e32(FDIV(3, 1, 2)); e32(FDIV(4, 3, 2)); e32(FSQRT(5, 4)); e32(FMUL(6, 5, 5));   // dependent slow-op chain
    pend(); exec(600);
    chk("chain f3", gf(3), 32'h40955555); chk("chain f4", gf(4), 32'h3FC71C71);
    chk("chain f5", gf(5), 32'h3F9FA4E0); chk("chain f6", gf(6), 32'h3FC71C71);
    end_sect();

    begin_sect("loops, FP compare + branch, fmv.x.w -> jalr");
    pclear();
    e32(ADDI(5, 0, 10)); e32(FMV_W_X(1, 0)); setf(2, 32'h3F800000);
    e32(FADD(1, 1, 2)); e32(ADDI(5, 5, -1)); e32(BNE(5, 0, -8));
    e32(ADDI(6, 0, 0)); e32(FMV_W_X(3, 0)); e32(ADDI(7, 0, 10));
    e32(ADDI(6, 6, 1)); e32(FCVT_S_W(4, 6)); e32(FADD(3, 3, 4)); e32(BLT(6, 7, -12));
    e32(FLT(8, 1, 3)); e32(BEQ(8, 0, 8)); e32(ADDI(9, 0, 1)); e32(ADDI(10, 0, 2));
    pend(); exec(1200);
    chk("f1 = 10.0", gf(1), 32'h41200000); chk("f3 = 55.0", gf(3), 32'h425C0000);
    chk("x5", gx(5), 64'd0); chk("x6", gx(6), 64'd10); chk("x8 = flt", gx(8), 64'd1);
    chk("x9", gx(9), 64'd1); chk("x10", gx(10), 64'd2);

    pclear();
    e32(AUIPC(11, 0)); e32(ADDI(11, 11, 24)); e32(FMV_W_X(1, 11)); e32(FMV_X_W(10, 1));
    e32(JALR(0, 10, 0)); e32(ADDI(12, 0, 99)); e32(ADDI(13, 0, 5));
    pend(); exec(200);
    chk("x12 skipped (jalr target from fmv.x.w forward)", gx(12), 64'd0); chk("x13", gx(13), 64'd5);
    end_sect();
  endtask

  // =============================================================================
  //  T3: fcsr / Zicsr semantics
  // =============================================================================
  task automatic t_fcsr();
    begin_sect("fflags/frm/fcsr CSR instructions");
    pclear();
    e32(CSRRWI(0, FFLAGS, 31)); e32(CSRRS(5, FFLAGS, 0));
    e32(CSRRCI(6, FFLAGS, 10)); e32(CSRRSI(7, FFLAGS, 2));
    e32(CSRRW(8, FFLAGS, 0));   e32(CSRRS(9, FFLAGS, 0));
    setf(1, 32'h3F800000); e32(FMV_W_X(2, 0));
    e32(FDIV(3, 1, 2));                                         // DZ
    setf(4, 32'h7F800000); e32(FSUB(5, 4, 4));                  // NV
    setf(7, 32'h40400000); e32(FDIV(6, 1, 7));                  // NX
    e32(CSRRS(10, FFLAGS, 0));                                  // 0x19 (flags accumulate)
    e32(CSRRWI(0, FRM, 3)); e32(CSRRS(11, FCSR, 0)); e32(CSRRS(12, FRM, 0));
    e32(ADDI(13, 0, 32'h65)); e32(CSRRW(0, FCSR, 13)); e32(CSRRS(14, FRM, 0)); e32(CSRRS(15, FFLAGS, 0));
    e32(CSRRWI(0, FFLAGS, 31)); e32(CSRRS(16, FFLAGS, 0)); e32(CSRRC(0, FFLAGS, 0)); e32(CSRRS(17, FFLAGS, 0));
    e32(CSRRSI(18, FFLAGS, 0)); e32(CSRRCI(0, FFLAGS, 0)); e32(CSRRS(19, FFLAGS, 0));
    pend(); exec(400);
    chk("csrrwi/csrrs fflags", gx(5), 64'h1F);
    chk("csrrci returns old", gx(6), 64'h1F); chk("csrrsi returns old", gx(7), 64'h15);
    chk("csrrw x0-source writes 0", gx(8), 64'h17); chk("fflags now 0", gx(9), 64'h0);
    chk("flags accumulate DZ|NV|NX", gx(10), 64'h19);
    chk("fcsr = {frm, fflags}", gx(11), 64'h79); chk("frm", gx(12), 64'h3);
    chk("fcsr write -> frm", gx(14), 64'h3); chk("fcsr write -> fflags", gx(15), 64'h5);
    chk("csrrs rs1=x0 no write", gx(17), 64'h1F); chk("csrrs zimm=0 / csrrci zimm=0 no write", gx(19), 64'h1F);
    end_sect();

    begin_sect("dynamic rounding-mode validity");
    // invalid frm + dynamic-rm op must trap and must not write
    pclear(); setf(1, 32'h3F800000); setf(2, 32'h40000000); e32(CSRRWI(0, FRM, 5));
    begin
      logic [63:0] a_fadd;
      a_fadd = plen * 2;
      e32(encR(7'h00, 2, 1, 3'b111, 4, OP_FP));
      start_cpu(); repeat (80) @(posedge clk); #1;
      chk1("illegal pulse for fadd rm=111 with frm=5", illegal_cnt > 0);
      chk("trap pc", ill_pc, a_fadd);
      chk("f4 untouched", gf(4), 32'd0);
      chk("fflags untouched", dut.fcsr_inst.fflags, 5'd0);
    end
    // invalid frm must NOT affect static-rm ops or non-rm ops
    pclear(); setf(1, 32'h3F800000); setf(2, 32'h40400000); e32(CSRRWI(0, FRM, 5));
    e32(FADD(4, 1, 2));  e32(FEQ(8, 1, 1)); e32(encR(7'h70, 0, 1, 3'b001, 9, OP_FP));   // fclass
    e32(FSGNJ(5, 1, 2)); e32(FMV_X_W(10, 2)); e32(FMV_W_X(6, 10)); e32(FCVT_S_W(7, 8));
    e32(FLW(3, 0, 0)); e32(FSW(1, 0, 8));
    pend(); exec(300);
    chk("no trap with static rm under bad frm", illegal_cnt, 0);
    chk("f4 = 4.0", gf(4), 32'h40800000);  chk("feq", gx(8), 64'd1); chk("fclass(+1) = bit6", gx(9), 64'h40);
    end_sect();
  endtask

  // =============================================================================
  //  T4: illegal encodings / HINTs
  // =============================================================================
  task automatic try_ill(input string nm, input logic [31:0] w, input bit is16);
    pclear(); e32(ADDI(11, 0, 85));
    if (is16) e16(w[15:0]); else e32(w);
    e32(ADDI(12, 0, 1));
    start_cpu(); repeat (40) @(posedge clk); #1;
    chk1({nm, " : must trap"}, illegal_cnt > 0);
    chk({nm, " : trap pc"}, ill_pc, 64'd4);
    chk({nm, " : x11 not clobbered"}, gx(11), 64'd85);
    chk({nm, " : f11 not written"}, gf(11), 32'd0);
    chk({nm, " : younger instr squashed"}, gx(12), 64'd0);
  endtask

  task automatic try_legal(input string nm, input logic [31:0] w, input bit is16);
    pclear(); e32(ADDI(5, 0, 17));
    if (is16) e16(w[15:0]); else e32(w);
    e32(ADDI(6, 0, 34)); pend();
    exec(100);
    chk(nm, illegal_cnt, 0);
    chk({nm, " : x5 intact"}, gx(5), 64'd17); chk({nm, " : next instr ran"}, gx(6), 64'd34);
  endtask

  task automatic t_illegal();
    begin_sect("illegal 32-bit encodings must trap with no side effect");
    try_ill("slli imm[11:6]!=0",     encR(7'b0100000, 1, 5, 3'b001, 11, OP_IMM), 0);
    try_ill("srli bad funct7",       encR(7'b1000000, 1, 5, 3'b101, 11, OP_IMM), 0);
    try_ill("slliw shamt[5]=1",      encR(7'b0000001, 1, 5, 3'b001, 11, OP_IMM_32), 0);
    try_ill("srliw shamt[5]=1",      encR(7'b0000001, 1, 5, 3'b101, 11, OP_IMM_32), 0);
    try_ill("op-imm-32 funct3=010",  encI(0, 5, 3'b010, 11, OP_IMM_32), 0);
    try_ill("branch funct3=010",     encB(8, 0, 0, 3'b010), 0);
    try_ill("branch funct3=011",     encB(8, 0, 0, 3'b011), 0);
    try_ill("load funct3=111",       encI(0, 0, 3'b111, 11, OP_LOAD), 0);
    try_ill("store funct3=100",      encS(0, 0, 0, 3'b100, OP_STORE), 0);
    try_ill("jalr funct3=001",       encI(0, 0, 3'b001, 11, OP_JALR), 0);
    try_ill("op funct7=0000010",     encR(7'b0000010, 1, 5, 3'b000, 11, OP_REG), 0);
    try_ill("op funct7=0100000 f3=001", encR(7'b0100000, 1, 5, 3'b001, 11, OP_REG), 0);
    try_ill("op-32 mulh-like f3=001", encR(7'b0000001, 1, 5, 3'b001, 11, OP_REG_32), 0);
    try_ill("custom-0 opcode",       32'h0000000B, 0);
    try_ill("system funct3=100",     encI(0, 0, 3'b100, 11, OP_SYSTEM), 0);
    try_ill("opcode 1111111",        32'hFFFFFFFF, 0);
    end_sect();

    begin_sect("illegal F encodings must trap with no side effect");
    try_ill("fadd rm=101",           encR(7'h00, 2, 1, 3'b101, 11, OP_FP), 0);
    try_ill("fadd rm=110",           encR(7'h00, 2, 1, 3'b110, 11, OP_FP), 0);
    try_ill("fadd fmt=D",            encR(7'h01, 2, 1, 3'b000, 11, OP_FP), 0);
    try_ill("fsqrt rs2!=0",          encR(7'h2C, 1, 1, 3'b000, 11, OP_FP), 0);
    try_ill("fcvt.w.s rs2=4",        encR(7'h60, 4, 1, 3'b000, 11, OP_FP), 0);
    try_ill("fcvt.s.w rs2=7",        encR(7'h68, 7, 5, 3'b000, 11, OP_FP), 0);
    try_ill("fmv.x.w funct3=010",    encR(7'h70, 0, 1, 3'b010, 11, OP_FP), 0);
    try_ill("fmv.x.w rs2=1",         encR(7'h70, 1, 1, 3'b000, 11, OP_FP), 0);
    try_ill("fclass rs2=1",          encR(7'h70, 1, 1, 3'b001, 11, OP_FP), 0);
    try_ill("fmin funct3=010",       encR(7'h14, 2, 1, 3'b010, 11, OP_FP), 0);
    try_ill("fsgnj funct3=011",      encR(7'h10, 2, 1, 3'b011, 11, OP_FP), 0);
    try_ill("feq funct3=111",        encR(7'h50, 2, 1, 3'b111, 11, OP_FP), 0);
    try_ill("fmv.w.x funct3=001",    encR(7'h78, 0, 5, 3'b001, 11, OP_FP), 0);
    try_ill("fmv.w.x rs2=1",         encR(7'h78, 1, 5, 3'b000, 11, OP_FP), 0);
    try_ill("unknown funct7 0x30",   encR(7'h30, 2, 1, 3'b000, 11, OP_FP), 0);
    try_ill("unknown funct7 0x58",   encR(7'h58, 2, 1, 3'b000, 11, OP_FP), 0);
    try_ill("fcvt.d.s (D ext)",      encR(7'h21, 0, 1, 3'b000, 11, OP_FP), 0);
    try_ill("fld (funct3=011)",      encI(0, 0, 3'b011, 11, OP_LOAD_FP), 0);
    try_ill("fsd (funct3=011)",      encS(0, 1, 0, 3'b011, OP_STORE_FP), 0);
    try_ill("fmadd fmt=D",           {5'd3, 2'b01, 5'd2, 5'd1, 3'b000, 5'd11, OP_FMADD}, 0);
    try_ill("fmadd rm=101",          encR4(OP_FMADD, 3, 2, 1, 3'b101, 11), 0);
    try_ill("fnmadd rm=110",         encR4(OP_FNMADD, 3, 2, 1, 3'b110, 11), 0);
    end_sect();

    begin_sect("illegal compressed encodings must trap");
    try_ill("c.addi4spn nzuimm=0",   16'h0004, 1);
    try_ill("c.lwsp rd=x0",          16'h4002, 1);
    try_ill("c.ldsp rd=x0",          16'h6002, 1);
    try_ill("c.jr rs1=x0",           16'h8002, 1);
    try_ill("c.addi16sp nzimm=0",    16'h6101, 1);
    try_ill("c.lui nzimm=0",         16'h6081, 1);
    try_ill("c.addiw rd=x0",         16'h2001, 1);
    try_ill("c.fld (no D)",          16'h2000, 1);
    try_ill("c.fsd (no D)",          16'hA000, 1);
    try_ill("c.fldsp (no D)",        16'h2002, 1);
    try_ill("c.fsdsp (no D)",        16'hA002, 1);
    try_ill("reserved c.arith 9C41", 16'h9C41, 1);
    try_ill("reserved c.arith 9C61", 16'h9C61, 1);
    // all-zero halfword
    pclear(); e32(ADDI(11, 0, 85)); e16(16'h0000); e16(16'h0000);
    start_cpu(); repeat (40) @(posedge clk); #1;
    chk1("all-zero parcel traps", illegal_cnt > 0); chk("all-zero trap pc", ill_pc, 64'd4);
    end_sect();

    begin_sect("HINT / legal encodings must NOT trap");
    try_legal("c.nop",                 16'h0001, 1);
    try_legal("c.addi x0,1 (HINT)",    16'h0005, 1);
    try_legal("c.addi x1,0 (HINT)",    16'h0081, 1);
    try_legal("c.li x0,5 (HINT)",      16'h4015, 1);
    try_legal("c.mv x0,x5 (HINT)",     16'h802E, 1);
    try_legal("c.add x0,x5 (HINT)",    16'h902E, 1);
    try_legal("c.slli x0,3 (HINT)",    16'h000E, 1);
    try_legal("c.slli x5,0 (HINT)",    16'h0282, 1);
    try_legal("c.srli x8,0 (HINT)",    16'h8001, 1);
    try_legal("c.srai x8,0 (HINT)",    16'h8401, 1);
    try_legal("c.lui x0,1 (HINT)",     16'h6005, 1);
    try_legal("fence",                 32'h0FF0000F, 0);
    try_legal("fence.i",               32'h0000100F, 0);
    try_legal("wfi",                   32'h10500073, 0);
    end_sect();
  endtask

  // =============================================================================
  //  T5: C + F at every alignment
  // =============================================================================
  task automatic fp_block(input bit shifted);
    pclear();
    if (shifted) e16(C_NOP());
    e32(ADDI(31, 0, 32'h100));
    e16(C_LI(8, 5)); setf(1, 32'h3F800000); setf(2, 32'h40000000); e16(C_ADDI(8, 3));
    e32(FADD(4, 1, 2)); e16(C_NOP()); e32(FMADD(5, 1, 2, 4)); e32(FSW(5, 31, 0)); e16(C_LI(9, 1));
    e32(FLW(6, 31, 0)); e32(FDIV(7, 6, 2)); e16(C_ADD(8, 9)); e32(FCVT_W_S(10, 7)); e16(C_MV(11, 10));
    e32(CSRRS(12, FFLAGS, 0));
    pend(); exec(500);
    chk("f4", gf(4), 32'h40400000); chk("f5", gf(5), 32'h40A00000); chk("f6", gf(6), 32'h40A00000);
    chk("f7 = 2.5", gf(7), 32'h40200000); chk("x8 = 9", gx(8), 64'd9);
    chk("x10 = rne(2.5) = 2", gx(10), 64'd2); chk("x11", gx(11), 64'd2); chk("x12 = NX", gx(12), 64'd1);
  endtask

  task automatic t_c_fp();
    begin_sect("compressed + FP, 4-byte aligned and 2-byte misaligned instruction streams");
    fp_block(1'b0);
    fp_block(1'b1);
    end_sect();
  endtask

  // =============================================================================
  //  T6: random differential pipeline test
  // =============================================================================
  localparam int MAXI = 400;
  logic [31:0] it_w   [0:MAXI-1];
  int          it_len [0:MAXI-1];
  int          it_br  [0:MAXI-1];
  int          it_f3  [0:MAXI-1];
  int          it_rs1 [0:MAXI-1];
  int          it_rs2 [0:MAXI-1];
  int          n_items;
  logic [63:0] init_x [0:31];
  logic [31:0] init_f [0:31];
  logic [31:0] sp_tab [0:15];

  logic [63:0] sx   [0:1][0:31];
  logic [31:0] sf   [0:1][0:31];
  logic [4:0]  sfl  [0:1];
  logic [2:0]  sfrm [0:1];
  logic [7:0]  smem [0:1][0:127];

  function automatic int ir(); ir = 5 + rnd_range(8); endfunction
  function automatic int fr(); fr = 1 + rnd_range(8); endfunction
  function automatic [2:0] rmsel();
    if (rnd_range(6) == 0) rmsel = 3'b111; else rmsel = 3'(rnd_range(5));
  endfunction

  task automatic gen_item(input int i, input bit allow_br);
    int r, a, b, c, d, e, k, sz, off, f3, sh;
    logic [31:0] w;
    r = rnd_range(100);
    if (!allow_br && r >= 94 && r < 97) r = 20;
    a = ir(); b = ir(); c = ir(); d = fr(); e = fr();
    if (rnd_range(10) == 0) b = 0;
    it_len[i] = 4; it_br[i] = 0; w = NOP32();
    if (r < 18) begin                                              // integer reg-reg
      k = rnd_range(15);
      case (k)
        0: w = encR(7'h00, c, b, 3'b000, a, OP_REG);  1: w = encR(7'h20, c, b, 3'b000, a, OP_REG);
        2: w = encR(7'h00, c, b, 3'b001, a, OP_REG);  3: w = encR(7'h00, c, b, 3'b010, a, OP_REG);
        4: w = encR(7'h00, c, b, 3'b011, a, OP_REG);  5: w = encR(7'h00, c, b, 3'b100, a, OP_REG);
        6: w = encR(7'h00, c, b, 3'b101, a, OP_REG);  7: w = encR(7'h20, c, b, 3'b101, a, OP_REG);
        8: w = encR(7'h00, c, b, 3'b110, a, OP_REG);  9: w = encR(7'h00, c, b, 3'b111, a, OP_REG);
        10: w = encR(7'h00, c, b, 3'b000, a, OP_REG_32); 11: w = encR(7'h20, c, b, 3'b000, a, OP_REG_32);
        12: w = encR(7'h00, c, b, 3'b001, a, OP_REG_32); 13: w = encR(7'h00, c, b, 3'b101, a, OP_REG_32);
        default: w = encR(7'h20, c, b, 3'b101, a, OP_REG_32);
      endcase
    end else if (r < 25) begin                                     // integer immediate
      k = rnd_range(11); off = rnd_range(4096); sh = rnd_range(64);
      case (k)
        0: w = encI(off, b, 3'b000, a, OP_IMM);   1: w = encI(off, b, 3'b010, a, OP_IMM);
        2: w = encI(off, b, 3'b011, a, OP_IMM);   3: w = encI(off, b, 3'b100, a, OP_IMM);
        4: w = encI(off, b, 3'b110, a, OP_IMM);   5: w = encI(off, b, 3'b111, a, OP_IMM);
        6: w = encI(sh, b, 3'b001, a, OP_IMM);    7: w = encI(sh, b, 3'b101, a, OP_IMM);
        8: w = encI(32'h400 | sh, b, 3'b101, a, OP_IMM);
        9: w = encI(off, b, 3'b000, a, OP_IMM_32);
        default: w = encI(sh % 32, b, 3'b001, a, OP_IMM_32);
      endcase
    end else if (r < 32) begin                                     // M extension
      k = rnd_range(13);
      if (k < 8) w = encR(7'h01, c, b, 3'(k), a, OP_REG);
      else case (k)
        8:  w = encR(7'h01, c, b, 3'b000, a, OP_REG_32);  9:  w = encR(7'h01, c, b, 3'b100, a, OP_REG_32);
        10: w = encR(7'h01, c, b, 3'b101, a, OP_REG_32);  11: w = encR(7'h01, c, b, 3'b110, a, OP_REG_32);
        default: w = encR(7'h01, c, b, 3'b111, a, OP_REG_32);
      endcase
    end else if (r < 38) begin                                     // integer load
      f3 = rnd_range(7); sz = 1 << (f3 & 3); off = rnd_range(120 / sz) * sz;
      w = encI(off, 31, 3'(f3), a, OP_LOAD);
    end else if (r < 43) begin                                     // integer store
      f3 = rnd_range(4); sz = 1 << f3; off = rnd_range(120 / sz) * sz;
      w = encS(off, b, 31, 3'(f3), OP_STORE);
    end else if (r < 48) begin                                     // flw / fsw
      off = rnd_range(30) * 4;
      if (rnd_range(2) == 0) w = encI(off, 31, 3'b010, d, OP_LOAD_FP);
      else                   w = encS(off, d, 31, 3'b010, OP_STORE_FP);
    end else if (r < 71) begin                                     // FP arithmetic
      k = rnd_range(9);
      case (k)
        0: w = encR(7'h00, e, d, rmsel(), fr(), OP_FP);
        1: w = encR(7'h04, e, d, rmsel(), fr(), OP_FP);
        2: w = encR(7'h08, e, d, rmsel(), fr(), OP_FP);
        3: w = encR(7'h0C, e, d, rmsel(), fr(), OP_FP);
        4: w = encR(7'h2C, 0, d, rmsel(), fr(), OP_FP);
        5: w = encR4(OP_FMADD,  fr(), e, d, rmsel(), fr());
        6: w = encR4(OP_FMSUB,  fr(), e, d, rmsel(), fr());
        7: w = encR4(OP_FNMSUB, fr(), e, d, rmsel(), fr());
        default: w = encR4(OP_FNMADD, fr(), e, d, rmsel(), fr());
      endcase
    end else if (r < 76) begin                                     // sgnj / min / max
      k = rnd_range(5);
      if (k < 3) w = encR(7'h10, e, d, 3'(k), fr(), OP_FP);
      else       w = encR(7'h14, e, d, 3'(k - 3), fr(), OP_FP);
    end else if (r < 81) begin                                     // conversions / moves
      k = rnd_range(10);
      if (k < 4)       w = encR(7'h60, k, d, rmsel(), a, OP_FP);
      else if (k < 8)  w = encR(7'h68, k - 4, b, rmsel(), d, OP_FP);
      else if (k == 8) w = encR(7'h70, 0, d, 3'b000, a, OP_FP);
      else             w = encR(7'h78, 0, b, 3'b000, d, OP_FP);
    end else if (r < 86) begin                                     // compare / class
      k = rnd_range(4);
      case (k)
        0: w = encR(7'h50, e, d, 3'b010, a, OP_FP);
        1: w = encR(7'h50, e, d, 3'b001, a, OP_FP);
        2: w = encR(7'h50, e, d, 3'b000, a, OP_FP);
        default: w = encR(7'h70, 0, d, 3'b001, a, OP_FP);
      endcase
    end else if (r < 90) begin                                     // CSR
      k = rnd_range(5);
      case (k)
        0: w = CSRRS(a, FFLAGS, 0);
        1: w = CSRRWI(0, FRM, rnd_range(5));
        2: w = CSRRSI(a, FFLAGS, rnd_range(32));
        3: w = CSRRCI(a, FFLAGS, rnd_range(32));
        default: w = CSRRS(a, FCSR, 0);
      endcase
    end else if (r < 94) begin                                     // compressed
      it_len[i] = 2; k = rnd_range(12);
      off = rnd_range(15) - 7; if (off == 0) off = 1;
      case (k)
        0: w = {16'h0, C_ADDI(a, off)};      1: w = {16'h0, C_MV(a, b == 0 ? 5 : b)};
        2: w = {16'h0, C_ADD(a, c == 0 ? 6 : c)};
        3: w = {16'h0, C_ALU(rnd_range(4), rnd_range(5), rnd_range(5))};
        4: w = {16'h0, C_LI(a, off)};        5: w = {16'h0, C_SLLI(a, 1 + rnd_range(31))};
        6: w = {16'h0, C_LDSP(a, rnd_range(15) * 8)};  7: w = {16'h0, C_SDSP(b, rnd_range(15) * 8)};
        8: w = {16'h0, C_LWSP(a, rnd_range(30) * 4)};  9: w = {16'h0, C_SWSP(b, rnd_range(30) * 4)};
        10: w = {16'h0, C_NOP()};
        default: w = {16'h0, C_ADDI(a, off)};
      endcase
    end else if (r < 97) begin                                     // forward branch over the next item
      it_br[i] = 1;
      case (rnd_range(6))
        0: it_f3[i] = 0; 1: it_f3[i] = 1; 2: it_f3[i] = 4; 3: it_f3[i] = 5; 4: it_f3[i] = 6; default: it_f3[i] = 7;
      endcase
      it_rs1[i] = b; it_rs2[i] = c;
    end else begin                                                 // extra FMA / fdiv pressure
      if (rnd_range(2) == 0) w = encR4(OP_FMADD, fr(), e, d, rmsel(), fr());
      else                   w = encR(7'h0C, e, d, rmsel(), fr(), OP_FP);
    end
    it_w[i] = w;
  endtask

  task automatic gen_program(input int n);
    int i, k;
    n_items = n;
    for (i = 5; i <= 12; i++) begin
      k = rnd_range(7);
      case (k)
        0: init_x[i] = 64'd0;          1: init_x[i] = 64'd1;       2: init_x[i] = 64'hFFFFFFFFFFFFFFFF;
        3: init_x[i] = {rnd(), rnd()}; 4: init_x[i] = {32'h0, rnd()};
        5: init_x[i] = rnd_range(256); default: init_x[i] = {{32{rnd_range(2) == 1}}, rnd()};
      endcase
    end
    for (i = 1; i <= 8; i++) begin
      if (rnd_range(3) == 0) init_f[i] = rnd(); else init_f[i] = sp_tab[rnd_range(16)];
    end
    for (i = 0; i < n; i++) gen_item(i, (i < n - 2) && (i == 0 || it_br[i-1] == 0));
  endtask

  task automatic emit_preamble();
    int i;
    pclear();
    e32(ADDI(31, 0, 32'h100)); e32(ADDI(2, 0, 32'h100));
    for (i = 5; i <= 12; i++) li64(i, init_x[i]);
    for (i = 1; i <= 8; i++)  setf(i, init_f[i]);
    for (i = 0; i < 16; i++)  e32(SD(5 + (i % 8), 31, i * 8));
    e32(CSRRWI(0, FFLAGS, 0)); e32(CSRRWI(0, FRM, 0));
  endtask

  task automatic layout_items(input int pad);
    int i, p, cur;
    int addr [0:MAXI];
    cur = plen * 2;
    for (i = 0; i < n_items; i++) begin
      addr[i] = cur;
      cur = cur + it_len[i] + pad * 4;
    end
    addr[n_items] = cur;
    for (i = 0; i < n_items; i++) begin
      if (it_br[i] != 0)       e32(encB(addr[i+2] - addr[i], it_rs2[i], it_rs1[i], 3'(it_f3[i])));
      else if (it_len[i] == 4) e32(it_w[i]);
      else                     e16(it_w[i][15:0]);
      for (p = 0; p < pad; p++) e32(NOP32());
    end
  endtask

  task automatic snap(input int idx);
    int i;
    for (i = 1; i < 32; i++) sx[idx][i] = dut.regfile_inst.regs[i];
    for (i = 0; i < 32; i++) sf[idx][i] = dut.fp_regfile_inst.regs[i];
    sfl[idx]  = dut.fcsr_inst.fflags;
    sfrm[idx] = dut.fcsr_inst.frm;
    for (i = 0; i < 128; i++) smem[idx][i] = dut.dmem_inst.mem[12'h100 + i];
  endtask

  task automatic run_random(input int seed);
    int i, bad;
    string tag;
    rng_s = 32'h9E3779B9 ^ (seed * 32'h85EBCA6B);
    if (rng_s == 0) rng_s = 1;
    for (i = 0; i < 8; i++) void'(rnd());
    gen_program(120);
    for (i = 0; i < 2; i++) begin
      emit_preamble();
      layout_items(i == 0 ? 0 : 3);
      pend();
      exec(40000);
      chk1($sformatf("seed %0d run %0d: no illegal-instruction trap", seed, i), illegal_cnt == 0);
      snap(i);
    end
    bad = 0;
    for (i = 1; i < 32; i++) if (sx[0][i] !== sx[1][i]) begin
      bad++; if (bad < 4) $display("  seed %0d: x%0d dense=%h gapped=%h", seed, i, sx[0][i], sx[1][i]);
    end
    for (i = 0; i < 32; i++) if (sf[0][i] !== sf[1][i]) begin
      bad++; if (bad < 4) $display("  seed %0d: f%0d dense=%h gapped=%h", seed, i, sf[0][i], sf[1][i]);
    end
    if (sfl[0]  !== sfl[1])  begin bad++; $display("  seed %0d: fflags dense=%h gapped=%h", seed, sfl[0], sfl[1]); end
    if (sfrm[0] !== sfrm[1]) begin bad++; $display("  seed %0d: frm dense=%h gapped=%h", seed, sfrm[0], sfrm[1]); end
    for (i = 0; i < 128; i++) if (smem[0][i] !== smem[1][i]) begin
      bad++; if (bad < 4) $display("  seed %0d: mem[0x%0h] dense=%h gapped=%h", seed, 12'h100 + i, smem[0][i], smem[1][i]);
    end
    chk1($sformatf("seed %0d: dense and gapped runs agree (re-run with +SEED=%0d)", seed, seed), bad == 0);
  endtask

  task automatic t_random(input int nseeds, input int one_seed);
    int s;
    begin_sect("random differential pipeline test (dense vs NOP-gapped)");
    if (one_seed >= 0) run_random(one_seed);
    else for (s = 1; s <= nseeds; s++) run_random(s);
    end_sect();
  endtask

  // =============================================================================
  //  T7: FP golden vectors
  // =============================================================================
  localparam int MAXVEC = 120000;
  logic [223:0] vecmem [0:MAXVEC-1];
  string        opname [0:27];
  int unsigned  v_tot  [0:27];
  int unsigned  v_fail [0:27];
  int unsigned  v_resf [0:27];
  int unsigned  v_flgf [0:27];

  function automatic bit is_int_dest(input fpu_op_e op);
    is_int_dest = (op == FPU_CVT_W_S) || (op == FPU_CVT_WU_S) || (op == FPU_CVT_L_S) || (op == FPU_CVT_LU_S) ||
                  (op == FPU_MV_X_W)  || (op == FPU_EQ) || (op == FPU_LT) || (op == FPU_LE) || (op == FPU_CLASS);
  endfunction

  function automatic [31:0] enc_fp(input fpu_op_e op, input [2:0] rm);
    case (op)
      FPU_ADD:      enc_fp = encR(7'h00, 2, 1, rm, 4, OP_FP);
      FPU_SUB:      enc_fp = encR(7'h04, 2, 1, rm, 4, OP_FP);
      FPU_MUL:      enc_fp = encR(7'h08, 2, 1, rm, 4, OP_FP);
      FPU_DIV:      enc_fp = encR(7'h0C, 2, 1, rm, 4, OP_FP);
      FPU_SQRT:     enc_fp = encR(7'h2C, 0, 1, rm, 4, OP_FP);
      FPU_MADD:     enc_fp = encR4(OP_FMADD,  3, 2, 1, rm, 4);
      FPU_MSUB:     enc_fp = encR4(OP_FMSUB,  3, 2, 1, rm, 4);
      FPU_NMSUB:    enc_fp = encR4(OP_FNMSUB, 3, 2, 1, rm, 4);
      FPU_NMADD:    enc_fp = encR4(OP_FNMADD, 3, 2, 1, rm, 4);
      FPU_SGNJ:     enc_fp = encR(7'h10, 2, 1, 3'b000, 4, OP_FP);
      FPU_SGNJN:    enc_fp = encR(7'h10, 2, 1, 3'b001, 4, OP_FP);
      FPU_SGNJX:    enc_fp = encR(7'h10, 2, 1, 3'b010, 4, OP_FP);
      FPU_MIN:      enc_fp = encR(7'h14, 2, 1, 3'b000, 4, OP_FP);
      FPU_MAX:      enc_fp = encR(7'h14, 2, 1, 3'b001, 4, OP_FP);
      FPU_CVT_W_S:  enc_fp = encR(7'h60, 0, 1, rm, 11, OP_FP);
      FPU_CVT_WU_S: enc_fp = encR(7'h60, 1, 1, rm, 11, OP_FP);
      FPU_CVT_L_S:  enc_fp = encR(7'h60, 2, 1, rm, 11, OP_FP);
      FPU_CVT_LU_S: enc_fp = encR(7'h60, 3, 1, rm, 11, OP_FP);
      FPU_CVT_S_W:  enc_fp = encR(7'h68, 0, 5, rm, 4, OP_FP);
      FPU_CVT_S_WU: enc_fp = encR(7'h68, 1, 5, rm, 4, OP_FP);
      FPU_CVT_S_L:  enc_fp = encR(7'h68, 2, 5, rm, 4, OP_FP);
      FPU_CVT_S_LU: enc_fp = encR(7'h68, 3, 5, rm, 4, OP_FP);
      FPU_MV_X_W:   enc_fp = encR(7'h70, 0, 1, 3'b000, 11, OP_FP);
      FPU_MV_W_X:   enc_fp = encR(7'h78, 0, 5, 3'b000, 4, OP_FP);
      FPU_EQ:       enc_fp = encR(7'h50, 2, 1, 3'b010, 11, OP_FP);
      FPU_LT:       enc_fp = encR(7'h50, 2, 1, 3'b001, 11, OP_FP);
      FPU_LE:       enc_fp = encR(7'h50, 2, 1, 3'b000, 11, OP_FP);
      default:      enc_fp = encR(7'h70, 0, 1, 3'b001, 11, OP_FP);      // FPU_CLASS
    endcase
  endfunction

  task automatic build_vec(input fpu_op_e op, input logic [7:0] rmm, input logic [63:0] a,
                           input logic [31:0] b, input logic [31:0] c);
    logic [2:0] rm;
    bit int_src, need_b, need_c;
    pclear();
    int_src = (op == FPU_CVT_S_W) || (op == FPU_CVT_S_WU) || (op == FPU_CVT_S_L) || (op == FPU_CVT_S_LU) || (op == FPU_MV_W_X);
    need_c  = (op == FPU_MADD) || (op == FPU_MSUB) || (op == FPU_NMSUB) || (op == FPU_NMADD);
    need_b  = need_c || (op == FPU_ADD) || (op == FPU_SUB) || (op == FPU_MUL) || (op == FPU_DIV) ||
              (op == FPU_SGNJ) || (op == FPU_SGNJN) || (op == FPU_SGNJX) || (op == FPU_MIN) || (op == FPU_MAX) ||
              (op == FPU_EQ) || (op == FPU_LT) || (op == FPU_LE);
    if (int_src) li64(5, a);
    else begin li32(5, a[31:0]); e32(FMV_W_X(1, 5)); end
    if (need_b) begin li32(6, b); e32(FMV_W_X(2, 6)); end
    if (need_c) begin li32(7, c); e32(FMV_W_X(3, 7)); end
    if (rmm >= 8) begin rm = 3'b111; e32(CSRRWI(0, FRM, int'(rmm) - 8)); end
    else rm = rmm[2:0];
    e32(enc_fp(op, rm));
    e32(CSRRS(10, FFLAGS, 0));
    pend();
  endtask

  task automatic t_vectors(input int step, input bit verbose);
    int i, nvec, ran;
    logic [223:0] w;
    fpu_op_e op;
    logic [7:0]  rmm, expfl;
    logic [63:0] a, expres, got;
    logic [31:0] b, c;
    bit rfail, ffail;
    int unsigned printed;
    begin_sect("RV64F golden vectors (fp_vectors.hex)");
    for (i = 0; i < 28; i++) begin v_tot[i] = 0; v_fail[i] = 0; v_resf[i] = 0; v_flgf[i] = 0; end
    $readmemh("fp_vectors.hex", vecmem);
    nvec = 0;
    while (nvec < MAXVEC && (^vecmem[nvec]) !== 1'bx) nvec = nvec + 1;
    $display("     %0d vectors loaded, running every %0d-th", nvec, step);
    ran = 0; printed = 0;
    for (i = 0; i < nvec; i = i + step) begin
      w = vecmem[i];
      op = fpu_op_e'(w[220:216]); rmm = w[215:208]; expfl = w[207:200];
      a = w[191:128]; b = w[127:96]; c = w[95:64]; expres = w[63:0];
      build_vec(op, rmm, a, b, c);
      start_cpu(); run_end(600);
      if (is_int_dest(op)) got = gx(11); else begin got = {32'h0, gf(4)}; expres = {32'h0, expres[31:0]}; end
      rfail = (got !== expres);
      ffail = (gx(10) !== {56'h0, expfl}) || (dut.fcsr_inst.fflags !== expfl[4:0]);
      n_checks++; ran++; v_tot[op]++;
      if (rfail || ffail || timed_out || illegal_cnt != 0) begin
        n_fail++; v_fail[op]++;
        if (rfail) v_resf[op]++;
        if (ffail) v_flgf[op]++;
        if (verbose || v_fail[op] <= 6)
          $display("  FAIL vec#%0d %s rm=%0d%s a=%h b=%h c=%h | exp res=%h fl=%05b | got res=%h fl=%05b%s%s",
                   i, opname[op], (rmm >= 8) ? rmm - 8 : rmm, (rmm >= 8) ? "(dyn)" : "",
                   a, b, c, expres, expfl[4:0], got, gx(10)[4:0],
                   timed_out ? " TIMEOUT" : "", (illegal_cnt != 0) ? " ILLEGAL-TRAP" : "");
      end
    end
    $display("     per-op summary (vectors / failing / result-mismatch / flag-mismatch):");
    for (i = 0; i < 28; i++)
      if (v_tot[i] != 0)
        $display("       %-12s %6d %6d %6d %6d", opname[i], v_tot[i], v_fail[i], v_resf[i], v_flgf[i]);
    end_sect();
  endtask

  // =============================================================================
  //  main
  // =============================================================================
  int step_arg, seeds_arg, seed_arg;

  initial begin
    sp_tab[0]  = 32'h3F800000; sp_tab[1]  = 32'hBF800000; sp_tab[2]  = 32'h40000000; sp_tab[3]  = 32'h00000000;
    sp_tab[4]  = 32'h80000000; sp_tab[5]  = 32'h7F800000; sp_tab[6]  = 32'hFF800000; sp_tab[7]  = 32'h7FC00000;
    sp_tab[8]  = 32'h7F800001; sp_tab[9]  = 32'h00000001; sp_tab[10] = 32'h007FFFFF; sp_tab[11] = 32'h7F7FFFFF;
    sp_tab[12] = 32'h3F000000; sp_tab[13] = 32'h40400000; sp_tab[14] = 32'h3DCCCCCD; sp_tab[15] = 32'h4B800000;
    opname[0]="FADD"; opname[1]="FSUB"; opname[2]="FMUL"; opname[3]="FDIV"; opname[4]="FSQRT";
    opname[5]="FMADD"; opname[6]="FMSUB"; opname[7]="FNMSUB"; opname[8]="FNMADD";
    opname[9]="FSGNJ"; opname[10]="FSGNJN"; opname[11]="FSGNJX"; opname[12]="FMIN"; opname[13]="FMAX";
    opname[14]="FCVT.W.S"; opname[15]="FCVT.WU.S"; opname[16]="FCVT.L.S"; opname[17]="FCVT.LU.S";
    opname[18]="FCVT.S.W"; opname[19]="FCVT.S.WU"; opname[20]="FCVT.S.L"; opname[21]="FCVT.S.LU";
    opname[22]="FMV.X.W"; opname[23]="FMV.W.X"; opname[24]="FEQ"; opname[25]="FLT"; opname[26]="FLE";
    opname[27]="FCLASS";

    step_arg = 1; seeds_arg = 40; seed_arg = -1;
    void'($value$plusargs("QUICK=%d", step_arg));
    void'($value$plusargs("SEEDS=%d", seeds_arg));
    void'($value$plusargs("SEED=%d",  seed_arg));
    if (step_arg < 1) step_arg = 1;

    rst_n = 1'b0;
    repeat (4) @(negedge clk);

    t_bringup();
    t_fp_directed();
    t_fcsr();
    t_illegal();
    t_c_fp();
    t_random(seeds_arg, seed_arg);
    t_vectors(step_arg, $test$plusargs("VERBOSE"));

    $display("");
    $display("==============================================================");
    $display(" %0d checks, %0d FAILED  ->  %s", n_checks, n_fail, (n_fail == 0) ? "ALL TESTS PASSED" : "TEST FAILED");
    $display("==============================================================");
    $finish;
  end

  // global watchdog (200M cycles)
  initial begin
    #2_000_000_000;
    $display("GLOBAL TIMEOUT");
    $finish;
  end

endmodule