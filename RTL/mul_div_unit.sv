import rv64im_pkg::*;

module mul_div_unit (
    input  logic         clk,
    input  logic         rst_n,

    input  logic         req,      // idex_valid && (is_mul || is_div)
    input  logic         is_mul,
    input  logic         is_div,
    input  mul_op_e      mul_op,
    input  div_op_e      div_op,
    input  logic [63:0]  a,        // rs1 (post-forwarding)
    input  logic [63:0]  b,        // rs2 (post-forwarding)

    output logic         busy,     // hold the pipeline while high
    output logic         done,     // one-cycle pulse, result valid
    output logic [63:0]  result
);

  localparam int MUL_CYCLES = 4;    // 64 bits / 16 bits-per-cycle
  localparam int DIV_CYCLES = 64;   // 1 bit per cycle, classic restoring divider

  typedef enum logic [1:0] {S_IDLE, S_RUN, S_DONE} state_e;
  state_e state, state_n;

  logic [6:0] cyc_left;
  logic       op_is_mul_q;

  // ---------------------------------------------------------------
  // Shared control FSM
  // ---------------------------------------------------------------
  always_comb begin
    state_n = state;
    unique case (state)
      S_IDLE:  if (req)             state_n = S_RUN;
      S_RUN:   if (cyc_left == 7'd0) state_n = S_DONE;
      S_DONE:                        state_n = S_IDLE;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) state <= S_IDLE;
    else        state <= state_n;

  assign busy = (state == S_IDLE && req) || (state == S_RUN);
  assign done = (state == S_DONE);

  // =================================================================
  // Multiplier datapath
  // =================================================================
  logic [63:0]  mul_a_q;         // multiplicand, fixed for the whole op
  logic [63:0]  mul_b_orig_q;    // original multiplier, kept for sign fixup
  logic [63:0]  mplier;          // shifts left 16 bits/cycle (MSB chunk first)
  logic [127:0] acc;             // running 128-bit product accumulator
  mul_op_e      mul_op_q;

  logic [79:0] mul_partial;
  assign mul_partial = mul_a_q * mplier[63:48];   // 64 x 16 -> 80

  // =================================================================
  // Divider datapath
  // =================================================================
  function automatic logic op_is_signed_div(div_op_e op);
    unique case (op)
      DIV_DIV, DIV_REM, DIV_DIVW, DIV_REMW: op_is_signed_div = 1'b1;
      default:                              op_is_signed_div = 1'b0;
    endcase
  endfunction

  function automatic logic op_is_word_div(div_op_e op);
    unique case (op)
      DIV_DIVW, DIV_DIVUW, DIV_REMW, DIV_REMUW: op_is_word_div = 1'b1;
      default:                                  op_is_word_div = 1'b0;
    endcase
  endfunction

  function automatic logic op_is_rem_div(div_op_e op);
    unique case (op)
      DIV_REM, DIV_REMU, DIV_REMW, DIV_REMUW: op_is_rem_div = 1'b1;
      default:                                op_is_rem_div = 1'b0;
    endcase
  endfunction

  // ---- operand prep (combinational off the live inputs; only latched
  //      at the exact S_IDLE&&req cycle, so it's safe to leave free-running)
  logic        sel_is_signed, sel_is_word;
  logic [63:0] sel_a_ext, sel_b_ext;
  logic        sel_a_neg, sel_b_neg;
  logic [63:0] sel_a_mag, sel_b_mag;
  logic        sel_div_by_zero, sel_overflow;

  assign sel_is_signed = op_is_signed_div(div_op);
  assign sel_is_word   = op_is_word_div(div_op);
  assign sel_a_ext = sel_is_word ? (sel_is_signed ? {{32{a[31]}}, a[31:0]} : {32'b0, a[31:0]}) : a;
  assign sel_b_ext = sel_is_word ? (sel_is_signed ? {{32{b[31]}}, b[31:0]} : {32'b0, b[31:0]}) : b;
  assign sel_a_neg = sel_is_signed && sel_a_ext[63];
  assign sel_b_neg = sel_is_signed && sel_b_ext[63];
  assign sel_a_mag = sel_a_neg ? (~sel_a_ext + 64'd1) : sel_a_ext;
  assign sel_b_mag = sel_b_neg ? (~sel_b_ext + 64'd1) : sel_b_ext;
  assign sel_div_by_zero = (sel_b_ext == 64'b0);
  assign sel_overflow    = sel_is_signed && (sel_a_ext == 64'h8000_0000_0000_0000) &&
                                            (sel_b_ext == 64'hFFFF_FFFF_FFFF_FFFF);

  div_op_e     div_op_q;
  logic        div_is_word_q;
  logic        div_quot_neg, div_rem_neg;
  logic        div_by_zero_q, div_overflow_q;
  logic [63:0] div_a_ext_q;               // extended dividend: doubles as the
                                           // div-by-zero / overflow special result
  logic [63:0] div_r_reg, div_q_reg, div_d_reg;

  logic [63:0] div_r_shifted;
  logic [64:0] div_trial;
  assign div_r_shifted = {div_r_reg[62:0], div_q_reg[63]};
  assign div_trial     = {1'b0, div_r_shifted} - {1'b0, div_d_reg};

  // =================================================================
  // Sequencer: latch operands on entry, iterate for the rest
  // =================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cyc_left <= 7'd0;
    end else if (state == S_IDLE && req) begin
      op_is_mul_q <= is_mul;
      if (is_mul) begin
        mul_op_q     <= mul_op;
        mul_a_q      <= a;
        mul_b_orig_q <= b;
        mplier       <= b;
        acc          <= 128'b0;
        cyc_left     <= 7'(MUL_CYCLES - 1);
      end else begin
        div_op_q       <= div_op;
        div_is_word_q  <= sel_is_word;
        div_quot_neg   <= sel_a_neg ^ sel_b_neg;
        div_rem_neg    <= sel_a_neg;        // remainder takes the dividend's sign
        div_by_zero_q  <= sel_div_by_zero;
        div_overflow_q <= sel_overflow;
        div_a_ext_q    <= sel_a_ext;
        div_r_reg      <= 64'b0;
        div_q_reg      <= sel_a_mag;
        div_d_reg      <= sel_b_mag;
        cyc_left       <= 7'(DIV_CYCLES - 1);
      end
    end else if (state == S_RUN) begin
      if (op_is_mul_q) begin
        acc    <= (acc << 16) + {48'b0, mul_partial};   // Horner step, MSB chunk first
        mplier <= mplier << 16;
      end else begin
        if (div_trial[64]) begin   // trial subtraction borrowed -> restore
          div_r_reg <= div_r_shifted;
          div_q_reg <= {div_q_reg[62:0], 1'b0};
        end else begin
          div_r_reg <= div_trial[63:0];
          div_q_reg <= {div_q_reg[62:0], 1'b1};
        end
      end
      if (cyc_left != 7'd0) cyc_left <= cyc_left - 7'd1;
    end
  end

  // =================================================================
  // Result mux (combinational; only consumed by the caller while done=1)
  // =================================================================
  logic [127:0] mul_corrected;
  always_comb begin
    unique case (mul_op_q)
      MUL_MULH:   mul_corrected = acc - (mul_a_q[63]      ? ({64'b0, mul_b_orig_q} << 64) : 128'b0)
                                       - (mul_b_orig_q[63] ? ({64'b0, mul_a_q}      << 64) : 128'b0);
      MUL_MULHSU: mul_corrected = acc - (mul_a_q[63]      ? ({64'b0, mul_b_orig_q} << 64) : 128'b0);
      default:    mul_corrected = acc;   // MUL, MULHU, MULW need no correction
    endcase
  end

  logic [63:0] mul_result;
  always_comb begin
    unique case (mul_op_q)
      MUL_MUL:    mul_result = acc[63:0];
      MUL_MULH:   mul_result = mul_corrected[127:64];
      MUL_MULHSU: mul_result = mul_corrected[127:64];
      MUL_MULHU:  mul_result = acc[127:64];
      MUL_MULW:   mul_result = {{32{acc[31]}}, acc[31:0]};
      default:    mul_result = acc[63:0];
    endcase
  end

  logic [63:0] div_quot_signed, div_rem_signed, div_result_full, div_result;
  always_comb begin
    div_quot_signed = div_quot_neg ? (~div_q_reg + 64'd1) : div_q_reg;
    div_rem_signed  = div_rem_neg  ? (~div_r_reg + 64'd1) : div_r_reg;

    if (div_by_zero_q)
      div_result_full = op_is_rem_div(div_op_q) ? div_a_ext_q : 64'hFFFF_FFFF_FFFF_FFFF;
    else if (div_overflow_q)
      div_result_full = op_is_rem_div(div_op_q) ? 64'b0 : div_a_ext_q;
    else
      div_result_full = op_is_rem_div(div_op_q) ? div_rem_signed : div_quot_signed;

    div_result = div_is_word_q ? {{32{div_result_full[31]}}, div_result_full[31:0]} : div_result_full;
  end

  assign result = op_is_mul_q ? mul_result : div_result;

endmodule