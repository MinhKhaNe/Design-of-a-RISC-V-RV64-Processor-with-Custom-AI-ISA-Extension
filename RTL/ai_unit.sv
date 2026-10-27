import rv64imafc_pkg::*;

// Xai: AI-acceleration instructions (opcode custom-0).  Spec = ai_verif/ai_model.py
//
//   dot8  rd, rs1, rs2        rd = sum_{i<8} s8(rs1.byte[i]) * s8(rs2.byte[i])       (sign-extended to 64 bits)
//   qrelu rd, rs1, rs2, SH    4 x int32 {rs1.lo, rs1.hi, rs2.lo, rs2.hi} -> 4 x int8 in rd[31:0], rd[63:32] = 0
//                             byte = clamp( (v + (SH ? 2^(SH-1) : 0)) >>> SH, 0, 127 )     SH = funct7[4:0]
//   max8  rd, rs1, rs2        rd.byte[i] = signed max(rs1.byte[i], rs2.byte[i])      i < 8
//
// AI_LAT = 1 : purely combinational in EX (no stall; longest path = forwarding mux -> multipliers -> adder tree)
// AI_LAT = 2 : operands are registered in the first cycle (busy = 1, one stall), the datapath then runs from the
//              registers in the second cycle.  Splits the critical path in two, costs one cycle per AI instruction.
//              Same handshake as mul_div_unit / fpu: result is valid when req && !busy.
// AI_LAT = 3 : PIPELINED across EX and MEM, no stall (busy = 0 always, one Xai instruction can issue every cycle).
//                EX  : the eight 8x8 products are computed from the forwarded operands and registered
//                      (for qrelu / max8 the two operands are registered instead);
//                MEM : the adder tree (dot8) / the qrelu / the max8 logic runs from those registers.
//              `result` is therefore valid ONE CYCLE AFTER the request (while the instruction is in MEM), and the core
//              treats an Xai instruction like a load: the result is written to MEM/WB, a consumer in the very next
//              instruction waits one bubble (hazard_unit), a consumer two or more instructions later does not wait.
//              The stage register has no enable and no reset: its content is only used when the core marks the
//              instruction in MEM as an Xai instruction.  Flip-flops: 128 + 8 (the same as AI_LAT = 2).
//
// DOT_TREE = 1 : the eight products are added by a balanced tree with pruned widths (16 -> 17 -> 18 -> 19 bit),
//                7 adders, 120 full-adder cells instead of the 8 x 32-bit serial chain of the original description.
//                The result is bit-exact (|sum| <= 8 * 128 * 128 = 2^17 fits in 19 bit signed).  DOT_TREE = 0 keeps
//                the original serial 32-bit chain.
module ai_unit #(
    parameter int AI_LAT   = 2,
    parameter bit DOT_TREE = 1'b1
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        req,       // idex_valid && is_ai && !illegal
    input  ai_op_e      op,
    input  logic [4:0]  shamt,     // qrelu shift (instr[29:25])
    input  logic [63:0] a,         // rs1 (post-forwarding)
    input  logic [63:0] b,         // rs2 (post-forwarding)

    output logic        busy,
    output logic [63:0] result
);

  // ------------------------------------------------------------------
  // Operand source: live inputs (AI_LAT=1), registered copy (AI_LAT=2), stage register (AI_LAT=3)
  // ------------------------------------------------------------------
  ai_op_e      op_u;
  logic [4:0]  sh_u;
  logic [63:0] a_u, b_u;
  wire [127:0] prod_pk;                  // the eight 16-bit signed products that feed the adder tree (packed: product i = [16*i +: 16])

  typedef enum logic {S_IDLE, S_DONE} state_e;

  // the eight signed 8x8 products of two operand vectors, packed (|p| <= 16384, fits in 16 bit signed)
  function automatic logic [127:0] dot_prods(input logic [63:0] x, input logic [63:0] y);
    logic signed [15:0] xa, xb, p;
    logic [127:0]       r;
    for (int i = 0; i < 8; i++) begin
      xa = {{8{x[8*i + 7]}}, x[8*i +: 8]};
      xb = {{8{y[8*i + 7]}}, y[8*i +: 8]};
      p  = xa * xb;
      r[16*i +: 16] = p;
    end
    return r;
  endfunction

  // sum of the eight products: balanced tree with pruned widths (16 -> 17 -> 18 -> 19 bit), exact
  function automatic logic signed [31:0] dot_tree(input logic [127:0] pk);
    logic signed [15:0] p  [8];
    logic signed [16:0] s1 [4];
    logic signed [17:0] s2 [2];
    logic signed [18:0] s3;
    for (int i = 0; i < 8; i++) p[i] = pk[16*i +: 16];
    for (int k = 0; k < 4; k++) s1[k] = 17'(p[2*k])  + 17'(p[2*k + 1]);
    for (int k = 0; k < 2; k++) s2[k] = 18'(s1[2*k]) + 18'(s1[2*k + 1]);
    s3 = 19'(s2[0]) + 19'(s2[1]);
    return 32'(s3);
  endfunction

  // the original serial 32-bit chain (DOT_TREE = 0)
  function automatic logic signed [31:0] dot_serial(input logic [127:0] pk);
    logic signed [15:0] p;
    logic signed [31:0] s;
    s = 32'sd0;
    for (int i = 0; i < 8; i++) begin
      p = pk[16*i +: 16];
      s = s + 32'(p);
    end
    return s;
  endfunction

  generate
    if (AI_LAT == 1) begin : g_lat1
      assign op_u = op;
      assign sh_u = shamt;
      assign a_u  = a;
      assign b_u  = b;
      assign busy = 1'b0;
      assign prod_pk = dot_prods(a_u, b_u);
    end else if (AI_LAT == 2) begin : g_lat2
      state_e      state;
      ai_op_e      op_q;
      logic [4:0]  sh_q;
      logic [63:0] a_q, b_q;

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          state <= S_IDLE;
        end else begin
          case (state)
            S_IDLE: if (req) begin
              op_q  <= op;
              sh_q  <= shamt;
              a_q   <= a;
              b_q   <= b;
              state <= S_DONE;
            end
            S_DONE: state <= S_IDLE;
          endcase
        end
      end

      assign busy = (state == S_IDLE) && req;
      assign op_u = op_q;
      assign sh_u = sh_q;
      assign a_u  = a_q;
      assign b_u  = b_q;
      assign prod_pk = dot_prods(a_u, b_u);
    end else if (AI_LAT == 3) begin : g_lat3
      // ---- stage 1 (EX): products / operand copy, registered every cycle ----
      ai_op_e       op_q;
      logic [4:0]   sh_q;
      logic [127:0] s1_d, s1_q;
      wire  [127:0] prod_vec;

      assign prod_vec = dot_prods(a, b);
      assign s1_d = (op == AI_DOT8) ? prod_vec : {b, a};

      always_ff @(posedge clk) begin
        op_q <= op;
        sh_q <= shamt;
        s1_q <= s1_d;
      end

      // ---- stage 2 (MEM): everything below runs from the stage register ----
      assign busy = 1'b0;
      assign op_u = op_q;
      assign sh_u = sh_q;
      assign a_u  = s1_q[63:0];          // qrelu / max8 operands (dot8 does not use them)
      assign b_u  = s1_q[127:64];
      assign prod_pk = s1_q;
    end else begin : g_bad
      $error("ai_unit: AI_LAT must be 1, 2 or 3");
    end
  endgenerate

  // ------------------------------------------------------------------
  // dot8: sum of the eight 16-bit signed products
  // ------------------------------------------------------------------
  logic signed [31:0] dot_sum;
  assign dot_sum = DOT_TREE ? dot_tree(prod_pk) : dot_serial(prod_pk);

  // ------------------------------------------------------------------
  // qrelu: 4 x (int32 -> rounded >> SH -> ReLU -> saturate to 0..127)
  // ------------------------------------------------------------------
  logic [31:0] q_res;

  always_comb begin : qrelu_path
    logic [127:0]       lanes;
    logic [31:0]        v, rnd;
    logic signed [63:0] vs, rs, t, r;
    lanes = {b_u, a_u};
    rnd   = (sh_u == 5'd0) ? 32'd0 : (32'd1 << (sh_u - 5'd1));
    q_res = 32'b0;
    for (int l = 0; l < 4; l++) begin
      v  = lanes[32*l +: 32];
      vs = {{32{v[31]}}, v};
      rs = {32'b0, rnd};
      t  = vs + rs;                                       // exact (no overflow in 64 bit)
      r  = t >>> sh_u;                                    // arithmetic shift
      if (r < 64'sd0)        q_res[8*l +: 8] = 8'd0;      // ReLU
      else if (r > 64'sd127) q_res[8*l +: 8] = 8'd127;    // saturate
      else                   q_res[8*l +: 8] = r[7:0];
    end
  end

  // ------------------------------------------------------------------
  // max8: signed max per byte lane
  // ------------------------------------------------------------------
  logic [63:0] max_res;

  always_comb begin : max8_path
    logic signed [7:0] xa, xb;
    max_res = 64'b0;
    for (int i = 0; i < 8; i++) begin
      xa = a_u[8*i +: 8];
      xb = b_u[8*i +: 8];
      max_res[8*i +: 8] = (xa > xb) ? a_u[8*i +: 8] : b_u[8*i +: 8];
    end
  end

  // ------------------------------------------------------------------
  // result mux
  // ------------------------------------------------------------------
  always_comb begin
    case (op_u)
      AI_DOT8:  result = {{32{dot_sum[31]}}, dot_sum};
      AI_QRELU: result = {32'b0, q_res};
      AI_MAX8:  result = max_res;
      default:  result = 64'b0;
    endcase
  end

endmodule