module fp_unpack (
    input  logic [31:0]       x,
    output logic              sign,
    output logic              zero,
    output logic              inf,
    output logic              nan,
    output logic              snan,
    output logic [23:0]       sig_n,
    output logic signed [11:0] e_n
);

  logic [7:0]  ex;
  logic [22:0] fr;
  logic [23:0] sig;
  logic [4:0]  lz;

  always_comb begin
    ex   = x[30:23];
    fr   = x[22:0];
    sign = x[31];
    zero = (ex == 8'd0)   && (fr == 23'd0);
    inf  = (ex == 8'hFF)  && (fr == 23'd0);
    nan  = (ex == 8'hFF)  && (fr != 23'd0);
    snan = nan && !fr[22];
    sig  = {(ex != 8'd0), fr};
    lz   = 5'd0;
    for (int i = 0; i < 24; i++) if (sig[i]) lz = 5'(23 - i);   // highest set bit wins
    sig_n = sig << lz;
    e_n   = $signed({4'b0, (ex == 8'd0) ? 8'd1 : ex}) - 12'sd150 - $signed({7'b0, lz});
  end

endmodule