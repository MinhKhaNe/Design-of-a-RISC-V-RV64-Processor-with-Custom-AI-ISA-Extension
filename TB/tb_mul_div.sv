// ===========================================================================
// Comprehensive RV64M testbench for mul_div_unit.
//
// Verification strategy: every result is checked against an independent
// golden-model function written with SystemVerilog's own signed/unsigned
// arithmetic (not a copy of the RTL's algorithm), so this genuinely
// cross-checks the implementation rather than restating it.
//
//   1. A corner-case operand-pair list is run through *every* mul_op_e /
//      div_op_e variant (so e.g. the {MIN,-1} overflow pair is exercised
//      against DIV, DIVU, REM, REMU, DIVW, DIVUW, REMW and REMUW alike).
//   2. A second list of pairs targets the 32-bit boundary specifically for
//      the *W ops, including garbage upper 32 bits to confirm they're
//      correctly ignored.
//   3. A randomized sweep (RAND_ITERS per op) adds broad coverage on top
//      of the hand-picked corners.
// ===========================================================================
import rv64im_pkg::*;

module tb_mul_div;

  // -------------------------------------------------------------------
  // DUT
  // -------------------------------------------------------------------
  logic clk = 0, rst_n = 0;
  logic req, is_mul, is_div;
  mul_op_e mul_op;
  div_op_e div_op;
  logic [63:0] a, b;
  logic busy, done;
  logic [63:0] result;

  mul_div_unit dut (
      .clk(clk), .rst_n(rst_n),
      .req(req), .is_mul(is_mul), .is_div(is_div),
      .mul_op(mul_op), .div_op(div_op),
      .a(a), .b(b),
      .busy(busy), .done(done), .result(result)
  );

  always #5 clk = ~clk;

  int errors = 0;
  int checks = 0;

  // -------------------------------------------------------------------
  // Golden model (independent of the RTL's internal algorithm)
  // -------------------------------------------------------------------
  function automatic logic [63:0] g_mul(logic [63:0] a_, b_);
    logic [127:0] au, bu, prod;
    au = {64'b0, a_}; bu = {64'b0, b_}; prod = au * bu;
    g_mul = prod[63:0];
  endfunction

  function automatic logic [63:0] g_mulhu(logic [63:0] a_, b_);
    logic [127:0] au, bu, prod;
    au = {64'b0, a_}; bu = {64'b0, b_}; prod = au * bu;
    g_mulhu = prod[127:64];
  endfunction

  function automatic logic [63:0] g_mulh(logic [63:0] a_, b_);
    logic signed [127:0] as_, bs_, prod;
    as_ = {{64{a_[63]}}, a_};
    bs_ = {{64{b_[63]}}, b_};
    prod = as_ * bs_;
    g_mulh = prod[127:64];
  endfunction

  function automatic logic [63:0] g_mulhsu(logic [63:0] a_, b_);
    logic signed [127:0] as_, bu_, prod;
    as_ = {{64{a_[63]}}, a_};   // sign-extend a
    bu_ = {64'b0, b_};          // zero-extend b (top bit 0 -> safe as signed too)
    prod = as_ * bu_;
    g_mulhsu = prod[127:64];
  endfunction

  function automatic logic [63:0] g_mulw(logic [63:0] a_, b_);
    logic [63:0] au, bu, prod;
    logic [31:0] res32;
    au = {32'b0, a_[31:0]}; bu = {32'b0, b_[31:0]}; prod = au * bu;
    res32 = prod[31:0];
    g_mulw = {{32{res32[31]}}, res32};
  endfunction

  function automatic logic [63:0] g_div(logic [63:0] a_, b_);
    if (b_ == 64'b0) g_div = 64'hFFFF_FFFF_FFFF_FFFF;
    else if (a_ == 64'h8000_0000_0000_0000 && b_ == 64'hFFFF_FFFF_FFFF_FFFF) g_div = a_;
    else g_div = $unsigned($signed(a_) / $signed(b_));
  endfunction

  function automatic logic [63:0] g_rem(logic [63:0] a_, b_);
    if (b_ == 64'b0) g_rem = a_;
    else if (a_ == 64'h8000_0000_0000_0000 && b_ == 64'hFFFF_FFFF_FFFF_FFFF) g_rem = 64'b0;
    else g_rem = $unsigned($signed(a_) % $signed(b_));
  endfunction

  function automatic logic [63:0] g_divu(logic [63:0] a_, b_);
    if (b_ == 64'b0) g_divu = 64'hFFFF_FFFF_FFFF_FFFF;
    else g_divu = a_ / b_;
  endfunction

  function automatic logic [63:0] g_remu(logic [63:0] a_, b_);
    if (b_ == 64'b0) g_remu = a_;
    else g_remu = a_ % b_;
  endfunction

  function automatic logic [63:0] g_divw(logic [63:0] a_, b_);
    logic signed [31:0] a32, b32, q32;
    a32 = a_[31:0]; b32 = b_[31:0];
    if (b32 == 32'b0) g_divw = 64'hFFFF_FFFF_FFFF_FFFF;
    else if (a32 == 32'h8000_0000 && b32 == -32'sd1) g_divw = {{32{a32[31]}}, a32};
    else begin
      q32 = a32 / b32;
      g_divw = {{32{q32[31]}}, q32};
    end
  endfunction

  function automatic logic [63:0] g_remw(logic [63:0] a_, b_);
    logic signed [31:0] a32, b32, r32;
    a32 = a_[31:0]; b32 = b_[31:0];
    if (b32 == 32'b0) g_remw = {{32{a32[31]}}, a32};
    else if (a32 == 32'h8000_0000 && b32 == -32'sd1) g_remw = 64'b0;
    else begin
      r32 = a32 % b32;
      g_remw = {{32{r32[31]}}, r32};
    end
  endfunction

  function automatic logic [63:0] g_divuw(logic [63:0] a_, b_);
    logic [31:0] a32, b32, q32;
    a32 = a_[31:0]; b32 = b_[31:0];
    if (b32 == 32'b0) g_divuw = 64'hFFFF_FFFF_FFFF_FFFF;
    else begin
      q32 = a32 / b32;
      g_divuw = {{32{q32[31]}}, q32};
    end
  endfunction

  function automatic logic [63:0] g_remuw(logic [63:0] a_, b_);
    logic [31:0] a32, b32, r32;
    a32 = a_[31:0]; b32 = b_[31:0];
    if (b32 == 32'b0) g_remuw = {{32{a32[31]}}, a32};
    else begin
      r32 = a32 % b32;
      g_remuw = {{32{r32[31]}}, r32};
    end
  endfunction

  function automatic logic [63:0] golden_mul(mul_op_e op, logic [63:0] a_, b_);
    unique case (op)
      MUL_MUL:    golden_mul = g_mul(a_, b_);
      MUL_MULH:   golden_mul = g_mulh(a_, b_);
      MUL_MULHSU: golden_mul = g_mulhsu(a_, b_);
      MUL_MULHU:  golden_mul = g_mulhu(a_, b_);
      MUL_MULW:   golden_mul = g_mulw(a_, b_);
    endcase
  endfunction

  function automatic logic [63:0] golden_div(div_op_e op, logic [63:0] a_, b_);
    unique case (op)
      DIV_DIV:   golden_div = g_div(a_, b_);
      DIV_DIVU:  golden_div = g_divu(a_, b_);
      DIV_REM:   golden_div = g_rem(a_, b_);
      DIV_REMU:  golden_div = g_remu(a_, b_);
      DIV_DIVW:  golden_div = g_divw(a_, b_);
      DIV_DIVUW: golden_div = g_divuw(a_, b_);
      DIV_REMW:  golden_div = g_remw(a_, b_);
      DIV_REMUW: golden_div = g_remuw(a_, b_);
    endcase
  endfunction

  function automatic string mul_op_name(mul_op_e op);
    unique case (op)
      MUL_MUL:    mul_op_name = "MUL";
      MUL_MULH:   mul_op_name = "MULH";
      MUL_MULHSU: mul_op_name = "MULHSU";
      MUL_MULHU:  mul_op_name = "MULHU";
      MUL_MULW:   mul_op_name = "MULW";
    endcase
  endfunction

  function automatic string div_op_name(div_op_e op);
    unique case (op)
      DIV_DIV:   div_op_name = "DIV";
      DIV_DIVU:  div_op_name = "DIVU";
      DIV_REM:   div_op_name = "REM";
      DIV_REMU:  div_op_name = "REMU";
      DIV_DIVW:  div_op_name = "DIVW";
      DIV_DIVUW: div_op_name = "DIVUW";
      DIV_REMW:  div_op_name = "REMW";
      DIV_REMUW: div_op_name = "REMUW";
    endcase
  endfunction

  // -------------------------------------------------------------------
  // Drivers
  // -------------------------------------------------------------------
  task automatic check_mul(mul_op_e op, logic [63:0] av, bv);
    logic [63:0] expected;
    expected = golden_mul(op, av, bv);
    is_mul = 1; is_div = 0; mul_op = op; a = av; b = bv; req = 1;
    @(posedge clk);
    while (busy) @(posedge clk);
    #1;
    checks++;
    if (result !== expected) begin
      errors++;
      $display("FAIL %s: a=%h b=%h -> got %h expected %h", mul_op_name(op), av, bv, result, expected);
    end
    req = 0; is_mul = 0;
    @(posedge clk);
  endtask

  task automatic check_div(div_op_e op, logic [63:0] av, bv);
    logic [63:0] expected;
    expected = golden_div(op, av, bv);
    is_mul = 0; is_div = 1; div_op = op; a = av; b = bv; req = 1;
    @(posedge clk);
    while (busy) @(posedge clk);
    #1;
    checks++;
    if (result !== expected) begin
      errors++;
      $display("FAIL %s: a=%h b=%h -> got %h expected %h", div_op_name(op), av, bv, result, expected);
    end
    req = 0; is_div = 0;
    @(posedge clk);
  endtask

  // -------------------------------------------------------------------
  // Corner-case operand pairs
  // -------------------------------------------------------------------
  localparam int N_GENERIC = 25;
  logic [63:0] generic_a [0:N_GENERIC-1];
  logic [63:0] generic_b [0:N_GENERIC-1];

  localparam int N_WORD = 10;
  logic [63:0] word_a [0:N_WORD-1];
  logic [63:0] word_b [0:N_WORD-1];

  initial begin
    // ---- generic 64-bit corners: zero, one, -1, MIN, MAX, div-by-zero,
    //      overflow (MIN/-1), and sign-combination truncation checks ----
    generic_a[0]  = 64'd0;                    generic_b[0]  = 64'd0;
    generic_a[1]  = 64'd0;                    generic_b[1]  = 64'd1;
    generic_a[2]  = 64'd1;                    generic_b[2]  = 64'd0;
    generic_a[3]  = 64'hFFFF_FFFF_FFFF_FFFF;  generic_b[3]  = 64'd0;      // -1 / 0
    generic_a[4]  = 64'd5;                    generic_b[4]  = 64'd0;
    generic_a[5]  = 64'h8000_0000_0000_0000;  generic_b[5]  = 64'd0;      // MIN / 0
    generic_a[6]  = 64'h8000_0000_0000_0000;  generic_b[6]  = 64'hFFFF_FFFF_FFFF_FFFF; // MIN/-1 overflow
    generic_a[7]  = 64'h8000_0000_0000_0000;  generic_b[7]  = 64'd1;      // MIN / 1
    generic_a[8]  = 64'h7FFF_FFFF_FFFF_FFFF;  generic_b[8]  = 64'd1;      // MAX / 1
    generic_a[9]  = 64'h7FFF_FFFF_FFFF_FFFF;  generic_b[9]  = 64'hFFFF_FFFF_FFFF_FFFF; // MAX / -1
    generic_a[10] = 64'hFFFF_FFFF_FFFF_FFFF;  generic_b[10] = 64'hFFFF_FFFF_FFFF_FFFF; // -1 / -1
    generic_a[11] = 64'h8000_0000_0000_0000;  generic_b[11] = 64'h8000_0000_0000_0000; // MIN / MIN
    generic_a[12] = 64'h7FFF_FFFF_FFFF_FFFF;  generic_b[12] = 64'h7FFF_FFFF_FFFF_FFFF; // MAX / MAX
    generic_a[13] = 64'hFFFF_FFFF_FFFF_FFFF;  generic_b[13] = 64'd2;      // (unsigned huge) / 2
    generic_a[14] = 64'd2;                    generic_b[14] = 64'hFFFF_FFFF_FFFF_FFFF;
    generic_a[15] = 64'd20;                   generic_b[15] = 64'd6;
    generic_a[16] = -64'sd20;                 generic_b[16] = 64'd6;
    generic_a[17] = 64'd20;                   generic_b[17] = -64'sd6;
    generic_a[18] = -64'sd20;                 generic_b[18] = -64'sd6;
    generic_a[19] = 64'd7;                    generic_b[19] = 64'd3;
    generic_a[20] = -64'sd7;                  generic_b[20] = 64'd3;
    generic_a[21] = 64'd7;                    generic_b[21] = -64'sd3;
    generic_a[22] = -64'sd7;                  generic_b[22] = -64'sd3;
    generic_a[23] = 64'd1;                    generic_b[23] = 64'hFFFF_FFFF_FFFF_FFFF; // 1 / -1
    generic_a[24] = 64'hDEAD_BEEF_1234_5678;  generic_b[24] = 64'h0000_0000_0000_0101; // "random-ish" fixed

    // ---- 32-bit boundary corners for the *W family, with garbage upper
    //      32 bits on several entries to confirm they're ignored ----
    word_a[0] = 64'hDEAD_BEEF_8000_0000;  word_b[0] = 64'h1234_5678_FFFF_FFFF; // MIN32/-1 overflow, junk upper bits
    word_a[1] = 64'h0000_0000_8000_0000;  word_b[1] = 64'h0000_0000_0000_0000; // MIN32 / 0
    word_a[2] = 64'hFFFF_FFFF_0000_0000;  word_b[2] = 64'hFFFF_FFFF_0000_0001; // low32 a=0, junk upper -> 0/1
    word_a[3] = 64'h0000_0000_7FFF_FFFF;  word_b[3] = 64'h0000_0000_0000_0001; // MAX32 / 1
    word_a[4] = 64'h0000_0000_FFFF_FFFF;  word_b[4] = 64'h0000_0000_0000_0002; // low32 = -1 (signed) / 2, or unsigned huge/2
    word_a[5] = 64'hFFFF_FFFF_FFFF_FFFF;  word_b[5] = 64'h0000_0000_0000_0003; // low32 -1 / 3, junk upper on a
    word_a[6] = 64'h0000_0000_4000_0000;  word_b[6] = 64'h0000_0000_0000_0002; // MULW overflow-into-sign case
    word_a[7] = 64'h0000_0000_8000_0000;  word_b[7] = 64'h0000_0000_0000_0002; // low32 MIN32 * 2 (wraps to 0)
    word_a[8] = 64'hAAAA_AAAA_0000_0011;  word_b[8] = 64'h5555_5555_0000_0003; // junk upper, small low32 values
    word_a[9] = 64'h0000_0000_0000_0000;  word_b[9] = 64'h0000_0000_0000_0000;

    rst_n = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // ---- 1) every generic corner pair x every MUL op ----
    for (int p = 0; p < N_GENERIC; p++) begin
      check_mul(MUL_MUL,    generic_a[p], generic_b[p]);
      check_mul(MUL_MULH,   generic_a[p], generic_b[p]);
      check_mul(MUL_MULHSU, generic_a[p], generic_b[p]);
      check_mul(MUL_MULHU,  generic_a[p], generic_b[p]);
      check_mul(MUL_MULW,   generic_a[p], generic_b[p]);
    end

    // ---- 2) every generic corner pair x every DIV op ----
    for (int p = 0; p < N_GENERIC; p++) begin
      check_div(DIV_DIV,   generic_a[p], generic_b[p]);
      check_div(DIV_DIVU,  generic_a[p], generic_b[p]);
      check_div(DIV_REM,   generic_a[p], generic_b[p]);
      check_div(DIV_REMU,  generic_a[p], generic_b[p]);
      check_div(DIV_DIVW,  generic_a[p], generic_b[p]);
      check_div(DIV_DIVUW, generic_a[p], generic_b[p]);
      check_div(DIV_REMW,  generic_a[p], generic_b[p]);
      check_div(DIV_REMUW, generic_a[p], generic_b[p]);
    end

    // ---- 3) 32-bit boundary pairs x MULW / all *W div ops ----
    for (int p = 0; p < N_WORD; p++) begin
      check_mul(MUL_MULW,   word_a[p], word_b[p]);
      check_div(DIV_DIVW,   word_a[p], word_b[p]);
      check_div(DIV_DIVUW,  word_a[p], word_b[p]);
      check_div(DIV_REMW,   word_a[p], word_b[p]);
      check_div(DIV_REMUW,  word_a[p], word_b[p]);
    end

    $display("---- directed corners: %0d checks, %0d errors so far ----", checks, errors);

    // ---- 4) randomized sweep on top of the directed corners ----
    begin
      localparam int RAND_ITERS = 300;
      logic [63:0] ra, rb;
      mul_op_e mop;
      div_op_e dop;

      for (int i = 0; i < RAND_ITERS; i++) begin
        ra = {$urandom, $urandom};
        rb = {$urandom, $urandom};
        mop = mul_op_e'($urandom_range(0, 4));
        check_mul(mop, ra, rb);
      end

      for (int i = 0; i < RAND_ITERS; i++) begin
        ra = {$urandom, $urandom};
        rb = {$urandom, $urandom};
        // bias divisor toward small values (incl. 0) part of the time to
        // hit div-by-zero and small-quotient paths more often than a
        // uniform 64-bit random divisor would
        if (i % 4 == 0) rb = {59'b0, $urandom_range(0, 15)};
        dop = div_op_e'($urandom_range(0, 7));
        check_div(dop, ra, rb);
      end
    end

    $display("---- TOTAL: %0d checks, %0d errors ----", checks, errors);
    if (errors == 0) $display("ALL PASS");
    else              $display("*** %0d FAILURES ***", errors);
    $finish;
  end

endmodule