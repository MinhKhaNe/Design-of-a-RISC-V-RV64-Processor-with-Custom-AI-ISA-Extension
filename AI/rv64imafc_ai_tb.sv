`timescale 1ns/1ps
// Core-level directed test for the Xai instructions (memory window 0x100..0x2ff, 1500 cycles).
//   python3 ai_ext_test.py <dir>     (creates imem.hex, dmem.hex, expected_*.hex in <dir>; run vsim with cwd = <dir>)
module rv64imafc_ai_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic [63:0] pc_o;
  logic        stall_o, flush_o, ill_o;

  rv64imafc_top #(.RESET_PC(64'h0), .TRAP_PC(64'h0), .IMEM_INIT("imem.hex"), .DMEM_INIT("dmem.hex")) dut (
      .clk(clk), .rst_n(rst_n), .pc_o(pc_o), .stall_o(stall_o),
      .flush_o(flush_o), .illegal_instr_o(ill_o)
  );

  logic [63:0] exp_regs [0:31];
  logic [7:0]  exp_mem  [0:511];
  integer i, errors, ill_count;

  always @(posedge clk) if (rst_n && ill_o) ill_count++;

  initial begin
    errors = 0; ill_count = 0;
    $readmemh("expected_regs.hex", exp_regs);
    $readmemh("expected_mem.hex",  exp_mem);
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (1500) @(posedge clk);

    for (i = 1; i < 32; i++)
      if (dut.regfile_inst.regs[i] !== exp_regs[i]) begin
        errors++;
        $display("REG x%0d: got %h  exp %h", i, dut.regfile_inst.regs[i], exp_regs[i]);
      end
    for (i = 0; i < 512; i++)
      if (dut.dmem_inst.mem[32'h100 + i] !== exp_mem[i]) begin
        errors++;
        $display("MEM[0x%0h]: got %h  exp %h", 32'h100 + i, dut.dmem_inst.mem[32'h100 + i], exp_mem[i]);
      end
    if (ill_count != 0) begin
      errors++;
      $display("unexpected illegal-instruction traps: %0d (an AI instruction failed to decode?)", ill_count);
    end
    $display("%s  (%0d mismatches)", errors == 0 ? "PASS" : "FAIL", errors);
    $finish;
  end
endmodule
