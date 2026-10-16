// Self-checking testbench for fpu.sv. Run gen_vectors.py first (creates fpu_vectors.txt).
//   e.g.  verilator --binary --timing -Wno-fatal ../rv64im_pkg.sv ../fp_unpack.sv ../fp_round.sv ../fpu.sv fpu_tb.sv
import rv64im_pkg::*;

module fpu_tb;
  logic        clk = 0, rst_n = 0, req = 0;
  fpu_op_e     op;
  logic [2:0]  rm;
  logic [63:0] a;
  logic [31:0] b, c;
  logic        busy;
  logic [63:0] result;
  logic [4:0]  flags;

  fpu dut (.*);
  always #5 clk = ~clk;

  integer fd, r, n, errors;
  logic [7:0]  op_i;
  logic [3:0]  rm_i;
  logic [63:0] a_i, exp_res;
  logic [31:0] b_i, c_i;
  logic [7:0]  exp_fl;

  initial begin
    errors = 0; n = 0;
    fd = $fopen("fpu_vectors.txt", "r");
    if (fd == 0) begin $display("cannot open fpu_vectors.txt"); $finish; end
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(negedge clk);
    while (!$feof(fd)) begin
      r = $fscanf(fd, "%h %h %h %h %h %h %h\n", op_i, rm_i, a_i, b_i, c_i, exp_res, exp_fl);
      if (r == 7) begin
        op = fpu_op_e'(op_i[4:0]); rm = rm_i[2:0]; a = a_i; b = b_i; c = c_i; req = 1;
        #1;
        while (busy) begin @(posedge clk); #1; end
        if (result !== exp_res || flags !== exp_fl[4:0]) begin
          errors++;
          if (errors < 30)
            $display("MISMATCH op=%0d rm=%0d a=%h b=%h c=%h  got %h/%b  exp %h/%b",
                     op_i, rm_i, a_i, b_i, c_i, result, flags, exp_res, exp_fl[4:0]);
        end
        n++;
        @(posedge clk); #1; req = 0;
        @(negedge clk);
      end
    end
    $display("%0d vectors, %0d errors  -> %s", n, errors, errors == 0 ? "PASS" : "FAIL");
    $finish;
  end
endmodule