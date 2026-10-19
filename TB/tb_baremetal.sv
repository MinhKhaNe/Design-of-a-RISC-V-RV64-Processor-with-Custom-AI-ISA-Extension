`timescale 1ns/1ps
// Runs a bare-metal program (build/imem.hex, build/dmem.hex) on the core and prints the
// results the program leaves in the mailbox (last 256 bytes of dmem).
//   +TIMEOUT=<cycles>   (default 5,000,000)
//   +VERBOSE            enable the per-instruction debug prints below
// Run with cwd = build/ so the relative hex file names resolve (the Makefile does this).
module tb_baremetal;
  `include "prog_params.svh"         // IMEM_BYTES, DMEM_BYTES, TRAP_PC  (written by elf2hex.py)

  localparam int          MBOX_OFF   = DMEM_BYTES - 256;
  localparam logic [63:0] DONE_MAGIC = 64'h600DF00D;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic [63:0] pc_o;
  logic        stall_o, flush_o, ill_o;

  rv64imafc_top #(
      .RESET_PC   (64'h0),
      .TRAP_PC    (TRAP_PC),
      .IMEM_BYTES (IMEM_BYTES),
      .DMEM_BYTES (DMEM_BYTES),
      .IMEM_INIT  ("imem.hex"),
      .DMEM_INIT  ("dmem.hex")
  ) dut (
      .clk(clk), .rst_n(rst_n), .pc_o(pc_o), .stall_o(stall_o),
      .flush_o(flush_o), .illegal_instr_o(ill_o)
  );

  function automatic logic [63:0] mb(input int idx);
    logic [63:0] v;
    for (int b = 0; b < 8; b++) v[8*b +: 8] = dut.dmem_inst.mem[MBOX_OFF + 8*idx + b];
    return v;
  endfunction

  longint unsigned cycles, timeout;
  int              traps;

  // ---- debug prints: off by default, enable with +VERBOSE ----
  bit verbose;
  initial verbose = $test$plusargs("VERBOSE");

  always @(posedge clk) begin
    if (verbose && rst_n && dut.idex_valid && dut.idex_is_csr && !dut.ex_busy)
      $display("CSR  pc=%h addr=%h rdata=%h  minstret=%0d",
              dut.idex_pc, dut.idex_csr_addr, dut.csr_rdata,
              dut.zicntr_inst.minstret);
  end

  localparam logic [15:0] BUF_LO = 16'h????, BUF_HI = BUF_LO + 16'd63;   // fill from nm
  always @(posedge clk) begin
    if (verbose && rst_n && dut.mem_we &&
        dut.exmem_alu_result[15:0] >= BUF_LO && dut.exmem_alu_result[15:0] <= BUF_HI)
      $display("%0t ST buf+%0d  data=%h width=%0d pc_in_wb_area",
              $time, dut.exmem_alu_result[15:0]-BUF_LO, dut.mem_wdata, dut.exmem_mem_width);
  end

  always @(posedge clk) begin
    if (verbose && rst_n && dut.memwb_reg_write &&
        (dut.wb_data == 64'h2e || dut.wb_data == 64'h1FED8))
      $display("%0t WB x%0d <= %h (wb_sel=%0d)", $time,
              dut.memwb_rd, dut.wb_data, dut.memwb_wb_sel);
  end

  initial begin
    if (!$value$plusargs("TIMEOUT=%d", timeout)) timeout = 5_000_000;
    cycles = 0; traps = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;

    forever begin
      @(posedge clk);
      cycles++;
      if ((cycles % 100000) == 0) begin
        $display(
            "TRACE cycle=%0d PC=0x%h stall=%b flush=%b illegal=%b MBOX0=0x%h",
            cycles, pc_o, stall_o, flush_o, ill_o, mb(0)
        );
      end
      if (ill_o) begin
        traps++;
        $display("FAIL: illegal-instruction trap #%0d at cycle %0d (IF pc = 0x%h)", traps, cycles, pc_o);
        if (traps >= 1) begin $display("(re-run the disassembly: make bm_dis; the trapping instruction is just before this pc)"); $finish; end
      end
      if (mb(0) == DONE_MAGIC) begin
        repeat (3) @(posedge clk);
        $display("program finished after %0d cycles; status code = %0d  -> %s",
                 cycles, mb(1), mb(1) == 0 ? "PASS" : "FAIL");
        for (int i = 2; i < 32; i++)
          if (mb(i) != 0) $display("  MBOX[%0d] = %0d  (0x%h)", i, mb(i), mb(i));
        $finish;
      end
      if (cycles >= timeout) begin
        $display("FAIL: timeout after %0d cycles (pc = 0x%h) - program never wrote DONE_MAGIC", cycles, pc_o);
        $finish;
      end
    end
  end
endmodule