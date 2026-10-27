`timescale 1ns/1ps
// Self-checking unit test of ai_unit for ALL THREE latencies against ai_model.py.
//   python3 gen_ai_vectors.py <dir>        -> <dir>/ai_vectors.txt  (run vsim with cwd = <dir>)
// AI_LAT=1 : combinational, busy must stay 0.
// AI_LAT=2 : busy = 1 in the cycle the request is presented, result valid in the next cycle; the inputs are
//            deliberately scrambled right after the capture edge (as the forwarding network would do while the
//            pipeline is stalled) and must not disturb the result.
// AI_LAT=3 : pipelined, busy must stay 0; the result is valid in the cycle AFTER the request (the stage register is
//            loaded at the clock edge) and must not be disturbed by the scrambled inputs.  A second run streams the
//            vectors back to back (a new request EVERY cycle) and checks that the result of request n appears
//            together with request n+1 (this is what the EX/MEM pipeline does).
// Requests of the first part are issued with random one-cycle gaps.
import rv64imafc_pkg::*;

module ai_unit_tb;
  logic        clk = 0, rst_n = 0, req = 0;
  ai_op_e      op;
  logic [4:0]  sh;
  logic [63:0] a, b;
  logic        busy1, busy2, busy3;
  logic [63:0] res1, res2, res3;

  // streaming instance (own inputs)
  logic        sreq = 0;
  ai_op_e      sop;
  logic [4:0]  ssh;
  logic [63:0] sa, sb, sres;
  logic        sbusy;

  always #5 clk = ~clk;

  ai_unit #(.AI_LAT(1)) dut1 (.clk(clk), .rst_n(rst_n), .req(req), .op(op), .shamt(sh), .a(a), .b(b), .busy(busy1), .result(res1));
  ai_unit #(.AI_LAT(2)) dut2 (.clk(clk), .rst_n(rst_n), .req(req), .op(op), .shamt(sh), .a(a), .b(b), .busy(busy2), .result(res2));
  ai_unit #(.AI_LAT(3)) dut3 (.clk(clk), .rst_n(rst_n), .req(req), .op(op), .shamt(sh), .a(a), .b(b), .busy(busy3), .result(res3));
  ai_unit #(.AI_LAT(3)) dut3s(.clk(clk), .rst_n(rst_n), .req(sreq), .op(sop), .shamt(ssh), .a(sa), .b(sb), .busy(sbusy), .result(sres));

  integer      fd, r, n, ns, errors;
  logic [7:0]  op_i, sh_i;
  logic [63:0] a_i, b_i, e_i, prev_e;
  logic        prev_valid;

  initial begin
    errors = 0; n = 0; ns = 0; prev_valid = 0; prev_e = 0;
    fd = $fopen("ai_vectors.txt", "r");
    if (fd == 0) begin $display("cannot open ai_vectors.txt"); $finish; end
    op = AI_DOT8; sh = 0; a = 0; b = 0; sop = AI_DOT8; ssh = 0; sa = 0; sb = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk); #1;

    // ---------------- part 1: one request at a time, random gaps ----------------
    while (!$feof(fd)) begin
      r = $fscanf(fd, "%h %h %h %h %h\n", op_i, sh_i, a_i, b_i, e_i);
      if (r == 5) begin
        op = ai_op_e'(op_i[2:0]); sh = sh_i[4:0]; a = a_i; b = b_i; req = 1;
        #1;
        if (busy1 !== 1'b0 || res1 !== e_i) begin
          errors++;
          if (errors < 30) $display("LAT1 MISMATCH op=%0d sh=%0d a=%h b=%h  got %h (busy=%b)  exp %h", op_i, sh_i, a_i, b_i, res1, busy1, e_i);
        end
        if (busy2 !== 1'b1) begin
          errors++;
          if (errors < 30) $display("LAT2: busy not asserted in the request cycle (op=%0d)", op_i);
        end
        if (busy3 !== 1'b0) begin
          errors++;
          if (errors < 30) $display("LAT3: busy asserted (op=%0d): the pipelined unit must never stall", op_i);
        end
        @(posedge clk); #1;                                  // operands captured (LAT2: DONE cycle, LAT3: stage register loaded)
        a = ~a; b = ~b; sh = ~sh; op = AI_MAX8;              // scramble the live inputs
        #1;
        if (busy2 !== 1'b0 || res2 !== e_i) begin
          errors++;
          if (errors < 30) $display("LAT2 MISMATCH op=%0d sh=%0d a=%h b=%h  got %h (busy=%b)  exp %h", op_i, sh_i, a_i, b_i, res2, busy2, e_i);
        end
        if (busy3 !== 1'b0 || res3 !== e_i) begin
          errors++;
          if (errors < 30) $display("LAT3 MISMATCH op=%0d sh=%0d a=%h b=%h  got %h (busy=%b)  exp %h", op_i, sh_i, a_i, b_i, res3, busy3, e_i);
        end
        n++;
        @(posedge clk); #1;                                  // back to IDLE; next request may follow immediately
        if ($urandom % 4 == 0) begin req = 0; @(posedge clk); #1; end
      end
    end
    req = 0;

    // ---------------- part 2: AI_LAT=3 streaming, one request every cycle ----------------
    r = $fseek(fd, 0, 0);
    @(posedge clk); #1;
    while (!$feof(fd)) begin
      r = $fscanf(fd, "%h %h %h %h %h\n", op_i, sh_i, a_i, b_i, e_i);
      if (r == 5) begin
        sop = ai_op_e'(op_i[2:0]); ssh = sh_i[4:0]; sa = a_i; sb = b_i; sreq = 1;
        #1;                                                  // the stage register still holds the PREVIOUS request
        if (sbusy !== 1'b0 || (prev_valid && sres !== prev_e)) begin
          errors++;
          if (errors < 30) $display("LAT3 STREAM MISMATCH before vector %0d: got %h (busy=%b)  exp %h", ns, sres, sbusy, prev_e);
        end
        @(posedge clk); #1;
        prev_e = e_i; prev_valid = 1; ns++;
      end
    end
    sreq = 0; sa = ~sa; sb = ~sb; sop = AI_MAX8;             // the last result must survive the scrambled inputs
    #1;
    if (prev_valid && sres !== prev_e) begin
      errors++;
      $display("LAT3 STREAM MISMATCH on the last vector: got %h exp %h", sres, prev_e);
    end

    $display("%0d vectors x 3 latencies (+ %0d streamed back to back), %0d errors  -> %s", n, ns, errors, errors == 0 ? "PASS" : "FAIL");
    $finish;
  end
endmodule
