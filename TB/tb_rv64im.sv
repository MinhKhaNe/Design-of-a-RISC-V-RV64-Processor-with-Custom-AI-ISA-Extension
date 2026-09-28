`timescale 1ns/1ps

module tb_rv64im;

  localparam int NUM_WORDS = 692;
  localparam logic [63:0] RESET_PC = 64'h0000000000000000;
  localparam logic [63:0] TRAP_PC  = 64'h0000000000000700;

  localparam logic [63:0] PASS_ADDR = 64'h0f00;
  localparam logic [63:0] FAIL_ADDR = 64'h0f20;
  localparam logic [31:0] PASS_MAGIC = 32'hcafef00d;
  localparam logic [31:0] FAIL_MAGIC = 32'hdeaddead;
  localparam int EXPECTED_TESTS = 92;

  // ------------------------------------------------------------------
  // Clock / reset
  // ------------------------------------------------------------------
  logic clk = 0;
  always #5 clk = ~clk;   // 100 MHz

  logic rst_n;
  logic [63:0] pc_o;
  logic        stall_o, flush_o, illegal_instr_o;

  // ------------------------------------------------------------------
  // DUT
  // ------------------------------------------------------------------
  rv64im_top #(
      .RESET_PC (RESET_PC),
      .TRAP_PC  (TRAP_PC)
  ) dut (
      .clk             (clk),
      .rst_n           (rst_n),
      .pc_o            (pc_o),
      .stall_o         (stall_o),
      .flush_o         (flush_o),
      .illegal_instr_o (illegal_instr_o)
  );

  // ------------------------------------------------------------------
  // program_mem image (machine code), one 32-bit word per instruction
  // ------------------------------------------------------------------
  localparam logic [31:0] program_mem [0:NUM_WORDS-1] = '{
    32'h00000f93, 32'hfff00d13, 32'h80000db7, 32'h020d9d93, 32'h00000e93, 32'h01dd8db3, 32'h00500093, 32'hffd00113,
    32'h06408193, 32'h06900f13, 32'h29e190e3, 32'h001f8f93, 32'hff808213, 32'hffd00f13, 32'h27e218e3, 32'h001f8f93,
    32'h002082b3, 32'h00200f13, 32'h27e290e3, 32'h001f8f93, 32'h40208333, 32'h00800f13, 32'h25e318e3, 32'h001f8f93,
    32'h0020f3b3, 32'h00500f13, 32'h25e390e3, 32'h001f8f93, 32'h0020e433, 32'hffd00f13, 32'h23e418e3, 32'h001f8f93,
    32'h0020c4b3, 32'hff800f13, 32'h23e490e3, 32'h001f8f93, 32'h00112533, 32'h00100f13, 32'h21e518e3, 32'h001f8f93,
    32'h0020a5b3, 32'h00000f13, 32'h21e590e3, 32'h001f8f93, 32'h00113633, 32'h00000f13, 32'h1fe618e3, 32'h001f8f93,
    32'h0020b6b3, 32'h00100f13, 32'h1fe690e3, 32'h001f8f93, 32'h0060a713, 32'h00100f13, 32'h1de718e3, 32'h001f8f93,
    32'h0050a793, 32'h00000f13, 32'h1de790e3, 32'h001f8f93, 32'h0060b813, 32'h00100f13, 32'h1be818e3, 32'h001f8f93,
    32'h0030f893, 32'h00100f13, 32'h1be890e3, 32'h001f8f93, 32'h0080e913, 32'h00d00f13, 32'h19e918e3, 32'h001f8f93,
    32'hfff0c993, 32'hffa00f13, 32'h19e990e3, 32'h001f8f93, 32'hf0f0f0b7, 32'h0f108093, 32'h02009093, 32'hf0f0feb7,
    32'h0f0e8e93, 32'h01d080b3, 32'h00409a13, 32'h0f0f1f37, 32'hf0ff0f13, 32'h020f1f13, 32'h0f0f1eb7, 32'hf00e8e93,
    32'h01df0f33, 32'h15ea12e3, 32'h001f8f93, 32'h0040da93, 32'h0f0f1f37, 32'hf0ff0f13, 32'h020f1f13, 32'h0f0f1eb7,
    32'hf0fe8e93, 32'h01df0f33, 32'h13ea90e3, 32'h001f8f93, 32'hff000093, 32'h4020db13, 32'hffc00f13, 32'h11eb16e3,
    32'h001f8f93, 32'h00500093, 32'hffd00113, 32'h00209bb3, 32'ha0000f37, 32'h020f1f13, 32'h00000e93, 32'h01df0f33,
    32'h0feb94e3, 32'h001f8f93, 32'h002ddc33, 32'h00400f13, 32'h0dec1ce3, 32'h001f8f93, 32'h402ddcb3, 32'hffc00f13,
    32'h0dec94e3, 32'h001f8f93, 32'h123450b7, 32'h12345f37, 32'h0be09ce3, 32'h001f8f93, 32'h800000b7, 32'h80000f37,
    32'h0be094e3, 32'h001f8f93, 32'h01000117, 32'h00000f13, 32'h00bf1f13, 32'h000f0f13, 32'h00bf1f13, 32'h000f0f13,
    32'h00bf1f13, 32'h004f0f13, 32'h00bf1f13, 32'h000f0f13, 32'h00bf1f13, 32'h208f0f13, 32'h07e118e3, 32'h001f8f93,
    32'h7ffff0b7, 32'h7ff08093, 32'h7ff08093, 32'h00108093, 32'h00100113, 32'h002081bb, 32'h80000f37, 32'h05e196e3,
    32'h001f8f93, 32'h4020823b, 32'h7fffff37, 32'h7fff0f13, 32'h7fff0f13, 32'h03e21ae3, 32'h001f8f93, 32'h00100093,
    32'h02009093, 32'h80000eb7, 32'h01d080b3, 32'h000092bb, 32'h80000f37, 32'h01e29ae3, 32'h001f8f93, 32'h00100093,
    32'h02009093, 32'hfff00e93, 32'h01d080b3, 32'h0000d33b, 32'hfff00f13, 32'h7fe31a63, 32'h001f8f93, 32'h00100093,
    32'h02009093, 32'hff000e93, 32'h01d080b3, 32'h4000d3bb, 32'hff000f13, 32'h7de39a63, 32'h001f8f93, 32'hfff0041b,
    32'hfff00f13, 32'h7de41263, 32'h001f8f93, 32'h00100093, 32'h01f0949b, 32'h80000f37, 32'h7be49863, 32'h001f8f93,
    32'h00100093, 32'h02009093, 32'h80000eb7, 32'h01d080b3, 32'h0040d51b, 32'h08000f37, 32'h79e51863, 32'h001f8f93,
    32'h4040d59b, 32'hf8000f37, 32'h79e59063, 32'h001f8f93, 32'h55500793, 32'h008000ef, 32'h1ad00793, 32'h00000f13,
    32'h00bf1f13, 32'h000f0f13, 32'h00bf1f13, 32'h000f0f13, 32'h00bf1f13, 32'h000f0f13, 32'h00bf1f13, 32'h000f0f13,
    32'h00bf1f13, 32'h338f0f13, 32'h75e09063, 32'h001f8f93, 32'h55500f13, 32'h73e79a63, 32'h001f8f93, 32'h55500793,
    32'h00000293, 32'h00b29293, 32'h00028293, 32'h00b29293, 32'h00028293, 32'h00b29293, 32'h00028293, 32'h00b29293,
    32'h00028293, 32'h00b29293, 32'h3b428293, 32'h00028167, 32'h1ad00793, 32'h00000f13, 32'h00bf1f13, 32'h000f0f13,
    32'h00bf1f13, 32'h000f0f13, 32'h00bf1f13, 32'h000f0f13, 32'h00bf1f13, 32'h000f0f13, 32'h00bf1f13, 32'h3b0f0f13,
    32'h6de11463, 32'h001f8f93, 32'h55500f13, 32'h6be79e63, 32'h001f8f93, 32'h00700093, 32'h00700113, 32'h55500793,
    32'h00208463, 32'h1ad00793, 32'h55500f13, 32'h69e79e63, 32'h001f8f93, 32'h00700093, 32'h00800113, 32'h55500793,
    32'h00208463, 32'h1ad00793, 32'h1ad00f13, 32'h67e79e63, 32'h001f8f93, 32'h00700093, 32'h00800113, 32'h55500793,
    32'h00209463, 32'h1ad00793, 32'h55500f13, 32'h65e79e63, 32'h001f8f93, 32'h00700093, 32'h00700113, 32'h55500793,
    32'h00209463, 32'h1ad00793, 32'h1ad00f13, 32'h63e79e63, 32'h001f8f93, 32'hffb00093, 32'h00300113, 32'h55500793,
    32'h0020c463, 32'h1ad00793, 32'h55500f13, 32'h61e79e63, 32'h001f8f93, 32'h00300093, 32'hffb00113, 32'h55500793,
    32'h0020c463, 32'h1ad00793, 32'h1ad00f13, 32'h5fe79e63, 32'h001f8f93, 32'h00300093, 32'hffb00113, 32'h55500793,
    32'h0020d463, 32'h1ad00793, 32'h55500f13, 32'h5de79e63, 32'h001f8f93, 32'hffb00093, 32'h00300113, 32'h55500793,
    32'h0020d463, 32'h1ad00793, 32'h1ad00f13, 32'h5be79e63, 32'h001f8f93, 32'h00300093, 32'hffb00113, 32'h55500793,
    32'h0020e463, 32'h1ad00793, 32'h55500f13, 32'h59e79e63, 32'h001f8f93, 32'hffb00093, 32'h00300113, 32'h55500793,
    32'h0020e463, 32'h1ad00793, 32'h1ad00f13, 32'h57e79e63, 32'h001f8f93, 32'hffb00093, 32'h00300113, 32'h55500793,
    32'h0020f463, 32'h1ad00793, 32'h55500f13, 32'h55e79e63, 32'h001f8f93, 32'h00300093, 32'hffb00113, 32'h55500793,
    32'h0020f463, 32'h1ad00793, 32'h1ad00f13, 32'h53e79e63, 32'h001f8f93, 32'h00000113, 32'h0ab00093, 32'h00110023,
    32'h00010183, 32'hfab00f13, 32'h53e19063, 32'h001f8f93, 32'h00014203, 32'h0ab00f13, 32'h51e21863, 32'h001f8f93,
    32'h000080b7, 32'h76508093, 32'h00111423, 32'h00811283, 32'hffff8f37, 32'h765f0f13, 32'h4fe29863, 32'h001f8f93,
    32'h00815303, 32'h00008f37, 32'h765f0f13, 32'h4de31e63, 32'h001f8f93, 32'h00100093, 32'h02009093, 32'h89abdeb7,
    32'hdefe8e93, 32'h01d080b3, 32'h00112823, 32'h01012383, 32'h89abdf37, 32'hdeff0f13, 32'h4be39863, 32'h001f8f93,
    32'h01016403, 32'h00100f13, 32'h020f1f13, 32'h89abdeb7, 32'hdefe8e93, 32'h01df0f33, 32'h49e41863, 32'h001f8f93,
    32'hfedcc0b7, 32'ha9808093, 32'h02009093, 32'h76543eb7, 32'h210e8e93, 32'h01d080b3, 32'h00113c23, 32'h01813483,
    32'hfedccf37, 32'ha98f0f13, 32'h020f1f13, 32'h76543eb7, 32'h210e8e93, 32'h01df0f33, 32'h45e49863, 32'h001f8f93,
    32'h01814503, 32'h01000f13, 32'h45e51063, 32'h001f8f93, 32'h01f14583, 32'h0fe00f13, 32'h43e59863, 32'h001f8f93,
    32'h00000113, 32'h444440b7, 32'h44408093, 32'h02009093, 32'h44444eb7, 32'h444e8e93, 32'h01d080b3, 32'h02113023,
    32'h02013603, 32'h00160693, 32'h44444f37, 32'h444f0f13, 32'h020f1f13, 32'h44444eb7, 32'h445e8e93, 32'h01df0f33,
    32'h3fe69463, 32'h001f8f93, 32'h00a00093, 32'h00108113, 32'h00110193, 32'h00118213, 32'h00d00f13, 32'h3de21663,
    32'h001f8f93, 32'h07b00013, 32'h00000a13, 32'h00000f13, 32'h3bea1c63, 32'h001f8f93, 32'hfe00007f, 32'h3ac0006f,
    32'h5a500a93, 32'h5a500f13, 32'h3bea9063, 32'h001f8f93, 32'h00600093, 32'h00700113, 32'h022081b3, 32'h02a00f13,
    32'h39e19463, 32'h001f8f93, 32'hffa00093, 32'h00700113, 32'h022081b3, 32'hfd600f13, 32'h37e19863, 32'h001f8f93,
    32'h00200113, 32'h022d01b3, 32'hffe00f13, 32'h35e19e63, 32'h001f8f93, 32'h12345c37, 32'h679c0c13, 32'h020c1c13,
    32'h9abceeb7, 32'hef0e8e93, 32'h01dc0c33, 32'hfedcccb7, 32'ha98c8c93, 32'h020c9c93, 32'h76543eb7, 32'h210e8e93,
    32'h01dc8cb3, 32'h039c11b3, 32'hffeb5f37, 32'h992f0f13, 32'h020f1f13, 32'h3cc09eb7, 32'h532e8e93, 32'h01df0f33,
    32'h31e19463, 32'h001f8f93, 32'h039c31b3, 32'h121faf37, 32'h00bf0f13, 32'h020f1f13, 32'hd77d7eb7, 32'h422e8e93,
    32'h01df0f33, 32'h2fe19263, 32'h001f8f93, 32'h039c21b3, 32'h121faf37, 32'h00bf0f13, 32'h020f1f13, 32'hd77d7eb7,
    32'h422e8e93, 32'h01df0f33, 32'h2de19063, 32'h001f8f93, 32'h7ffff0b7, 32'h7ff08093, 32'h7ff08093, 32'h00108093,
    32'h00300113, 32'h022081bb, 32'h7fffff37, 32'h7fff0f13, 32'h7fef0f13, 32'h29e19a63, 32'h001f8f93, 32'hffb00093,
    32'h00600113, 32'h022081bb, 32'hfe200f13, 32'h27e19e63, 32'h001f8f93, 32'h01100093, 32'h00500113, 32'h0220c1b3,
    32'h00300f13, 32'h27e19263, 32'h001f8f93, 32'hfef00093, 32'h00500113, 32'h0220c1b3, 32'hffd00f13, 32'h25e19663,
    32'h001f8f93, 32'h01100093, 32'hffb00113, 32'h0220c1b3, 32'hffd00f13, 32'h23e19a63, 32'h001f8f93, 32'h00200113,
    32'h022d51b3, 32'h80000f37, 32'h020f1f13, 32'hfff00e93, 32'h01df0f33, 32'h21e19a63, 32'h001f8f93, 32'h01100093,
    32'h00500113, 32'h0220e1b3, 32'h00200f13, 32'h1fe19e63, 32'h001f8f93, 32'hfef00093, 32'h00500113, 32'h0220e1b3,
    32'hffe00f13, 32'h1fe19263, 32'h001f8f93, 32'h00200113, 32'h022d71b3, 32'h00100f13, 32'h1de19863, 32'h001f8f93,
    32'h02a00093, 32'h00000113, 32'h0220c1b3, 32'hfff00f13, 32'h1be19c63, 32'h001f8f93, 32'h02a00093, 32'h00000113,
    32'h0220d1b3, 32'hfff00f13, 32'h1be19063, 32'h001f8f93, 32'h02a00093, 32'h00000113, 32'h0220e1b3, 32'h02a00f13,
    32'h19e19463, 32'h001f8f93, 32'h02a00093, 32'h00000113, 32'h0220f1b3, 32'h02a00f13, 32'h17e19863, 32'h001f8f93,
    32'h03adc1b3, 32'h80000f37, 32'h020f1f13, 32'h00000e93, 32'h01df0f33, 32'h15e19a63, 32'h001f8f93, 32'h03ade1b3,
    32'h00000f13, 32'h15e19263, 32'h001f8f93, 32'h00100093, 32'h02009093, 32'hfec00e93, 32'h01d080b3, 32'h00300113,
    32'h0220c1bb, 32'hffa00f13, 32'h13e19063, 32'h001f8f93, 32'h00100093, 32'h02009093, 32'hff000e93, 32'h01d080b3,
    32'h00200113, 32'h0220d1bb, 32'h7fffff37, 32'h7fff0f13, 32'h7f9f0f13, 32'h0fe19a63, 32'h001f8f93, 32'h00100093,
    32'h02009093, 32'hfec00e93, 32'h01d080b3, 32'h00300113, 32'h0220e1bb, 32'hffe00f13, 32'h0de19863, 32'h001f8f93,
    32'h00100093, 32'h02009093, 32'hff000e93, 32'h01d080b3, 32'h00300113, 32'h0220f1bb, 32'h00000f13, 32'h0be19663,
    32'h001f8f93, 32'h00100093, 32'h02009093, 32'h80000eb7, 32'h01d080b3, 32'h00100113, 32'h02011113, 32'hfff00e93,
    32'h01d10133, 32'h0220c1bb, 32'h80000f37, 32'h07e19e63, 32'h001f8f93, 32'h00100093, 32'h02009093, 32'h80000eb7,
    32'h01d080b3, 32'h00100113, 32'h02011113, 32'hfff00e93, 32'h01d10133, 32'h0220e1bb, 32'h00000f13, 32'h05e19663,
    32'h001f8f93, 32'h06400093, 32'h00700113, 32'h0220c2b3, 32'h00128313, 32'h00f00f13, 32'h03e31863, 32'h001f8f93,
    32'h000014b7, 32'hf0048493, 32'h00100513, 32'h02051513, 32'hcafefeb7, 32'h00de8e93, 32'h01d50533, 32'h00a4a023,
    32'h01f4b423, 32'h0000006f, 32'h000014b7, 32'hf2048493, 32'h00100513, 32'h02051513, 32'hdeadeeb7, 32'heade8e93,
    32'h01d50533, 32'h00a4a023, 32'h01f4b423, 32'h0000006f
  };

  // ------------------------------------------------------------------
  // Preload imem: backdoor byte-wise write into imem_inst.mem
  // (little-endian, matching imem.sv's own byte assembly)
  // ------------------------------------------------------------------
  initial begin
    int i;
    for (i = 0; i < NUM_WORDS; i++) begin
      dut.imem_inst.mem[i*4 + 0] = program_mem[i][7:0];
      dut.imem_inst.mem[i*4 + 1] = program_mem[i][15:8];
      dut.imem_inst.mem[i*4 + 2] = program_mem[i][23:16];
      dut.imem_inst.mem[i*4 + 3] = program_mem[i][31:24];
    end
  end

  // ------------------------------------------------------------------
  // illegal_instr_o bookkeeping: this program_mem deliberately executes
  // exactly one illegal instruction, and expects the pipeline to flush
  // and redirect to TRAP_PC on the very next cycle.
  // ------------------------------------------------------------------
  int illegal_pulse_count = 0;

  always_ff @(posedge clk) begin
    if (rst_n && illegal_instr_o) begin
      illegal_pulse_count <= illegal_pulse_count + 1;
    end
  end

  // one cycle after an illegal_instr_o pulse + flush, pc_o must equal TRAP_PC
  logic illegal_seen_d;
  logic saw_trap_redirect = 1'b0;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) illegal_seen_d <= 1'b0;
    else        illegal_seen_d <= illegal_instr_o && flush_o;
  end

  always_ff @(posedge clk) begin
    if (illegal_seen_d) begin
      if (pc_o !== TRAP_PC) begin
        $display("[%0t] FAIL: illegal_instr_o fired but pc_o=%0h one cycle later, expected TRAP_PC=%0h",
                  $time, pc_o, TRAP_PC);
        saw_trap_redirect <= 1'b0;
      end else begin
        saw_trap_redirect <= 1'b1;
      end
    end
  end

  // ------------------------------------------------------------------
  // Reset + run + watch for the pass/fail signature in dmem
  // ------------------------------------------------------------------
  localparam int MAX_CYCLES = 200000;

  initial begin
    int cyc;
    logic [31:0] pass_word, fail_word;
    logic [63:0] tests_passed;

    rst_n = 1'b0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    for (cyc = 0; cyc < MAX_CYCLES; cyc++) begin
      @(posedge clk);
      pass_word = {dut.dmem_inst.mem[PASS_ADDR[11:0]+3], dut.dmem_inst.mem[PASS_ADDR[11:0]+2],
                   dut.dmem_inst.mem[PASS_ADDR[11:0]+1], dut.dmem_inst.mem[PASS_ADDR[11:0]+0]};
      fail_word = {dut.dmem_inst.mem[FAIL_ADDR[11:0]+3], dut.dmem_inst.mem[FAIL_ADDR[11:0]+2],
                   dut.dmem_inst.mem[FAIL_ADDR[11:0]+1], dut.dmem_inst.mem[FAIL_ADDR[11:0]+0]};
      if (pass_word != 32'b0 || fail_word != 32'b0) begin
        break;
      end
    end

    #1; // let the last combinational settling finish

    pass_word = {dut.dmem_inst.mem[PASS_ADDR[11:0]+3], dut.dmem_inst.mem[PASS_ADDR[11:0]+2],
                 dut.dmem_inst.mem[PASS_ADDR[11:0]+1], dut.dmem_inst.mem[PASS_ADDR[11:0]+0]};
    fail_word = {dut.dmem_inst.mem[FAIL_ADDR[11:0]+3], dut.dmem_inst.mem[FAIL_ADDR[11:0]+2],
                 dut.dmem_inst.mem[FAIL_ADDR[11:0]+1], dut.dmem_inst.mem[FAIL_ADDR[11:0]+0]};

    $display("========================================================");
    if (pass_word == PASS_MAGIC) begin
      tests_passed = {dut.dmem_inst.mem[PASS_ADDR[11:0]+15], dut.dmem_inst.mem[PASS_ADDR[11:0]+14],
                       dut.dmem_inst.mem[PASS_ADDR[11:0]+13], dut.dmem_inst.mem[PASS_ADDR[11:0]+12],
                       dut.dmem_inst.mem[PASS_ADDR[11:0]+11], dut.dmem_inst.mem[PASS_ADDR[11:0]+10],
                       dut.dmem_inst.mem[PASS_ADDR[11:0]+9],  dut.dmem_inst.mem[PASS_ADDR[11:0]+8]};
      $display("PASS signature found. tests_passed = %0d / %0d", tests_passed, EXPECTED_TESTS);
      if (tests_passed !== EXPECTED_TESTS) begin
        $display("FAIL: pass signature written, but tests_passed count (%0d) != expected (%0d)",
                  tests_passed, EXPECTED_TESTS);
        $display("========================================================");
        $fatal(1);
      end
      if (illegal_pulse_count != 1) begin
        $display("FAIL: expected exactly 1 illegal_instr_o pulse, saw %0d", illegal_pulse_count);
        $display("========================================================");
        $fatal(1);
      end
      if (!saw_trap_redirect) begin
        $display("FAIL: illegal_instr_o fired but pc_o never redirected to TRAP_PC");
        $display("========================================================");
        $fatal(1);
      end
      $display("illegal_instr_o pulsed exactly once, and pc_o correctly redirected to TRAP_PC=%0h", TRAP_PC);
      $display("ALL CHECKS PASSED");
      $display("========================================================");
      $finish;
    end else if (fail_word == FAIL_MAGIC) begin
      tests_passed = {dut.dmem_inst.mem[FAIL_ADDR[11:0]+15], dut.dmem_inst.mem[FAIL_ADDR[11:0]+14],
                       dut.dmem_inst.mem[FAIL_ADDR[11:0]+13], dut.dmem_inst.mem[FAIL_ADDR[11:0]+12],
                       dut.dmem_inst.mem[FAIL_ADDR[11:0]+11], dut.dmem_inst.mem[FAIL_ADDR[11:0]+10],
                       dut.dmem_inst.mem[FAIL_ADDR[11:0]+9],  dut.dmem_inst.mem[FAIL_ADDR[11:0]+8]};
      $display("FAIL signature found. %0d / %0d tests passed before the first failure.",
                tests_passed, EXPECTED_TESTS);
      $display("(see the TEST_NAMES table in this file, indexed by tests_passed, to identify which check failed)");
      $display("========================================================");
      $fatal(1);
    end else begin
      $display("TIMEOUT: neither PASS nor FAIL signature appeared within %0d cycles (pc_o=%0h)",
                MAX_CYCLES, pc_o);
      $display("========================================================");
      $fatal(1);
    end
  end

  // ------------------------------------------------------------------
  // Reference table: test_names[i] is the (i+1)-th self-check emitted
  // by the generator, in program_mem order. If tests_passed == N after a
  // FAIL, the test at index N below (0-indexed) is the first one that
  // mismatched.
  // ------------------------------------------------------------------
  //   [  0] ADDI pos
  //   [  1] ADDI neg
  //   [  2] ADD
  //   [  3] SUB
  //   [  4] AND
  //   [  5] OR
  //   [  6] XOR
  //   [  7] SLT signed true
  //   [  8] SLT signed false
  //   [  9] SLTU (huge unsigned)
  //   [ 10] SLTU true
  //   [ 11] SLTI true
  //   [ 12] SLTI false (equal)
  //   [ 13] SLTIU true
  //   [ 14] ANDI
  //   [ 15] ORI
  //   [ 16] XORI (bitwise not)
  //   [ 17] SLLI
  //   [ 18] SRLI (logical)
  //   [ 19] SRAI (arith, negative)
  //   [ 20] SLL by low6(rs2)
  //   [ 21] SRL by low6(rs2)
  //   [ 22] SRA by low6(rs2)
  //   [ 23] LUI
  //   [ 24] LUI (sign-extends from imm bit19)
  //   [ 25] AUIPC
  //   [ 26] ADDW overflow -> sign-extends
  //   [ 27] SUBW
  //   [ 28] SLLW shift0 = sign-extend32
  //   [ 29] SRLW shift0 = sign-extend32
  //   [ 30] SRAW
  //   [ 31] ADDIW
  //   [ 32] SLLIW into sign bit
  //   [ 33] SRLIW logical
  //   [ 34] SRAIW arithmetic
  //   [ 35] JAL link = pc+4
  //   [ 36] JAL: instr after jal was squashed
  //   [ 37] JALR link = pc+4
  //   [ 38] JALR: instr after jalr was squashed
  //   [ 39] BEQ (taken): fallthrough squashed
  //   [ 40] BEQ (not taken): fallthrough executed
  //   [ 41] BNE (taken): fallthrough squashed
  //   [ 42] BNE (not taken): fallthrough executed
  //   [ 43] BLT (taken): fallthrough squashed
  //   [ 44] BLT (not taken): fallthrough executed
  //   [ 45] BGE (taken): fallthrough squashed
  //   [ 46] BGE (not taken): fallthrough executed
  //   [ 47] BLTU (taken): fallthrough squashed
  //   [ 48] BLTU (not taken): fallthrough executed
  //   [ 49] BGEU (taken): fallthrough squashed
  //   [ 50] BGEU (not taken): fallthrough executed
  //   [ 51] LB sign-extends 0xAB
  //   [ 52] LBU zero-extends 0xAB
  //   [ 53] LH sign-extends
  //   [ 54] LHU zero-extends
  //   [ 55] LW sign-extends
  //   [ 56] LWU zero-extends
  //   [ 57] SD/LD round-trip
  //   [ 58] little-endian byte 0
  //   [ 59] little-endian byte 7
  //   [ 60] load-use hazard forwarded correctly
  //   [ 61] back-to-back RAW chain (EX/MEM fwd)
  //   [ 62] x0 stays zero after write attempt
  //   [ 63] execution resumed at TRAP_PC after illegal instr
  //   [ 64] MUL pos*pos
  //   [ 65] MUL neg*pos
  //   [ 66] MUL wraps mod 2^64
  //   [ 67] MULH signed*signed
  //   [ 68] MULHU unsigned*unsigned
  //   [ 69] MULHSU signed(rs1)*unsigned(rs2)
  //   [ 70] MULW low32 * low32, sign-extended
  //   [ 71] MULW negative operands
  //   [ 72] DIV pos/pos
  //   [ 73] DIV neg/pos (truncates toward 0)
  //   [ 74] DIV pos/neg
  //   [ 75] DIVU
  //   [ 76] REM pos%pos
  //   [ 77] REM neg%pos (sign follows dividend)
  //   [ 78] REMU
  //   [ 79] DIV by zero -> all-ones
  //   [ 80] DIVU by zero -> all-ones
  //   [ 81] REM by zero -> dividend
  //   [ 82] REMU by zero -> dividend
  //   [ 83] DIV overflow INT64_MIN/-1 -> INT64_MIN
  //   [ 84] REM overflow INT64_MIN%-1 -> 0
  //   [ 85] DIVW word-signed
  //   [ 86] DIVUW word-unsigned
  //   [ 87] REMW word-signed
  //   [ 88] REMUW word-unsigned
  //   [ 89] DIVW overflow INT32_MIN/-1
  //   [ 90] REMW overflow INT32_MIN%-1 -> 0
  //   [ 91] DIV -> immediately-dependent ADD (MDU busy-stall)

endmodule