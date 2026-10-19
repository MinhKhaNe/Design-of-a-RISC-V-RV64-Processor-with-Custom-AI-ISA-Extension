`timescale 1ns/1ps
// Core-level directed test for the A extension.
//   python3 a_ext_test.py        (creates imem.hex, expected_*.hex, prog_params.svh)
//   verilator --binary --timing -Wno-fatal -I. --top-module rv64imafc_a_tb \
//       <core .sv files in compile order, package first: see RTL_FILES in ../Makefile> rv64imafc_a_tb.sv
//   (run from this directory so "imem.hex" resolves)
module rv64imafc_a_tb;
  `include "prog_params.svh"                       // END_PC: self-loop, also used as TRAP_PC

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic [63:0] pc_o;
  logic        stall_o, flush_o, ill_o;

  rv64imafc_top #(.RESET_PC(64'h0), .TRAP_PC(END_PC), .IMEM_INIT("imem.hex")) dut (
      .clk(clk), .rst_n(rst_n), .pc_o(pc_o), .stall_o(stall_o),
      .flush_o(flush_o), .illegal_instr_o(ill_o)
  );

  logic [63:0] exp_regs [0:31];
  logic [7:0]  exp_mem  [0:31];
  integer i, errors, ill_count;

  always @(posedge clk) if (rst_n && ill_o) ill_count++;

  initial begin
    errors = 0; ill_count = 0;
    $readmemh("expected_regs.hex", exp_regs);
    $readmemh("expected_mem.hex",  exp_mem);

    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (600) @(posedge clk);

    for (i = 1; i < 32; i++)
      if (dut.regfile_inst.regs[i] !== exp_regs[i]) begin
        errors++;
        $display("REG x%0d: got %h  exp %h", i, dut.regfile_inst.regs[i], exp_regs[i]);
      end
    for (i = 0; i < 32; i++)
      if (dut.dmem_inst.mem[32'h100 + i] !== exp_mem[i]) begin
        errors++;
        $display("MEM[0x%0h]: got %h  exp %h", 32'h100 + i, dut.dmem_inst.mem[32'h100 + i], exp_mem[i]);
      end
    if (ill_count != 1) begin
      errors++;
      $display("expected exactly 1 trap (the misaligned AMO), saw %0d", ill_count);
    end
    $display("%s  (%0d mismatches)", errors == 0 ? "PASS" : "FAIL", errors);
    $finish;
  end
endmodule