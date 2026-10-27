import rv64imafc_pkg::*;

// Multiplier configuration (the defaults reproduce the original iterative unit bit-for-bit and cycle-for-cycle).
// Override from the simulator command line with  +define+MUL_MODE_VAL=1  etc., or by instance parameters.
//
//   MUL_MODE = 0  ITER : original iterative multiplier, 16 bits per cycle (IDLE + 4 + DONE -> 5 stall cycles)
//              1  COMB : one 64x64 multiplier in EX, no stall                          (largest, longest path)
//              2  LAT  : latency MODEL for design-space sweeps: operands are latched and the result (taken from a
//                        combinational multiplier) is presented after MUL_STALL stall cycles.  It is NOT an area
//                        model - use ITER / COMB / MULW_* for area and Fmax numbers.
//   MULW_FAST  = 1   mulw (32x32 low half only, ~528 partial-product bits) is combinational in EX: no stall
//   MULW_SHORT = 1   ITER mode only: mulw needs just the 2 low 16-bit chunks -> 3 stall cycles instead of 5, no extra area
`ifndef MUL_MODE_VAL
  `define MUL_MODE_VAL 0
`endif
`ifndef MUL_STALL_VAL
  `define MUL_STALL_VAL 3
`endif
`ifndef MULW_FAST_VAL
  `define MULW_FAST_VAL 0
`endif
`ifndef MULW_SHORT_VAL
  `define MULW_SHORT_VAL 0
`endif

module mul_div_unit #(
    parameter int MUL_MODE   = `MUL_MODE_VAL,
    parameter int MUL_STALL  = `MUL_STALL_VAL,     // MUL_MODE = 2 only, >= 1
    parameter bit MULW_FAST  = `MULW_FAST_VAL,
    parameter bit MULW_SHORT = `MULW_SHORT_VAL
) (
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

  // Divider datapath
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

  state_e       state, state_n;
  logic [6:0]   cyc_left;
  logic         op_is_mul_q;
  logic         sel_is_signed, sel_is_word;
  logic [63:0]  sel_a_ext, sel_b_ext;
  logic         sel_a_neg, sel_b_neg;
  logic [63:0]  sel_a_mag, sel_b_mag;
  logic         sel_div_by_zero, sel_overflow;
  div_op_e      div_op_q;
  logic         div_is_word_q;
  logic         div_quot_neg, div_rem_neg;
  logic         div_by_zero_q, div_overflow_q;
  logic [63:0]  div_a_ext_q;               
  logic [63:0]  div_r_reg, div_q_reg, div_d_reg;
  logic [63:0]  div_r_shifted;
  logic [64:0]  div_trial;
  logic [127:0] mul_corrected;
  logic [63:0]  mul_result;
  logic [63:0]  div_quot_signed, div_rem_signed, div_result_full, div_result;
  // Multiplier datapath
  logic [63:0]  mul_a_q;         // multiplicand, fixed for the whole op
  logic [63:0]  mul_b_orig_q;    // original multiplier, kept for sign fixup
  logic [63:0]  mplier;          // shifts left 16 bits/cycle (MSB chunk first)
  logic [127:0] acc;             // running 128-bit product accumulator
  mul_op_e      mul_op_q;
  logic [79:0]  mul_partial;

  // ---------------------------------------------------------------------
  // Multiplier variants
  // ---------------------------------------------------------------------
  // Full-width combinational multiply, all five RV64M multiply ops, one shared 65x65 signed array.
  function automatic logic [63:0] mul_full(input logic [63:0] x, input logic [63:0] y, input mul_op_e op);
    logic                sx, sy;
    logic signed [64:0]  mx, my;
    logic signed [129:0] p;
    sx = (op == MUL_MULH) || (op == MUL_MULHSU);            // rs1 signed
    sy = (op == MUL_MULH);                                  // rs2 signed
    mx = {sx & x[63], x};
    my = {sy & y[63], y};
    p  = mx * my;
    case (op)
      MUL_MUL:  mul_full = p[63:0];
      MUL_MULW: mul_full = {{32{p[31]}}, p[31:0]};
      default:  mul_full = p[127:64];                       // MULH / MULHSU / MULHU
    endcase
  endfunction

  // mulw only needs the low 32 bits of a 32x32 product (about 528 partial-product bits instead of 4096)
  function automatic logic [63:0] mulw_fast(input logic [63:0] x, input logic [63:0] y);
    logic [31:0] w;
    w = x[31:0] * y[31:0];
    mulw_fast = {{32{w[31]}}, w};
  endfunction

  logic        is_mulw, fast_now, req_fsm, lat_one;
  logic [63:0] fast_result, lat_result;

  assign is_mulw     = (mul_op == MUL_MULW);
  assign fast_now    = is_mul && ((MUL_MODE == 1) || (MULW_FAST && is_mulw));   // finishes in the cycle it enters EX
  assign req_fsm     = req && !fast_now;                                         // only the other ops use the FSM
  assign lat_one     = is_mul && (MUL_MODE == 2) && (MUL_STALL == 1);           // LAT model with 1 stall: IDLE -> DONE
  assign fast_result = (MULW_FAST && is_mulw) ? mulw_fast(a, b) : mul_full(a, b, mul_op);
  assign lat_result  = mul_full(mul_a_q, mul_b_orig_q, mul_op_q);

  assign result      = fast_now ? fast_result :
                       op_is_mul_q ? ((MUL_MODE == 2) ? lat_result : mul_result) : div_result;
  assign div_r_shifted    = {div_r_reg[62:0], div_q_reg[63]};
  assign div_trial        = {1'b0, div_r_shifted} - {1'b0, div_d_reg};
  assign sel_is_signed    = op_is_signed_div(div_op);
  assign sel_is_word      = op_is_word_div(div_op);
  assign sel_a_ext        = sel_is_word ? (sel_is_signed ? {{32{a[31]}}, a[31:0]} : {32'b0, a[31:0]}) : a;
  assign sel_b_ext        = sel_is_word ? (sel_is_signed ? {{32{b[31]}}, b[31:0]} : {32'b0, b[31:0]}) : b;
  assign sel_a_neg        = sel_is_signed && sel_a_ext[63];
  assign sel_b_neg        = sel_is_signed && sel_b_ext[63];
  assign sel_a_mag        = sel_a_neg ? (~sel_a_ext + 64'd1) : sel_a_ext;
  assign sel_b_mag        = sel_b_neg ? (~sel_b_ext + 64'd1) : sel_b_ext;
  assign sel_div_by_zero  = (sel_b_ext == 64'b0);
  assign sel_overflow     = sel_is_signed &&  (sel_a_ext == 64'h8000_0000_0000_0000) &&
                                              (sel_b_ext == 64'hFFFF_FFFF_FFFF_FFFF);
  assign busy             = (state == S_IDLE && req_fsm) || (state == S_RUN);
  assign done             = (state == S_DONE);
  assign mul_partial      = mul_a_q * mplier[63:48];   // 64 x 16 -> 80

  // Shared control FSM
  always_comb begin
    state_n = state;
    unique case (state)
      S_IDLE:  if (req_fsm)         state_n = lat_one ? S_DONE : S_RUN;
      S_RUN:   if (cyc_left == 7'd0) state_n = S_DONE;
      S_DONE:                        state_n = S_IDLE;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) 
      state <= S_IDLE;
    else        
      state <= state_n;
  end

  // Sequencer: latch operands on entry, iterate for the rest
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cyc_left <= 7'd0;
    end else if (state == S_IDLE && req_fsm) begin
      op_is_mul_q <= is_mul;
      if (is_mul) begin
        mul_op_q     <= mul_op;
        mul_a_q      <= a;
        mul_b_orig_q <= b;
        acc          <= 128'b0;
        if (MUL_MODE == 2) begin                    // latency model: (MUL_STALL - 1) RUN cycles, or none for MUL_STALL = 1
          mplier   <= b;
          cyc_left <= 7'((MUL_STALL > 1) ? MUL_STALL - 2 : 0);
        end else if (MULW_SHORT && (mul_op == MUL_MULW)) begin
          mplier   <= {b[31:0], 32'b0};             // only the low 32 multiplier bits matter: 2 chunks, MSB chunk first
          cyc_left <= 7'd1;
        end else begin                              // original behaviour
          mplier   <= b;
          cyc_left <= 7'(MUL_CYCLES - 1);
        end
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

  // Result mux (combinational; only consumed by the caller while done=1)
  always_comb begin
    unique case (mul_op_q)
      MUL_MULH:   mul_corrected = acc - (mul_a_q[63]      ? ({64'b0, mul_b_orig_q} << 64) : 128'b0)
                                       - (mul_b_orig_q[63] ? ({64'b0, mul_a_q}      << 64) : 128'b0);
      MUL_MULHSU: mul_corrected = acc - (mul_a_q[63]      ? ({64'b0, mul_b_orig_q} << 64) : 128'b0);
      default:    mul_corrected = acc;   // MUL, MULHU, MULW need no correction
    endcase
  end

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

endmodule