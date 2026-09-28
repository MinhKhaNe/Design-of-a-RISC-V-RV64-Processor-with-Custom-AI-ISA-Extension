import rv64i_pkg::*;

module tb_m_extension;
  logic clk = 0;
  logic rst_n = 0;
  logic [63:0] pc_o;
  logic stall_o, flush_o, illegal_instr_o;

  rv64i_top dut (
      .clk(clk), .rst_n(rst_n),
      .pc_o(pc_o), .stall_o(stall_o), .flush_o(flush_o),
      .illegal_instr_o(illegal_instr_o)
  );

  always #5 clk = ~clk;

  initial begin
    rst_n = 0;
    // addi x1,x0,6 ; addi x2,x0,7 ; mul x3,x1,x2 ; divu x4,x1,x2 ; add x5,x3,x4
    dut.imem_inst.mem[0]  = 8'h93; dut.imem_inst.mem[1]  = 8'h00; dut.imem_inst.mem[2]  = 8'h60; dut.imem_inst.mem[3]  = 8'h00;
    dut.imem_inst.mem[4]  = 8'h13; dut.imem_inst.mem[5]  = 8'h01; dut.imem_inst.mem[6]  = 8'h70; dut.imem_inst.mem[7]  = 8'h00;
    dut.imem_inst.mem[8]  = 8'hb3; dut.imem_inst.mem[9]  = 8'h81; dut.imem_inst.mem[10] = 8'h20; dut.imem_inst.mem[11] = 8'h02;
    dut.imem_inst.mem[12] = 8'h33; dut.imem_inst.mem[13] = 8'hd2; dut.imem_inst.mem[14] = 8'h20; dut.imem_inst.mem[15] = 8'h02;
    dut.imem_inst.mem[16] = 8'hb3; dut.imem_inst.mem[17] = 8'h82; dut.imem_inst.mem[18] = 8'h41; dut.imem_inst.mem[19] = 8'h00;
    // remaining bytes default to 0 -> ADDI x0,x0,0 (NOP-ish), harmless

    repeat (3) @(posedge clk);
    rst_n = 1;

    repeat (140) @(posedge clk);

    $display("x1=%0d x2=%0d x3(mul)=%0d x4(divu)=%0d x5(add)=%0d",
              dut.regfile_inst.regs[1], dut.regfile_inst.regs[2],
              dut.regfile_inst.regs[3], dut.regfile_inst.regs[4],
              dut.regfile_inst.regs[5]);

    if (dut.regfile_inst.regs[1] !== 64'd6)  $display("FAIL x1");
    if (dut.regfile_inst.regs[2] !== 64'd7)  $display("FAIL x2");
    if (dut.regfile_inst.regs[3] !== 64'd42) $display("FAIL x3 (mul 6*7 should be 42)");
    if (dut.regfile_inst.regs[4] !== 64'd0)  $display("FAIL x4 (divu 6/7 should be 0)");
    if (dut.regfile_inst.regs[5] !== 64'd42) $display("FAIL x5 (mul+divu result should be 42)");
    if (dut.regfile_inst.regs[1] === 64'd6 && dut.regfile_inst.regs[2] === 64'd7 &&
        dut.regfile_inst.regs[3] === 64'd42 && dut.regfile_inst.regs[4] === 64'd0 &&
        dut.regfile_inst.regs[5] === 64'd42)
      $display("PIPELINE INTEGRATION: ALL PASS");

    $finish;
  end

  // watch stalls for visibility
  always @(posedge clk) if (rst_n && stall_o) $display("t=%0t: stall (pc=%0d)", $time, pc_o);
endmodule