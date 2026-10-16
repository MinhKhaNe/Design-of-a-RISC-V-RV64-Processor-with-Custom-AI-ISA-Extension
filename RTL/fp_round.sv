module fp_round (
    input  logic               sign,
    input  logic signed [11:0] e,
    input  logic [63:0]        m,
    input  logic               sticky_in,
    input  logic [2:0]         rm,      // 000 RNE 001 RTZ 010 RDN 011 RUP 100 RMM
    output logic [31:0]        res,
    output logic               nx,
    output logic               uf,
    output logic               of
);

  function automatic logic round_up(input logic [2:0] rm_i, input logic sgn,
                                    input logic g, input logic s, input logic lsb);
    case (rm_i)
      3'b000:  round_up = g & (s | lsb);
      3'b001:  round_up = 1'b0;
      3'b010:  round_up = sgn & (g | s);
      3'b011:  round_up = ~sgn & (g | s);
      3'b100:  round_up = g;
      default: round_up = 1'b0;
    endcase
  endfunction

  logic signed [11:0] shift_s;
  logic [5:0]         shift;
  logic [63:0]        ms;
  logic               sh_sticky;
  logic [23:0]        sig;
  logic               g, s, inex, rup;
  logic [24:0]        sig_r;
  logic [7:0]         efield;
  logic [22:0]        frac;
  logic signed [11:0] e_r;
  logic [23:0]        sig_u;
  logic               g_u, s_u, rup_u, carry_u, tiny;

  always_comb begin
    // ---- sub-normal alignment ----
    shift_s = 12'sd1 - e;
    shift   = shift_s[5:0];
    if (e >= 12'sd1) begin
      ms = m;                         sh_sticky = 1'b0;
    end else if (shift_s >= 12'sd64) begin
      ms = 64'b0;                     sh_sticky = 1'b1;
    end else begin
      ms        = m >> shift;
      sh_sticky = |(m & ((64'd1 << shift) - 64'd1));
    end

    sig  = ms[63:40];
    g    = ms[39];
    s    = (|ms[38:0]) | sh_sticky | sticky_in;
    inex = g | s;
    rup  = round_up(rm, sign, g, s, sig[0]);
    sig_r = {1'b0, sig} + {24'b0, rup};

    // ---- pack ----
    if (e >= 12'sd1) begin
      if (sig_r[24]) begin e_r = e + 12'sd1; frac = 23'b0; end
      else           begin e_r = e;          frac = sig_r[22:0]; end
      efield = e_r[7:0];
    end else begin
      e_r    = 12'sd0;
      efield = {7'b0, sig_r[23]};     // rounded up into the minimum normal
      frac   = sig_r[22:0];
    end
    of = (e >= 12'sd1) && (e_r >= 12'sd255);

    // ---- tininess after rounding (unbounded exponent range) ----
    sig_u   = m[63:40];
    g_u     = m[39];
    s_u     = (|m[38:0]) | sticky_in;
    rup_u   = round_up(rm, sign, g_u, s_u, sig_u[0]);
    carry_u = (&sig_u) & rup_u;
    tiny    = (e < 12'sd1) && !((e == 12'sd0) && carry_u);
    uf      = inex & tiny & ~of;
    nx      = inex | of;

    if (of) begin
      if (rm == 3'b000 || rm == 3'b100 || (rm == 3'b010 && sign) || (rm == 3'b011 && !sign))
        res = {sign, 8'hFF, 23'b0};
      else
        res = {sign, 8'hFE, 23'h7FFFFF};
    end else begin
      res = {sign, efield, frac};
    end
  end

endmodule