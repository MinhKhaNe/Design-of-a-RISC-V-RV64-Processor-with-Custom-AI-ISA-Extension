import rv64imafc_pkg::*;

module fpu #(
    parameter int FMA_CYCLES = 2
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        req,       // idex_valid && is_fpu && !illegal
    input  fpu_op_e     op,
    input  logic [2:0]  rm,        // already resolved (dyn -> frm), 0..4
    input  logic [63:0] a,         // rs1: FP reg in [31:0], or integer reg
    input  logic [31:0] b,         // rs2 (FP)
    input  logic [31:0] c,         // rs3 (FP)

    output logic        busy,
    output logic [63:0] result,
    output logic [4:0]  flags      // {NV, DZ, OF, UF, NX}; valid when req && !busy
);

  localparam logic [31:0] QNAN = 32'h7FC00000;

  // ------------------------------------------------------------------
  // op classification
  // ------------------------------------------------------------------
  function automatic logic is_slow_op(fpu_op_e o);
    case (o)
      FPU_SGNJ, FPU_SGNJN, FPU_SGNJX, FPU_MIN, FPU_MAX,
      FPU_MV_X_W, FPU_MV_W_X, FPU_EQ, FPU_LT, FPU_LE, FPU_CLASS: is_slow_op = 1'b0;
      default:                                                   is_slow_op = 1'b1;
    endcase
  endfunction

  function automatic logic is_iter_op(fpu_op_e o);
    is_iter_op = (o == FPU_DIV) || (o == FPU_SQRT);
  endfunction

  function automatic logic is_fma_op(fpu_op_e o);
    case (o)
      FPU_ADD, FPU_SUB, FPU_MUL, FPU_MADD, FPU_MSUB, FPU_NMSUB, FPU_NMADD: is_fma_op = 1'b1;
      default:                                                              is_fma_op = 1'b0;
    endcase
  endfunction

  function automatic logic is_f2i_op(fpu_op_e o);
    is_f2i_op = (o == FPU_CVT_W_S) || (o == FPU_CVT_WU_S) || (o == FPU_CVT_L_S) || (o == FPU_CVT_LU_S);
  endfunction

  function automatic logic is_i2f_op(fpu_op_e o);
    is_i2f_op = (o == FPU_CVT_S_W) || (o == FPU_CVT_S_WU) || (o == FPU_CVT_S_L) || (o == FPU_CVT_S_LU);
  endfunction

  function automatic logic [6:0] clz64(input logic [63:0] x);
    clz64 = 7'd64;
    for (int i = 0; i < 64; i++) if (x[i]) clz64 = 7'(63 - i);
  endfunction

  // ------------------------------------------------------------------
  // FSM + operand latches
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {S_IDLE, S_INIT, S_RUN, S_DONE} state_e;
  state_e      state;
  logic [5:0]  cnt;
  fpu_op_e     op_q;
  logic [2:0]  rm_q;
  logic [63:0] a_q;
  logic [31:0] b_q, c_q;

  logic slow_live;
  assign slow_live = is_slow_op(op);
  assign busy = ((state == S_IDLE) && req && slow_live) || (state == S_INIT) || (state == S_RUN);

  // ------------------------------------------------------------------
  // Slow-path operand selection
  // ------------------------------------------------------------------
  logic        is_addsub, neg_p, neg_c, mul_only;
  logic [31:0] a_f, b_f, c_f;

  assign is_addsub = (op_q == FPU_ADD) || (op_q == FPU_SUB);
  assign neg_p     = (op_q == FPU_NMSUB) || (op_q == FPU_NMADD);
  assign neg_c     = (op_q == FPU_SUB) || (op_q == FPU_MSUB) || (op_q == FPU_NMADD);
  assign mul_only  = (op_q == FPU_MUL);
  assign a_f       = a_q[31:0];
  assign b_f       = is_addsub ? 32'h3F800000 : b_q;     // fadd/fsub = fma(a, 1.0, +-b)
  assign c_f       = is_addsub ? b_q : c_q;

  logic              a_sign, a_zero, a_inf, a_nan, a_snan;
  logic              b_sign, b_zero, b_inf, b_nan, b_snan;
  logic              c_sign, c_zero, c_inf, c_nan, c_snan;
  logic [23:0]       a_sig, b_sig, c_sig;
  logic signed [11:0] a_e, b_e, c_e;

  fp_unpack ua (.x(a_f), .sign(a_sign), .zero(a_zero), .inf(a_inf), .nan(a_nan), .snan(a_snan), .sig_n(a_sig), .e_n(a_e));
  fp_unpack ub (.x(b_f), .sign(b_sign), .zero(b_zero), .inf(b_inf), .nan(b_nan), .snan(b_snan), .sig_n(b_sig), .e_n(b_e));
  fp_unpack uc (.x(c_f), .sign(c_sign), .zero(c_zero), .inf(c_inf), .nan(c_nan), .snan(c_snan), .sig_n(c_sig), .e_n(c_e));

  // ------------------------------------------------------------------
  // FMA datapath  (a*b +/- c, single rounding)
  // ------------------------------------------------------------------
  logic        fma_spec;            // result is a special case, bypass rounder
  logic [31:0] fma_spec_res;
  logic        fma_spec_nv;
  logic        fma_rsign;
  logic signed [11:0] fma_e;
  logic [63:0] fma_m;

  always_comb begin : fma_path
    logic        sp, sc, nan_in, snan_in, inf_zero, p_inf, c_inf_e, clash, czero, p_big, eff_sub;
    logic [47:0] P, Mp, Mc, big_M, small_M;
    logic signed [11:0] xp, xc, d, x_big;
    logic [11:0] sh;
    logic [50:0] big_f, small_f, small_al;
    logic [51:0] sum, Sn;
    logic [6:0]  lz;

    sp       = a_sign ^ b_sign ^ neg_p;
    sc       = c_sign ^ neg_c;
    nan_in   = a_nan | b_nan | (c_nan & ~mul_only);
    snan_in  = a_snan | b_snan | (c_snan & ~mul_only);
    inf_zero = (a_inf & b_zero) | (a_zero & b_inf);
    p_inf    = a_inf | b_inf;
    c_inf_e  = c_inf & ~mul_only;
    clash    = p_inf & c_inf_e & (sp != sc);

    fma_spec     = 1'b1;
    fma_spec_nv  = 1'b0;
    fma_spec_res = QNAN;
    fma_rsign    = 1'b0;
    fma_e        = 12'sd0;
    fma_m        = 64'b0;
    P = '0; Mp = '0; Mc = '0; big_M = '0; small_M = '0;
    xp = '0; xc = '0; d = '0; x_big = '0; sh = '0;
    big_f = '0; small_f = '0; small_al = '0; sum = '0; Sn = '0; lz = '0;
    czero = 1'b0; p_big = 1'b1; eff_sub = 1'b0;

    if (nan_in | inf_zero | clash) begin
      fma_spec_res = QNAN;
      fma_spec_nv  = snan_in | inf_zero | clash;
    end else if (p_inf) begin
      fma_spec_res = {sp, 8'hFF, 23'b0};
    end else if (c_inf_e) begin
      fma_spec_res = {sc, 8'hFF, 23'b0};
    end else if (a_zero | b_zero) begin
      if (mul_only)      fma_spec_res = {sp, 31'b0};
      else if (c_zero)   fma_spec_res = {(sp == sc) ? sp : (rm_q == 3'b010), 31'b0};
      else               fma_spec_res = {sc, c_f[30:0]};
    end else begin
      fma_spec = 1'b0;
      P  = 48'(a_sig) * 48'(b_sig);
      xp = a_e + b_e;
      if (!P[47]) begin P = P << 1; xp = xp - 12'sd1; end
      Mp    = P;
      czero = mul_only | c_zero;
      Mc    = {c_sig, 24'b0};
      xc    = c_e - 12'sd24;
      d     = xp - xc;
      p_big = czero | (d > 12'sd0) | ((d == 12'sd0) & (Mp >= Mc));
      big_M   = p_big ? Mp : Mc;
      small_M = czero ? 48'b0 : (p_big ? Mc : Mp);
      x_big   = p_big ? xp : xc;
      fma_rsign = p_big ? sp : sc;
      eff_sub = czero ? 1'b0 : (sp ^ sc);
      sh      = d[11] ? 12'(-d) : 12'(d);
      big_f   = {big_M, 3'b0};
      small_f = {small_M, 3'b0};
      if (sh == 12'd0)        small_al = small_f;
      else if (sh >= 12'd51)  small_al = {50'b0, |small_M};
      else begin
        small_al    = small_f >> sh[5:0];
        small_al[0] = small_al[0] | (|(small_f & ((51'd1 << sh[5:0]) - 51'd1)));
      end
      sum = eff_sub ? ({1'b0, big_f} - {1'b0, small_al}) : ({1'b0, big_f} + {1'b0, small_al});
      if (sum == 52'b0) begin
        fma_spec     = 1'b1;                              // exact cancellation
        fma_spec_res = {(rm_q == 3'b010), 31'b0};
      end else begin
        lz = 7'd52;
        for (int i = 0; i < 52; i++) if (sum[i]) lz = 7'(51 - i);
        Sn    = sum << lz;
        fma_e = x_big + 12'sd175 - $signed({5'b0, lz});
        fma_m = {Sn, 12'b0};
      end
    end
  end

  // ------------------------------------------------------------------
  // FDIV datapath
  // ------------------------------------------------------------------
  logic [25:0] dv_r;
  logic [23:0] dv_d;
  logic [26:0] dv_q;

  logic        div_spec, div_spec_nv, div_spec_dz;
  logic [31:0] div_spec_res;
  logic        div_rsign;
  logic signed [11:0] div_e;
  logic [63:0] div_m;
  logic        div_sticky;

  always_comb begin : div_path
    div_rsign    = a_sign ^ b_sign;
    div_spec     = 1'b1;
    div_spec_nv  = 1'b0;
    div_spec_dz  = 1'b0;
    div_spec_res = QNAN;
    if (a_nan | b_nan | (a_inf & b_inf) | (a_zero & b_zero)) begin
      div_spec_nv = a_snan | b_snan | (a_inf & b_inf) | (a_zero & b_zero);
    end else if (a_inf) begin
      div_spec_res = {div_rsign, 8'hFF, 23'b0};
    end else if (b_inf) begin
      div_spec_res = {div_rsign, 31'b0};
    end else if (b_zero) begin
      div_spec_res = {div_rsign, 8'hFF, 23'b0};
      div_spec_dz  = 1'b1;
    end else if (a_zero) begin
      div_spec_res = {div_rsign, 31'b0};
    end else begin
      div_spec = 1'b0;
    end
    div_e      = a_e - b_e + 12'sd127 - (dv_q[26] ? 12'sd0 : 12'sd1);
    div_m      = dv_q[26] ? {dv_q, 37'b0} : {dv_q[25:0], 38'b0};
    div_sticky = |dv_r;
  end

  // ------------------------------------------------------------------
  // FSQRT datapath
  // ------------------------------------------------------------------
  logic [53:0] sq_rad;
  logic [31:0] sq_rem;
  logic [26:0] sq_root;

  logic        sqrt_spec, sqrt_spec_nv;
  logic [31:0] sqrt_spec_res;
  logic signed [11:0] sqrt_e, sqrt_e2;
  logic [24:0] sqrt_mp;
  logic [63:0] sqrt_m;
  logic        sqrt_sticky;

  always_comb begin : sqrt_path
    sqrt_spec     = 1'b1;
    sqrt_spec_nv  = 1'b0;
    sqrt_spec_res = QNAN;
    if (a_nan) begin
      sqrt_spec_nv = a_snan;
    end else if (a_zero) begin
      sqrt_spec_res = a_f;
    end else if (a_sign) begin
      sqrt_spec_nv = 1'b1;
    end else if (a_inf) begin
      sqrt_spec_res = a_f;
    end else begin
      sqrt_spec = 1'b0;
    end
    sqrt_mp     = a_e[0] ? {a_sig, 1'b0} : {1'b0, a_sig};
    sqrt_e2     = a_e[0] ? (a_e - 12'sd1) : a_e;
    sqrt_e      = (sq_root[26] ? 12'sd26 : 12'sd25) - 12'sd14 + (sqrt_e2 >>> 1) + 12'sd127;
    sqrt_m      = sq_root[26] ? {sq_root, 37'b0} : {sq_root[25:0], 38'b0};
    sqrt_sticky = |sq_rem;
  end

  // ------------------------------------------------------------------
  // int -> float
  // ------------------------------------------------------------------
  logic        i2f_zero, i2f_sign;
  logic signed [11:0] i2f_e;
  logic [63:0] i2f_m;

  always_comb begin : i2f_path
    logic [63:0] v, mag;
    logic [6:0]  lz;
    case (op_q)
      FPU_CVT_S_W:  begin v = {{32{a_q[31]}}, a_q[31:0]}; i2f_sign = v[63]; end
      FPU_CVT_S_WU: begin v = {32'b0, a_q[31:0]};         i2f_sign = 1'b0;  end
      FPU_CVT_S_L:  begin v = a_q;                        i2f_sign = v[63]; end
      default:      begin v = a_q;                        i2f_sign = 1'b0;  end
    endcase
    mag      = i2f_sign ? (~v + 64'd1) : v;
    i2f_zero = (mag == 64'b0);
    lz       = clz64(mag);
    i2f_m    = mag << lz[5:0];
    i2f_e    = 12'sd190 - $signed({5'b0, lz});
  end

  // ------------------------------------------------------------------
  // float -> int
  // ------------------------------------------------------------------
  logic [63:0] f2i_res;
  logic        f2i_nv, f2i_nx;

  always_comb begin : f2i_path
    logic        is64, sgnd, big, ovf, g, s;
    logic signed [11:0] k, rs;
    logic [23:0] sig;
    logic [63:0] mag, val, maxp, minn, v;
    logic [64:0] mag_r, pos_lim;
    logic [48:0] t, tsh;
    logic        up;

    is64 = (op_q == FPU_CVT_L_S) || (op_q == FPU_CVT_LU_S);
    sgnd = (op_q == FPU_CVT_W_S) || (op_q == FPU_CVT_L_S);
    if (sgnd) pos_lim = is64 ? 65'h0_7FFF_FFFF_FFFF_FFFF : 65'h0_0000_0000_7FFF_FFFF;
    else      pos_lim = is64 ? 65'h0_FFFF_FFFF_FFFF_FFFF : 65'h0_0000_0000_FFFF_FFFF;
    maxp = pos_lim[63:0];
    minn = sgnd ? (is64 ? 64'h8000_0000_0000_0000 : 64'h0000_0000_8000_0000) : 64'b0;

    sig  = {(a_f[30:23] != 8'd0), a_f[22:0]};
    k    = $signed({4'b0, (a_f[30:23] == 8'd0) ? 8'd1 : a_f[30:23]}) - 12'sd127;
    rs   = 12'sd23 - k;
    big  = (k >= 12'sd64);
    mag = 64'b0; g = 1'b0; s = 1'b0; t = '0; tsh = '0;
    if (big) begin
      mag = 64'b0;
    end else if (k >= 12'sd23) begin
      mag = 64'(sig) << (k - 12'sd23);
    end else if (rs > 12'sd26) begin
      s = (sig != 24'b0);
    end else begin
      t   = {sig, 25'b0};
      tsh = t >> rs[4:0];
      mag = 64'(tsh[48:25]);
      g   = tsh[24];
      s   = (|tsh[23:0]) | (|(t & ((49'd1 << rs[4:0]) - 49'd1)));
    end
    case (rm_q)
      3'b000:  up = g & (s | mag[0]);
      3'b001:  up = 1'b0;
      3'b010:  up = a_sign & (g | s);
      3'b011:  up = ~a_sign & (g | s);
      3'b100:  up = g;
      default: up = 1'b0;
    endcase
    mag_r = {1'b0, mag} + {64'b0, up};
    if (sgnd) ovf = big | (!a_sign & (mag_r > pos_lim)) | (a_sign & (mag_r > pos_lim + 65'd1));
    else      ovf = big | (!a_sign & (mag_r > pos_lim)) | (a_sign & (mag_r != 65'd0));
    if (sgnd) val = a_sign ? (~mag_r[63:0] + 64'd1) : mag_r[63:0];
    else      val = a_sign ? 64'b0 : mag_r[63:0];

    f2i_nv = 1'b0;
    f2i_nx = 1'b0;
    if (a_nan || (a_inf && !a_sign)) begin
      v = maxp; f2i_nv = 1'b1;
    end else if (a_inf) begin
      v = minn; f2i_nv = 1'b1;
    end else if (ovf) begin
      v = a_sign ? minn : maxp; f2i_nv = 1'b1;
    end else begin
      v = val; f2i_nx = g | s;
    end
    f2i_res = is64 ? v : {{32{v[31]}}, v[31:0]};
  end

  // ------------------------------------------------------------------
  // shared rounder
  // ------------------------------------------------------------------
  logic               rnd_sign, rnd_sticky;
  logic signed [11:0] rnd_e;
  logic [63:0]        rnd_m;
  logic [31:0]        rnd_res;
  logic               rnd_nx, rnd_uf, rnd_of;

  always_comb begin
    if (is_fma_op(op_q)) begin
      rnd_sign = fma_rsign; rnd_e = fma_e;  rnd_m = fma_m;  rnd_sticky = 1'b0;
    end else if (op_q == FPU_DIV) begin
      rnd_sign = div_rsign; rnd_e = div_e;  rnd_m = div_m;  rnd_sticky = div_sticky;
    end else if (op_q == FPU_SQRT) begin
      rnd_sign = 1'b0;      rnd_e = sqrt_e; rnd_m = sqrt_m; rnd_sticky = sqrt_sticky;
    end else begin
      rnd_sign = i2f_sign;  rnd_e = i2f_e;  rnd_m = i2f_m;  rnd_sticky = 1'b0;
    end
  end

  fp_round rounder (
      .sign(rnd_sign), .e(rnd_e), .m(rnd_m), .sticky_in(rnd_sticky), .rm(rm_q),
      .res(rnd_res), .nx(rnd_nx), .uf(rnd_uf), .of(rnd_of)
  );

  // ------------------------------------------------------------------
  // slow-op result mux
  // ------------------------------------------------------------------
  logic [63:0] slow_res;
  logic [4:0]  slow_flags;

  always_comb begin
    slow_res   = {32'b0, rnd_res};
    slow_flags = {1'b0, 1'b0, rnd_of, rnd_uf, rnd_nx};
    if (is_fma_op(op_q)) begin
      if (fma_spec) begin
        slow_res   = {32'b0, fma_spec_res};
        slow_flags = {fma_spec_nv, 4'b0};
      end
    end else if (op_q == FPU_DIV) begin
      if (div_spec) begin
        slow_res   = {32'b0, div_spec_res};
        slow_flags = {div_spec_nv, div_spec_dz, 3'b0};
      end
    end else if (op_q == FPU_SQRT) begin
      if (sqrt_spec) begin
        slow_res   = {32'b0, sqrt_spec_res};
        slow_flags = {sqrt_spec_nv, 4'b0};
      end
    end else if (is_i2f_op(op_q)) begin
      if (i2f_zero) begin
        slow_res   = 64'b0;
        slow_flags = 5'b0;
      end
    end else begin                                   // f2i
      slow_res   = f2i_res;
      slow_flags = {f2i_nv, 3'b0, f2i_nx};
    end
  end

  // ------------------------------------------------------------------
  // Fast ops (live operands)
  // ------------------------------------------------------------------
  logic              fa_sign, fa_zero, fa_inf, fa_nan, fa_snan;
  logic              fb_sign, fb_zero, fb_inf, fb_nan, fb_snan;
  logic [23:0]       fa_sig, fb_sig;
  logic signed [11:0] fa_e, fb_e;
  logic [31:0]       fa, fb;
  assign fa = a[31:0];
  assign fb = b;

  fp_unpack ufa (.x(fa), .sign(fa_sign), .zero(fa_zero), .inf(fa_inf), .nan(fa_nan), .snan(fa_snan), .sig_n(fa_sig), .e_n(fa_e));
  fp_unpack ufb (.x(fb), .sign(fb_sign), .zero(fb_zero), .inf(fb_inf), .nan(fb_nan), .snan(fb_snan), .sig_n(fb_sig), .e_n(fb_e));

  logic [63:0] fast_res;
  logic [4:0]  fast_flags;

  always_comb begin : fast_path
    logic less, less_mm, both_zero, unordered, eq;
    logic [9:0] cls;
    fast_res   = 64'b0;
    fast_flags = 5'b0;
    both_zero  = fa_zero & fb_zero;
    unordered  = fa_nan | fb_nan;
    if (fa_sign != fb_sign) less = fa_sign;
    else if (fa_sign)       less = (fa[30:0] > fb[30:0]);
    else                    less = (fa[30:0] < fb[30:0]);
    less_mm = less;                  // min/max: -0 < +0
    if (both_zero) less = 1'b0;      // compares: -0 == +0
    eq = !unordered && ((fa == fb) || both_zero);

    cls = 10'b0;
    if (fa_nan)                       cls[fa_snan ? 8 : 9] = 1'b1;
    else if (fa_inf)                  cls[fa_sign ? 0 : 7] = 1'b1;
    else if (fa_zero)                 cls[fa_sign ? 3 : 4] = 1'b1;
    else if (fa[30:23] == 8'd0)       cls[fa_sign ? 2 : 5] = 1'b1;
    else                              cls[fa_sign ? 1 : 6] = 1'b1;

    case (op)
      FPU_SGNJ:  fast_res = {32'b0, fb[31],            fa[30:0]};
      FPU_SGNJN: fast_res = {32'b0, ~fb[31],           fa[30:0]};
      FPU_SGNJX: fast_res = {32'b0, fa[31] ^ fb[31],   fa[30:0]};
      FPU_MIN, FPU_MAX: begin
        fast_flags[4] = fa_snan | fb_snan;
        if (fa_nan && fb_nan)  fast_res = {32'b0, QNAN};
        else if (fa_nan)       fast_res = {32'b0, fb};
        else if (fb_nan)       fast_res = {32'b0, fa};
        else if (op == FPU_MIN) fast_res = {32'b0, less_mm ? fa : fb};
        else                    fast_res = {32'b0, less_mm ? fb : fa};
      end
      FPU_MV_X_W: fast_res = {{32{fa[31]}}, fa};
      FPU_MV_W_X: fast_res = {32'b0, a[31:0]};
      FPU_EQ: begin
        fast_res      = {63'b0, eq};
        fast_flags[4] = fa_snan | fb_snan;
      end
      FPU_LT: begin
        fast_res      = {63'b0, !unordered & less};
        fast_flags[4] = unordered;
      end
      FPU_LE: begin
        fast_res      = {63'b0, !unordered & (less | eq)};
        fast_flags[4] = unordered;
      end
      FPU_CLASS: fast_res = {54'b0, cls};
      default: ;
    endcase
  end

  assign result = slow_live ? slow_res   : fast_res;
  assign flags  = slow_live ? slow_flags : fast_flags;

  // ------------------------------------------------------------------
  // Sequencer
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE;
      cnt   <= 6'd0;
    end else begin
      case (state)
        S_IDLE: if (req && slow_live) begin
          op_q <= op;
          rm_q <= rm;
          a_q  <= a;
          b_q  <= b;
          c_q  <= c;
          if (is_iter_op(op)) state <= S_INIT;
          else begin
            state <= S_RUN;
            cnt   <= 6'(FMA_CYCLES - 1);
          end
        end

        S_INIT: begin
          if (op_q == FPU_DIV) begin
            dv_r <= {2'b0, a_sig};
            dv_d <= b_sig;
            dv_q <= 27'b0;
          end else begin
            sq_rad  <= {1'b0, sqrt_mp, 28'b0};
            sq_rem  <= 32'b0;
            sq_root <= 27'b0;
          end
          state <= S_RUN;
          cnt   <= 6'd26;
        end

        S_RUN: begin
          if (op_q == FPU_DIV) begin
            logic bit_q;
            bit_q = (dv_r >= {2'b0, dv_d});
            dv_q <= {dv_q[25:0], bit_q};
            dv_r <= (bit_q ? (dv_r - {2'b0, dv_d}) : dv_r) << 1;
          end else if (op_q == FPU_SQRT) begin
            logic [31:0] rem_t, trial;
            rem_t = {sq_rem[29:0], sq_rad[53:52]};
            trial = {3'b0, sq_root, 2'b01};
            sq_rad <= sq_rad << 2;
            if (rem_t >= trial) begin
              sq_rem  <= rem_t - trial;
              sq_root <= {sq_root[25:0], 1'b1};
            end else begin
              sq_rem  <= rem_t;
              sq_root <= {sq_root[25:0], 1'b0};
            end
          end
          if (cnt == 6'd0) state <= S_DONE;
          else             cnt   <= cnt - 6'd1;
        end

        S_DONE: state <= S_IDLE;
      endcase
    end
  end

endmodule