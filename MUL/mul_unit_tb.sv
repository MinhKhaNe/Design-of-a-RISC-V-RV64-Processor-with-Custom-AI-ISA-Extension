`timescale 1ns/1ps
// Self-checking unit test of mul_div_unit in 9 configurations at once, against mul_model.py.
//   python3 gen_mul_vectors.py <dir>   -> <dir>/mul_vectors.txt   (run vsim with cwd = <dir>)
// For every multiply it checks the RESULT and the NUMBER OF STALL CYCLES (busy cycles) of the configuration;
// for every divide it checks the result (the divider is unchanged: this is a regression check).
import rv64imafc_pkg::*;

module mul_check #(
    parameter int    MUL_MODE = 0,
    parameter int    MUL_STALL = 1,
    parameter bit    MULW_FAST = 1'b0,
    parameter bit    MULW_SHORT = 1'b0,
    parameter int    EXP_STALL_MULW = 5,
    parameter int    EXP_STALL_MUL  = 5
) (
    input  logic clk,
    input  logic rst_n,
    output logic fin,
    output int   mul_err,
    output int   div_err,
    output int   stall_err,
    output int   n_mul,
    output int   n_div
);
  logic        req, is_mul, is_div;
  mul_op_e     mul_op;
  div_op_e     div_op;
  logic [63:0] a, b, result;
  logic        busy, done;

  mul_div_unit #(.MUL_MODE(MUL_MODE), .MUL_STALL(MUL_STALL), .MULW_FAST(MULW_FAST), .MULW_SHORT(MULW_SHORT)) dut (
      .clk(clk), .rst_n(rst_n), .req(req), .is_mul(is_mul), .is_div(is_div),
      .mul_op(mul_op), .div_op(div_op), .a(a), .b(b), .busy(busy), .done(done), .result(result)
  );

  integer      fd, r, stall, expected;
  logic [7:0]  kind, op_i;
  logic [63:0] a_i, b_i, e_i;

  initial begin
    fin = 0; mul_err = 0; div_err = 0; stall_err = 0; n_mul = 0; n_div = 0;
    req = 0; is_mul = 0; is_div = 0; mul_op = MUL_MUL; div_op = DIV_DIV; a = 0; b = 0;
    fd = $fopen("mul_vectors.txt", "r");
    if (fd == 0) begin $display("cannot open mul_vectors.txt"); $finish; end
    wait (rst_n === 1'b1);
    @(posedge clk); #1;
    while (!$feof(fd)) begin
      r = $fscanf(fd, "%h %h %h %h %h\n", kind, op_i, a_i, b_i, e_i);
      if (r == 5) begin
        a = a_i; b = b_i; req = 1;
        is_mul = (kind == 0);  is_div = (kind == 1);
        mul_op = (kind == 0) ? mul_op_e'(op_i[2:0]) : MUL_MUL;
        div_op = (kind == 1) ? div_op_e'(op_i[2:0]) : DIV_DIV;
        #1;
        stall = 0;
        while (busy && stall < 300) begin @(posedge clk); #1; stall++; end   // busy cycles = stall cycles
        if (result !== e_i) begin
          if (kind == 0) mul_err++; else div_err++;
          if (mul_err + div_err < 6)
            $display("[%m] WRONG RESULT kind=%0d op=%0d a=%h b=%h got %h exp %h", kind, op_i, a_i, b_i, result, e_i);
        end
        if (kind == 0) begin
          n_mul++;
          expected = (mul_op == MUL_MULW) ? EXP_STALL_MULW : EXP_STALL_MUL;
          if (stall != expected) begin
            stall_err++;
            if (stall_err < 4) $display("[%m] WRONG STALL op=%0d: %0d cycles, expected %0d", op_i, stall, expected);
          end
        end else n_div++;
        @(posedge clk); #1;                                   // result consumed; next request follows immediately
      end
    end
    req = 0; is_mul = 0; is_div = 0;
    fin = 1;
  end
endmodule

module mul_unit_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  initial begin repeat (3) @(posedge clk); rst_n = 1; end

  localparam int N = 9;
  logic fin [N];
  int   me [N], de [N], se [N], nm [N], nd [N];
  string names [N] = '{"iter", "iter+mulw_short", "iter+mulw_fast", "comb", "lat1", "lat2", "lat3", "lat5", "lat3+mulw_fast"};

  //                      mode stall fast short  expected stall (mulw, other)
  mul_check #(0, 3, 0, 0, 5, 5) c0 (clk, rst_n, fin[0], me[0], de[0], se[0], nm[0], nd[0]);
  mul_check #(0, 3, 0, 1, 3, 5) c1 (clk, rst_n, fin[1], me[1], de[1], se[1], nm[1], nd[1]);
  mul_check #(0, 3, 1, 0, 0, 5) c2 (clk, rst_n, fin[2], me[2], de[2], se[2], nm[2], nd[2]);
  mul_check #(1, 3, 0, 0, 0, 0) c3 (clk, rst_n, fin[3], me[3], de[3], se[3], nm[3], nd[3]);
  mul_check #(2, 1, 0, 0, 1, 1) c4 (clk, rst_n, fin[4], me[4], de[4], se[4], nm[4], nd[4]);
  mul_check #(2, 2, 0, 0, 2, 2) c5 (clk, rst_n, fin[5], me[5], de[5], se[5], nm[5], nd[5]);
  mul_check #(2, 3, 0, 0, 3, 3) c6 (clk, rst_n, fin[6], me[6], de[6], se[6], nm[6], nd[6]);
  mul_check #(2, 5, 0, 0, 5, 5) c7 (clk, rst_n, fin[7], me[7], de[7], se[7], nm[7], nd[7]);
  mul_check #(2, 3, 1, 0, 0, 3) c8 (clk, rst_n, fin[8], me[8], de[8], se[8], nm[8], nd[8]);

  integer i, total;
  initial begin
    wait (fin[0] && fin[1] && fin[2] && fin[3] && fin[4] && fin[5] && fin[6] && fin[7] && fin[8]);
    total = 0;
    for (i = 0; i < N; i++) begin
      $display("%-16s %0d multiplies / %0d divides: wrong mul results %0d, wrong div results %0d, wrong stall counts %0d",
               names[i], nm[i], nd[i], me[i], de[i], se[i]);
      total += me[i] + de[i] + se[i];
    end
    $display("%s", total == 0 ? "PASS" : "FAIL");
    $finish;
  end
endmodule