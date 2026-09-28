import rv64im_pkg::*;

module rv64im_top #(
    parameter logic [63:0] RESET_PC = 64'h0,
    parameter logic [63:0] TRAP_PC  = 64'h0   // redirect target on illegal instruction
) (
    input  logic clk,
    input  logic rst_n,

    // debug/observability
    output logic [63:0] pc_o,
    output logic         stall_o,
    output logic         flush_o,
    output logic         illegal_instr_o   // pulses for one cycle when an illegal instr reaches EX
);

  // =================================================================
  // IF stage
  // =================================================================
  logic [63:0] pc, pc_plus4;
  logic [31:0] if_instr;
  logic        stall, flush;
  logic [63:0] redirect_target;

  assign pc_plus4 = pc + 64'd4;
  assign pc_o      = pc;
  assign stall_o    = stall;
  assign flush_o    = flush;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)        pc <= RESET_PC;
    else if (flush)    pc <= redirect_target;
    else if (stall)    pc <= pc;              // hold
    else               pc <= pc_plus4;
  end

  imem imem_inst (
      .addr  (pc),
      .instr (if_instr)
  );

  // =================================================================
  // IF/ID pipeline register
  // =================================================================
  logic [63:0] ifid_pc, ifid_pc4;
  logic [31:0] ifid_instr;
  logic        ifid_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ifid_valid <= 1'b0;
    end else if (flush) begin
      ifid_valid <= 1'b0;                     
    end else if (stall) begin
      // hold current contents (write-disable)
    end else begin
      ifid_pc    <= pc;
      ifid_pc4   <= pc_plus4;
      ifid_instr <= if_instr;
      ifid_valid <= 1'b1;
    end
  end

  // =================================================================
  // ID stage
  // =================================================================
  logic [4:0]     id_rs1, id_rs2, id_rd;
  logic            id_rs1_used, id_rs2_used;
  imm_type_e      id_imm_type;
  alu_op_e        id_alu_op;
  alu_a_sel_e     id_alu_a_sel;
  alu_b_sel_e     id_alu_b_sel;
  logic           id_is_mul, id_is_div;
  mul_op_e        id_mul_op;
  div_op_e        id_div_op;
  branch_type_e   id_branch_type;
  logic           id_is_jal, id_is_jalr;
  logic           id_mem_read, id_mem_write;
  mem_width_e     id_mem_width;
  logic           id_reg_write;
  wb_sel_e        id_wb_sel;
  logic           id_illegal;

  decoder decoder_inst (
      .instr         (ifid_instr),
      .rs1           (id_rs1),
      .rs2           (id_rs2),
      .rd            (id_rd),
      .imm_type      (id_imm_type),
      .rs1_used      (id_rs1_used),
      .rs2_used      (id_rs2_used),
      .alu_op        (id_alu_op),
      .alu_a_sel     (id_alu_a_sel),
      .alu_b_sel     (id_alu_b_sel),
      .is_mul        (id_is_mul),
      .is_div        (id_is_div),
      .mul_op        (id_mul_op),
      .div_op        (id_div_op),
      .branch_type   (id_branch_type),
      .is_jal        (id_is_jal),
      .is_jalr       (id_is_jalr),
      .mem_read      (id_mem_read),
      .mem_write     (id_mem_write),
      .mem_width     (id_mem_width),
      .reg_write     (id_reg_write),
      .wb_sel        (id_wb_sel),
      .illegal_instr (id_illegal)
  );

  logic [63:0] id_imm;

  imm_gen imm_gen_inst (
      .instr    (ifid_instr),
      .imm_type (id_imm_type),
      .imm_o    (id_imm)
  );

  logic [63:0] id_rs1_data, id_rs2_data;

  // regfile write port driven by WB stage (declared below, forward-ref
  // via wires connected further down)
  logic [63:0] wb_data;
  logic [4:0]  memwb_rd;
  logic        memwb_reg_write;

  regfile regfile_inst (
      .clk         (clk),
      .rst_n       (rst_n),
      .rs1_addr    (id_rs1),
      .rs2_addr    (id_rs2),
      .rs1_data    (id_rs1_data),
      .rs2_data    (id_rs2_data),
      .rd_addr     (memwb_rd),
      .rd_data     (wb_data),
      .rd_write_en (memwb_reg_write)
  );

  // ---- Hazard detection (load-use) ----
  logic idex_mem_read;   // from ID/EX register, declared below
  logic [4:0] idex_rd;
  logic idex_valid;
  logic hazard_stall;

  hazard_unit hazard_inst (
      .idex_mem_read (idex_mem_read && idex_valid),
      .idex_rd       (idex_rd),
      .ifid_rs1      (id_rs1),
      .ifid_rs2      (id_rs2),
      .ifid_rs1_used (id_rs1_used),
      .ifid_rs2_used (id_rs2_used),
      .stall         (hazard_stall)
  );

  // ---- RV64M structural hazard: hold the whole pipeline while the
  //      multiply/divide unit (instantiated in the EX section below)
  //      is still working on the instruction already latched in ID/EX.
  logic        mdu_busy;
  logic [63:0] mdu_result;

  assign stall = hazard_stall || mdu_busy;

  // =================================================================
  // ID/EX pipeline register
  // =================================================================
  logic [63:0]   idex_pc, idex_pc4, idex_rs1_data, idex_rs2_data, idex_imm;
  logic [4:0]    idex_rs1, idex_rs2;
  alu_op_e       idex_alu_op;
  alu_a_sel_e    idex_alu_a_sel;
  alu_b_sel_e    idex_alu_b_sel;
  logic          idex_is_mul, idex_is_div;
  mul_op_e       idex_mul_op;
  div_op_e       idex_div_op;
  branch_type_e  idex_branch_type;
  logic          idex_is_jal, idex_is_jalr;
  logic          idex_mem_write;
  mem_width_e    idex_mem_width;
  logic          idex_reg_write;
  wb_sel_e       idex_wb_sel;
  logic          idex_illegal;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      idex_valid <= 1'b0;
    end else if (flush) begin
      idex_valid <= 1'b0;               // squash: older taken branch/jump/trap in EX
    end else if (mdu_busy) begin
      // hold: the M-extension unit is still working on the instruction
      // already sitting here. Don't accept a new one, don't bubble it.
    end else if (hazard_stall) begin
      idex_valid <= 1'b0;               // insert load-use bubble
    end else begin
      idex_pc          <= ifid_pc;
      idex_pc4          <= ifid_pc4;
      idex_rs1_data     <= id_rs1_data;
      idex_rs2_data     <= id_rs2_data;
      idex_imm          <= id_imm;
      idex_rs1          <= id_rs1;
      idex_rs2          <= id_rs2;
      idex_rd           <= id_rd;
      idex_alu_op       <= id_alu_op;
      idex_alu_a_sel    <= id_alu_a_sel;
      idex_alu_b_sel    <= id_alu_b_sel;
      idex_is_mul       <= id_is_mul;
      idex_is_div       <= id_is_div;
      idex_mul_op       <= id_mul_op;
      idex_div_op       <= id_div_op;
      idex_branch_type  <= id_branch_type;
      idex_is_jal       <= id_is_jal;
      idex_is_jalr      <= id_is_jalr;
      idex_mem_read     <= id_mem_read;
      idex_mem_write    <= id_mem_write;
      idex_mem_width    <= id_mem_width;
      idex_reg_write    <= id_reg_write;
      idex_wb_sel       <= id_wb_sel;
      idex_illegal      <= id_illegal;
      idex_valid        <= ifid_valid;  // propagate an upstream bubble
    end
  end

  // =================================================================
  // EX stage
  // =================================================================
  logic exmem_reg_write;   // from EX/MEM register, declared below
  logic [4:0] exmem_rd;
  logic [63:0] exmem_alu_result;

  logic [1:0] forward_a, forward_b;

  forward_unit forward_inst (
      .idex_rs1        (idex_rs1),
      .idex_rs2        (idex_rs2),
      .exmem_reg_write (exmem_reg_write),
      .exmem_rd        (exmem_rd),
      .memwb_reg_write (memwb_reg_write),
      .memwb_rd        (memwb_rd),
      .forward_a       (forward_a),
      .forward_b       (forward_b)
  );

  logic [63:0] fwd_rs1, fwd_rs2;

  always_comb begin
    case (forward_a)
      2'b01:   fwd_rs1 = exmem_alu_result;
      2'b10:   fwd_rs1 = wb_data;
      default: fwd_rs1 = idex_rs1_data;
    endcase
    case (forward_b)
      2'b01:   fwd_rs2 = exmem_alu_result;
      2'b10:   fwd_rs2 = wb_data;
      default: fwd_rs2 = idex_rs2_data;
    endcase
  end

  // ---- RV64M execution unit ----
  logic mdu_req;
  assign mdu_req = idex_valid && (idex_is_mul || idex_is_div);

  mul_div_unit mul_div_inst (
      .clk    (clk),
      .rst_n  (rst_n),
      .req    (mdu_req),
      .is_mul (idex_is_mul),
      .is_div (idex_is_div),
      .mul_op (idex_mul_op),
      .div_op (idex_div_op),
      .a      (fwd_rs1),
      .b      (fwd_rs2),
      .busy   (mdu_busy),
      .done   (),               // exmem capture below is gated by !mdu_busy instead
      .result (mdu_result)
  );

  logic [63:0] ex_alu_a, ex_alu_b, ex_alu_result;
  logic        ex_alu_zero;

  always_comb begin
    case (idex_alu_a_sel)
      ALU_A_REG:  ex_alu_a = fwd_rs1;
      ALU_A_PC:   ex_alu_a = idex_pc;
      ALU_A_ZERO: ex_alu_a = 64'b0;
      default:    ex_alu_a = fwd_rs1;
    endcase
  end

  assign ex_alu_b = (idex_alu_b_sel == ALU_B_IMM) ? idex_imm : fwd_rs2;

  alu alu_inst (
      .alu_op (idex_alu_op),
      .a      (ex_alu_a),
      .b      (ex_alu_b),
      .result (ex_alu_result),
      .zero   (ex_alu_zero)
  );

  logic ex_br_taken;

  branch_comp branch_comp_inst (
      .branch_type (idex_branch_type),
      .rs1_data    (fwd_rs1),
      .rs2_data    (fwd_rs2),
      .taken       (ex_br_taken)
  );

  // Control-flow resolution (JAL target computed directly from the
  // carried PC+imm since it needs no register operand; JALR/branch
  // targets come from the ALU as in the single-cycle design)
  logic [63:0] ex_jal_target, ex_jalr_target;

  assign ex_jal_target  = idex_pc + idex_imm;
  assign ex_jalr_target = ex_alu_result & ~64'h1;

  always_comb begin
    flush            = 1'b0;
    redirect_target  = pc_plus4; // don't-care default
    illegal_instr_o  = 1'b0;
    if (idex_valid && idex_illegal) begin
      // illegal instruction takes priority: don't trust its (possibly
      // garbage) control signals enough to let it redirect the PC itself
      flush            = 1'b1;
      redirect_target  = TRAP_PC;
      illegal_instr_o  = 1'b1;
    end else if (idex_valid && idex_is_jal) begin
      flush = 1'b1;
      redirect_target = ex_jal_target;
    end else if (idex_valid && idex_is_jalr) begin
      flush = 1'b1;
      redirect_target = ex_jalr_target;
    end else if (idex_valid && (idex_branch_type != BR_NONE) && ex_br_taken) begin
      flush = 1'b1;
      redirect_target = ex_alu_result; // PC + imm_B, computed by ALU (alu_a_sel=PC for branches)
    end
  end

  // =================================================================
  // EX/MEM pipeline register
  // =================================================================
  logic [63:0] exmem_store_data, exmem_pc4;
  logic        exmem_mem_write, exmem_valid;
  mem_width_e  exmem_mem_width;
  wb_sel_e     exmem_wb_sel;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      exmem_valid <= 1'b0;
    end else if (mdu_busy) begin
      // multiply/divide result isn't ready yet: hold this slot as a
      // bubble so nothing commits (regfile write / store) prematurely.
      exmem_valid     <= 1'b0;
      exmem_reg_write <= 1'b0;
      exmem_mem_write <= 1'b0;
    end else begin
      exmem_alu_result <= (idex_is_mul || idex_is_div) ? mdu_result : ex_alu_result;
      exmem_store_data <= fwd_rs2;
      exmem_pc4        <= idex_pc4;
      exmem_rd         <= idex_rd;
      exmem_mem_write  <= idex_mem_write && idex_valid && !idex_illegal;
      exmem_mem_width  <= idex_mem_width;
      exmem_reg_write  <= idex_reg_write && idex_valid && !idex_illegal;
      exmem_wb_sel     <= idex_wb_sel;
      exmem_valid      <= idex_valid;
    end
  end

  // =================================================================
  // MEM stage
  // =================================================================
  logic [63:0] mem_rdata;

  dmem dmem_inst (
      .clk       (clk),
      .addr      (exmem_alu_result),
      .wdata     (exmem_store_data),
      .mem_write (exmem_mem_write),
      .width     (exmem_mem_width),
      .rdata     (mem_rdata)
  );

  // =================================================================
  // MEM/WB pipeline register
  // =================================================================
  logic [63:0] memwb_mem_rdata, memwb_alu_result, memwb_pc4;
  wb_sel_e     memwb_wb_sel;
  logic        memwb_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      memwb_valid <= 1'b0;
    end else begin
      memwb_mem_rdata  <= mem_rdata;
      memwb_alu_result <= exmem_alu_result;
      memwb_pc4        <= exmem_pc4;
      memwb_rd         <= exmem_rd;
      memwb_reg_write  <= exmem_reg_write;
      memwb_wb_sel     <= exmem_wb_sel;
      memwb_valid      <= exmem_valid;
    end
  end

  // =================================================================
  // WB stage
  // =================================================================
  always_comb begin
    case (memwb_wb_sel)
      WB_ALU:  wb_data = memwb_alu_result;
      WB_MEM:  wb_data = memwb_mem_rdata;
      WB_PC4:  wb_data = memwb_pc4;
      WB_MEXT: wb_data = memwb_alu_result;   // MUL/DIV result rides the ALU-result field
      default: wb_data = memwb_alu_result;
    endcase
  end

endmodule