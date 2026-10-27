`timescale 1ns/1ps
// perf_mon: cycle-accounting monitor for rv64imafc_top (simulation only).
//
// Compile it AFTER the RTL and run it as a SECOND TOP-LEVEL MODULE next to the testbench; it needs no change to the
// testbench or to the RTL:
//     vlog -sv perf_mon.sv
//     vsim ... tb_baremetal perf_mon -voptargs=+acc ...
// (make perf_run does exactly this).  It reaches the core by hierarchical reference; the default path is
// tb_baremetal.dut, override with  vlog +define+PERF_DUT=<path>  if your testbench names the core differently.
//
// What it counts (every counter is a 64-bit event/cycle count, counted from reset release):
//   cycles       clock cycles                         retired     instructions that leave EX
//   ex_empty     cycles with NO valid instruction in EX = bubbles:   hz_load + hz_ai + 2 x (flushes) + start-up
//   busy_mdu/fpu/ai   cycles the EX instruction is held by the multiplier-divider / FPU / AI_LAT=2 unit
//   hz_load      bubbles inserted by the hazard unit because of a load      hz_ai   ... because of an Xai result (AI_LAT=3)
//   fl_br/fl_jal/fl_jalr/fl_trap   pipeline flushes (each costs 2 bubbles);  br_back = taken backward branches (loops)
//   instruction mix at retirement (exclusive classes): load store alu_imm alu_reg branch(taken/not taken) jal jalr
//                mul div fpu csr amo dot8 qrelu max8
// Output lines (parsed by perf_report.py):
//   PERF_SNAP <counters>   at every  csrr cycle  (rdcycle) that retires: the software TIMED() regions are pairs of snapshots
//   PERF_FINAL <counters>  at the end of the simulation
//   PERF_LOOP pc=.. target=.. taken=..   one line per backward branch executed (loop-closing branches)

`ifndef PERF_DUT
  `define PERF_DUT tb_baremetal.dut
`endif
`define PM `PERF_DUT

module perf_mon;
  import rv64imafc_pkg::*;

  typedef enum int {
    C_CYCLES, C_RETIRED, C_EX_EMPTY,
    C_BUSY_MDU, C_BUSY_FPU, C_BUSY_AI,
    C_HZ_LOAD, C_HZ_AI,
    C_FL_BR, C_FL_JAL, C_FL_JALR, C_FL_TRAP, C_BR_BACK,
    C_I_LOAD, C_I_STORE, C_I_ALU_IMM, C_I_ALU_REG,
    C_I_BR_T, C_I_BR_NT, C_I_JAL, C_I_JALR,
    C_I_MUL, C_I_DIV, C_I_FPU, C_I_CSR, C_I_AMO,
    C_I_DOT8, C_I_QRELU, C_I_MAX8,
    C_N
  } cidx_e;

  longint unsigned cnt [C_N];
  longint unsigned loop_cnt [logic [63:0]];
  logic [63:0]     loop_tgt [logic [63:0]];

  initial begin
    for (int i = 0; i < C_N; i++) cnt[i] = 0;
  end

  function automatic string cname(input int i);
    cidx_e e;
    string s;
    e = cidx_e'(i);
    s = e.name();
    return s.substr(2, s.len() - 1).tolower();
  endfunction

  function automatic void dump(input string tag);
    string s;
    s = tag;
    for (int i = 0; i < C_N; i++) s = {s, $sformatf(" %s=%0d", cname(i), cnt[i])};
    $display("%s", s);
  endfunction

  always @(posedge `PM.clk) begin
    if (`PM.rst_n === 1'b1) begin
      cnt[C_CYCLES]++;

      // ---- cycles without a valid instruction in EX, and why ----
      if (!`PM.idex_valid) cnt[C_EX_EMPTY]++;
      if (`PM.idex_valid && `PM.ex_busy) begin
        if (`PM.mdu_busy) cnt[C_BUSY_MDU]++;
        if (`PM.fpu_busy) cnt[C_BUSY_FPU]++;
        if (`PM.ai_busy)  cnt[C_BUSY_AI]++;
      end
      if (`PM.hazard_stall && !`PM.flush && !`PM.ex_busy) begin
        if (`PM.idex_mem_read) cnt[C_HZ_LOAD]++;
        else                   cnt[C_HZ_AI]++;
      end

      // ---- flushes (2 bubbles each) ----
      if (`PM.flush) begin
        if (`PM.illegal_instr_o)    cnt[C_FL_TRAP]++;
        else if (`PM.idex_is_jal)   cnt[C_FL_JAL]++;
        else if (`PM.idex_is_jalr)  cnt[C_FL_JALR]++;
        else begin
          cnt[C_FL_BR]++;
          if (`PM.ex_alu_result < `PM.idex_pc) begin       // taken backward branch = loop iteration
            cnt[C_BR_BACK]++;
            if (loop_cnt.exists(`PM.idex_pc)) loop_cnt[`PM.idex_pc]++;
            else                              loop_cnt[`PM.idex_pc] = 1;
            loop_tgt[`PM.idex_pc] = `PM.ex_alu_result;
          end
        end
      end

      // ---- instruction mix at retirement (exclusive classes) ----
      if (`PM.ex_retire) begin
        cnt[C_RETIRED]++;
        if (`PM.idex_is_ai) begin
          case (`PM.idex_ai_op)
            AI_DOT8:  cnt[C_I_DOT8]++;
            AI_QRELU: cnt[C_I_QRELU]++;
            AI_MAX8:  cnt[C_I_MAX8]++;
            default: ;
          endcase
        end
        else if (`PM.idex_is_mul)  cnt[C_I_MUL]++;
        else if (`PM.idex_is_div)  cnt[C_I_DIV]++;
        else if (`PM.idex_is_fpu)  cnt[C_I_FPU]++;
        else if (`PM.idex_is_csr)  cnt[C_I_CSR]++;
        else if (`PM.idex_is_amo || `PM.idex_is_lr || `PM.idex_is_sc) cnt[C_I_AMO]++;
        else if (`PM.idex_mem_read)  cnt[C_I_LOAD]++;
        else if (`PM.idex_mem_write) cnt[C_I_STORE]++;
        else if (`PM.idex_branch_type != BR_NONE) begin
          if (`PM.ex_br_taken) cnt[C_I_BR_T]++;
          else                 cnt[C_I_BR_NT]++;
        end
        else if (`PM.idex_is_jal)  cnt[C_I_JAL]++;
        else if (`PM.idex_is_jalr) cnt[C_I_JALR]++;
        else if (`PM.idex_alu_b_sel == ALU_B_IMM) cnt[C_I_ALU_IMM]++;
        else                                      cnt[C_I_ALU_REG]++;

        // snapshot at every  csrr rd, cycle  (rdcycle)
        if (`PM.idex_is_csr && `PM.idex_csr_addr == 12'hC00) dump("PERF_SNAP");
      end
    end
  end

  final begin
    dump("PERF_FINAL");
    foreach (loop_cnt[p])
      $display("PERF_LOOP pc=0x%0h target=0x%0h taken=%0d", p, loop_tgt[p], loop_cnt[p]);
  end
endmodule
