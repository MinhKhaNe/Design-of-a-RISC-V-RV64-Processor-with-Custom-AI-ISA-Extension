import rv64imafc_pkg::*;

module rv64imafc_top #(
    parameter logic [63:0] RESET_PC = 64'h0,
    parameter logic [63:0] TRAP_PC  = 64'h0,  // redirect target on illegal instruction
    parameter int          IMEM_BYTES = 4096, // powers of two
    parameter int          DMEM_BYTES = 4096,
    parameter string       IMEM_INIT  = "",   // $readmemh files (see imem.sv / dmem.sv)
    parameter string       DMEM_INIT  = ""
) (
    input  logic        clk,
    input  logic        rst_n,

    // debug/observability
    output logic [63:0] pc_o,
    output logic        stall_o,
    output logic        flush_o,
    output logic        illegal_instr_o   // pulses for one cycle when an illegal instr reaches EX
);

  // IF stage
  logic [63:0]    pc, pc_next;
  logic [31:0]    if_instr;
  logic           stall, flush;
  logic [63:0]    redirect_target;

  //IF/ID internal signals
  logic           if_is_compressed;
  logic [31:0]    if_instr_expanded;
  logic           if_c_illegal;
  logic [63:0]    ifid_pc, ifid_pc_next;
  logic [31:0]    ifid_instr;
  logic           ifid_valid;
  logic           ifid_c_illegal;   

  // ID stage
  logic [4:0]     id_rs1, id_rs2, id_rs3, id_rd;
  logic           id_rs1_used, id_rs2_used, id_rs3_used;
  logic           id_rs1_fp, id_rs2_fp;
  logic           id_is_fpu, id_uses_rm, id_fp_reg_write, id_is_csr;
  logic           id_is_amo, id_is_lr, id_is_sc;
  amo_op_e        id_amo_op;
  fpu_op_e        id_fpu_op;
  logic [2:0]     id_funct3;
  logic [63:0]    id_int_rs1_data, id_int_rs2_data;
  logic [31:0]    id_fp_rs1_data, id_fp_rs2_data, id_fp_rs3_data;
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
  logic [63:0]    id_imm;
  logic [63:0]    id_rs1_data, id_rs2_data;

  logic [63:0]    wb_data;
  logic [4:0]     memwb_rd;
  logic           memwb_reg_write;
  logic           memwb_fp_reg_write;

  //  RV64M structural hazard
  logic           mdu_busy;
  logic [63:0]    mdu_result;

  // Hazard detection
  logic           idex_mem_read;   // from ID/EX register, declared below
  logic           idex_fp_reg_write;
  logic [4:0]     idex_rd;
  logic           idex_valid;
  logic           hazard_stall;

  // ID/EX pipeline register
  logic [63:0]    idex_pc, idex_pc_next, idex_rs1_data, idex_rs2_data, idex_imm;
  logic [4:0]     idex_rs1, idex_rs2, idex_rs3;
  logic [31:0]    idex_rs3_data;
  logic           idex_rs1_fp, idex_rs2_fp;
  logic           idex_is_fpu, idex_uses_rm, idex_is_csr;
  logic           idex_is_amo, idex_is_lr, idex_is_sc;
  amo_op_e        idex_amo_op;
  fpu_op_e        idex_fpu_op;
  logic [2:0]     idex_funct3;
  logic [11:0]    idex_csr_addr;
  alu_op_e        idex_alu_op;
  alu_a_sel_e     idex_alu_a_sel;
  alu_b_sel_e     idex_alu_b_sel;
  logic           idex_is_mul, idex_is_div;
  mul_op_e        idex_mul_op;
  div_op_e        idex_div_op;
  branch_type_e   idex_branch_type;
  logic           idex_is_jal, idex_is_jalr;
  logic           idex_mem_write;
  mem_width_e     idex_mem_width;
  logic           idex_reg_write;
  wb_sel_e        idex_wb_sel;
  logic           idex_illegal;

  logic [63:0]    fwd_rs1, fwd_rs2;
  logic [31:0]    fwd_rs3;

  // EX stage
  logic           exmem_reg_write; 
  logic           exmem_fp_reg_write;
  logic [4:0]     exmem_rd;
  logic [63:0]    exmem_alu_result;
  logic [63:0]    ex_alu_a, ex_alu_b, ex_alu_result;
  logic           ex_alu_zero;
  logic           ex_br_taken;

  // EX/MEM pipeline register
  logic [63:0]    exmem_store_data, exmem_pc_next;
  logic           exmem_mem_write, exmem_valid;
  mem_width_e     exmem_mem_width;
  wb_sel_e        exmem_wb_sel;
  logic           exmem_is_amo, exmem_is_lr, exmem_is_sc;
  amo_op_e        exmem_amo_op;
  logic [63:0]    ex_jal_target, ex_jalr_target;


  logic [1:0]     forward_a, forward_b;
  logic [1:0]     fp_forward_a, fp_forward_b, fp_forward_c;
  logic           mdu_req;

  // RV64F: FPU / fcsr
  logic           fpu_req, fpu_busy, ex_busy;
  logic [63:0]    fpu_result;
  logic [4:0]     fpu_flags;
  logic [2:0]     frm, rm_eff;
  logic           rm_bad, ex_illegal;
  logic [63:0]    csr_rdata, csr_src, csr_wdata, ex_result;
  logic           csr_hit, csr_we;
  logic [31:0]    fp_wb_data;

  // MEM stage
  logic [63:0]    mem_rdata;

  // RV64A
  logic           ex_amo_class, ex_amo_misaligned;
  logic [63:0]    amo_new, mem_wdata;
  logic           mem_we, sc_ok;
  logic           resv_valid;
  logic [63:0]    resv_addr;

  // MEM/WB pipeline register
  logic [63:0]    memwb_mem_rdata, memwb_alu_result, memwb_pc_next;
  wb_sel_e        memwb_wb_sel;
  logic           memwb_valid;

  logic [63:0]    fcsr_rdata, cnt_rdata;
  logic           fcsr_hit, cnt_hit, cnt_ro;
  logic           csr_wr_req, csr_ro_viol, ex_retire;

  assign ex_jal_target    = idex_pc + idex_imm;
  assign ex_jalr_target   = ex_alu_result & ~64'h1;
  assign mdu_req          = idex_valid && (idex_is_mul || idex_is_div);
  assign ex_busy          = mdu_busy || fpu_busy;
  assign stall            = hazard_stall || ex_busy;
  assign pc_next          = pc + (if_is_compressed ? 64'd2 : 64'd4);
  assign if_is_compressed = (if_instr[1:0] != 2'b11);
  assign pc_o             = pc;
  assign stall_o          = stall;
  assign flush_o          = flush;
  assign csr_hit          = fcsr_hit | cnt_hit;
  assign csr_rdata        = fcsr_hit ? fcsr_rdata : cnt_rdata;

  // CSRRW always writes; CSRRS/C (and *I forms) write only if rs1/zimm != 0
  assign csr_wr_req       = idex_is_csr && (idex_funct3[1:0] == 2'b01 || idex_rs1 != 5'd0);
  assign csr_ro_viol      = csr_wr_req && cnt_ro;
  assign csr_we           = idex_valid && csr_wr_req && !ex_illegal && csr_hit;
  assign ex_retire        = idex_valid && !ex_busy && !ex_illegal;

  imem imem_inst (
      .addr  (pc),
      .instr (if_instr)
  );

  c_expander c_expander_inst (
      .instr16   (if_instr[15:0]),
      .instr32   (if_instr_expanded),
      .c_illegal (if_c_illegal)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)        pc <= RESET_PC;
    else if (flush)    pc <= redirect_target;
    else if (stall)    pc <= pc;              // hold
    else               pc <= pc_next;
  end

  // IF/ID pipeline register
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ifid_valid <= 1'b0;
    end else if (flush) begin
      ifid_valid <= 1'b0;                   
    end else if (stall) begin
      // hold current contents (write-disable)
    end else begin
      ifid_pc        <= pc;
      ifid_pc_next   <= pc_next;
      ifid_instr     <= if_is_compressed ? if_instr_expanded : if_instr;
      ifid_c_illegal <= if_is_compressed ? if_c_illegal : 1'b0;
      ifid_valid     <= 1'b1;
    end
  end

  decoder decoder_inst (
      .instr         (ifid_instr),
      .rs1           (id_rs1),
      .rs2           (id_rs2),
      .rd            (id_rd),
      .imm_type      (id_imm_type),
      .rs1_used      (id_rs1_used),
      .rs2_used      (id_rs2_used),
      .rs3_used      (id_rs3_used),
      .rs1_fp        (id_rs1_fp),
      .rs2_fp        (id_rs2_fp),
      .is_fpu        (id_is_fpu),
      .fpu_op        (id_fpu_op),
      .uses_rm       (id_uses_rm),
      .fp_reg_write  (id_fp_reg_write),
      .is_csr        (id_is_csr),
      .is_amo        (id_is_amo),
      .is_lr         (id_is_lr),
      .is_sc         (id_is_sc),
      .amo_op        (id_amo_op),
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

  assign id_rs3    = ifid_instr[31:27];
  assign id_funct3 = ifid_instr[14:12];

  imm_gen imm_gen_inst (
      .instr    (ifid_instr),
      .imm_type (id_imm_type),
      .imm_o    (id_imm)
  );

  regfile regfile_inst (
      .clk         (clk),
      .rst_n       (rst_n),
      .rs1_addr    (id_rs1),
      .rs2_addr    (id_rs2),
      .rs1_data    (id_int_rs1_data),
      .rs2_data    (id_int_rs2_data),
      .rd_addr     (memwb_rd),
      .rd_data     (wb_data),
      .rd_write_en (memwb_reg_write)
  );

  assign fp_wb_data   = wb_data[31:0];
  assign id_rs1_data  = id_rs1_fp ? {32'b0, id_fp_rs1_data} : id_int_rs1_data;
  assign id_rs2_data  = id_rs2_fp ? {32'b0, id_fp_rs2_data} : id_int_rs2_data;

  fp_regfile fp_regfile_inst (
      .clk         (clk),
      .rst_n       (rst_n),
      .rs1_addr    (id_rs1),
      .rs2_addr    (id_rs2),
      .rs3_addr    (id_rs3),
      .rs1_data    (id_fp_rs1_data),
      .rs2_data    (id_fp_rs2_data),
      .rs3_data    (id_fp_rs3_data),
      .rd_addr     (memwb_rd),
      .rd_data     (fp_wb_data),
      .rd_write_en (memwb_fp_reg_write)
  );

  hazard_unit hazard_inst (
      .idex_mem_read (idex_mem_read && idex_valid),
      .idex_rd       (idex_rd),
      .idex_rd_fp    (idex_fp_reg_write),
      .ifid_rs1      (id_rs1),
      .ifid_rs2      (id_rs2),
      .ifid_rs3      (id_rs3),
      .ifid_rs1_used (id_rs1_used),
      .ifid_rs2_used (id_rs2_used),
      .ifid_rs3_used (id_rs3_used),
      .ifid_rs1_fp   (id_rs1_fp),
      .ifid_rs2_fp   (id_rs2_fp),
      .stall         (hazard_stall)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      idex_valid <= 1'b0;
    end else if (flush) begin
      idex_valid <= 1'b0;               // squash: older taken branch/jump/trap in EX
    end else if (ex_busy) begin
      // hold: the M-extension / FPU is still working on the instruction
      // already sitting here. Don't accept a new one, don't bubble it.
    end else if (hazard_stall) begin
      idex_valid <= 1'b0;               // insert load-use bubble
    end else begin
      idex_pc          <= ifid_pc;
      idex_pc_next     <= ifid_pc_next;
      idex_rs1_data     <= id_rs1_data;
      idex_rs2_data     <= id_rs2_data;
      idex_imm          <= id_imm;
      idex_rs1          <= id_rs1;
      idex_rs2          <= id_rs2;
      idex_rs3          <= id_rs3;
      idex_rs3_data     <= id_fp_rs3_data;
      idex_rs1_fp       <= id_rs1_fp;
      idex_rs2_fp       <= id_rs2_fp;
      idex_is_fpu       <= id_is_fpu;
      idex_fpu_op       <= id_fpu_op;
      idex_uses_rm      <= id_uses_rm;
      idex_fp_reg_write <= id_fp_reg_write;
      idex_is_csr       <= id_is_csr;
      idex_is_amo       <= id_is_amo;
      idex_is_lr        <= id_is_lr;
      idex_is_sc        <= id_is_sc;
      idex_amo_op       <= id_amo_op;
      idex_funct3       <= id_funct3;
      idex_csr_addr     <= ifid_instr[31:20];
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
      idex_illegal      <= id_illegal | ifid_c_illegal;
      idex_valid        <= ifid_valid;  // propagate an upstream bubble
    end
  end

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

  fp_forward_unit fp_forward_inst (
      .idex_rs1           (idex_rs1),
      .idex_rs2           (idex_rs2),
      .idex_rs3           (idex_rs3),
      .exmem_fp_reg_write (exmem_fp_reg_write),
      .exmem_rd           (exmem_rd),
      .memwb_fp_reg_write (memwb_fp_reg_write),
      .memwb_rd           (memwb_rd),
      .forward_a          (fp_forward_a),
      .forward_b          (fp_forward_b),
      .forward_c          (fp_forward_c)
  );

  // forward_a/b (integer file) compare register numbers only, so they are
  // ignored for operands that live in the FP register file.
  logic [1:0] sel_a, sel_b;
  assign sel_a = idex_rs1_fp ? fp_forward_a : forward_a;
  assign sel_b = idex_rs2_fp ? fp_forward_b : forward_b;

  always_comb begin
    case (sel_a)
      2'b01:   fwd_rs1 = exmem_alu_result;
      2'b10:   fwd_rs1 = wb_data;
      default: fwd_rs1 = idex_rs1_data;
    endcase
    case (sel_b)
      2'b01:   fwd_rs2 = exmem_alu_result;
      2'b10:   fwd_rs2 = wb_data;
      default: fwd_rs2 = idex_rs2_data;
    endcase
    case (fp_forward_c)
      2'b01:   fwd_rs3 = exmem_alu_result[31:0];
      2'b10:   fwd_rs3 = wb_data[31:0];
      default: fwd_rs3 = idex_rs3_data;
    endcase
  end

  // ---------------- RV64F: rounding mode, illegal check, FPU, fcsr ----------------
  assign rm_eff     = (idex_funct3 == 3'b111) ? frm : idex_funct3;
  assign rm_bad     = idex_uses_rm && (rm_eff > 3'd4);      // dynamic rm holding an invalid value
  // LR/SC/AMO must be naturally aligned; the core has no trap CSRs, so a
  // misaligned atomic takes the same TRAP_PC redirect as an illegal instruction
  // (the register write, memory write and reservation update are all squashed).
  assign ex_amo_class      = idex_is_amo || idex_is_lr || idex_is_sc;
  assign ex_amo_misaligned = ex_amo_class &&
                             ((idex_mem_width == MEM_D) ? (ex_alu_result[2:0] != 3'b000)
                                                        : (ex_alu_result[1:0] != 2'b00));
  assign ex_illegal = idex_illegal || rm_bad || ex_amo_misaligned || csr_ro_viol;
  assign fpu_req    = idex_valid && idex_is_fpu && !ex_illegal;

  fpu fpu_inst (
      .clk    (clk),
      .rst_n  (rst_n),
      .req    (fpu_req),
      .op     (idex_fpu_op),
      .rm     (rm_eff),
      .a      (fwd_rs1),
      .b      (fwd_rs2[31:0]),
      .c      (fwd_rs3),
      .busy   (fpu_busy),
      .result (fpu_result),
      .flags  (fpu_flags)
  );

  assign csr_src = idex_funct3[2] ? {59'b0, idex_rs1} : fwd_rs1;
  
  always_comb begin
    case (idex_funct3[1:0])
      2'b01:   csr_wdata = csr_src;                    // CSRRW
      2'b10:   csr_wdata = csr_rdata | csr_src;        // CSRRS
      default: csr_wdata = csr_rdata & ~csr_src;       // CSRRC
    endcase
  end
  
  fcsr fcsr_inst (
      .clk       (clk),
      .rst_n     (rst_n),
      .csr_addr  (idex_csr_addr),
      .rdata     (fcsr_rdata),      // was csr_rdata
      .hit       (fcsr_hit),        // was csr_hit
      .we        (csr_we),
      .wdata     (csr_wdata),
      .flags_set (fpu_flags & {5{fpu_req && !fpu_busy}}),
      .frm       (frm)
  );

  zicntr zicntr_inst (
      .clk       (clk),
      .rst_n     (rst_n),
      .csr_addr  (idex_csr_addr),
      .rdata     (cnt_rdata),
      .hit       (cnt_hit),
      .read_only (cnt_ro),
      .we        (csr_we),
      .wdata     (csr_wdata),
      .retire    (ex_retire)
  );

  assign ex_result = idex_is_fpu                   ? fpu_result :
                     idex_is_csr                   ? csr_rdata  :
                     (idex_is_mul || idex_is_div)  ? mdu_result : ex_alu_result;

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

  branch_comp branch_comp_inst (
      .branch_type (idex_branch_type),
      .rs1_data    (fwd_rs1),
      .rs2_data    (fwd_rs2),
      .taken       (ex_br_taken)
  );

  always_comb begin
    flush            = 1'b0;
    redirect_target  = pc_next; // don't-care default
    illegal_instr_o  = 1'b0;
    if (idex_valid && ex_illegal) begin
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

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      exmem_valid         <= 1'b0;  
      exmem_reg_write     <= 1'b0;  
      exmem_fp_reg_write  <= 1'b0;
      exmem_mem_write     <= 1'b0;  
      exmem_is_amo        <= 1'b0;  
      exmem_is_lr         <= 1'b0;  
      exmem_is_sc         <= 1'b0;
    end else if (ex_busy) begin
      exmem_valid        <= 1'b0;
      exmem_reg_write    <= 1'b0;
      exmem_fp_reg_write <= 1'b0;
      exmem_mem_write    <= 1'b0;
      exmem_is_amo       <= 1'b0;
      exmem_is_lr        <= 1'b0;
      exmem_is_sc        <= 1'b0;
    end else begin
      exmem_alu_result    <= ex_result;
      exmem_store_data    <= fwd_rs2;
      exmem_pc_next       <= idex_pc_next;
      exmem_rd            <= idex_rd;
      exmem_mem_write     <= idex_mem_write && idex_valid && !ex_illegal;
      exmem_mem_width     <= idex_mem_width;
      exmem_reg_write     <= idex_reg_write && idex_valid && !ex_illegal;
      exmem_fp_reg_write  <= idex_fp_reg_write && idex_valid && !ex_illegal;
      exmem_wb_sel        <= idex_wb_sel;
      exmem_is_amo        <= idex_is_amo && idex_valid && !ex_illegal;
      exmem_is_lr         <= idex_is_lr  && idex_valid && !ex_illegal;
      exmem_is_sc         <= idex_is_sc  && idex_valid && !ex_illegal;
      exmem_amo_op        <= idex_amo_op;
      exmem_valid         <= idex_valid;
    end
  end

  amo_alu amo_alu_inst (
      .op      (exmem_amo_op),
      .is_word (exmem_mem_width == MEM_W),
      .old     (mem_rdata),
      .src     (exmem_store_data),
      .result  (amo_new)
  );

  // SC succeeds only if a reservation is held for the same 8-byte granule.
  assign sc_ok     = resv_valid && (resv_addr[63:3] == exmem_alu_result[63:3]);
  assign mem_wdata = exmem_is_amo ? amo_new : exmem_store_data;
  assign mem_we    = exmem_mem_write && !(exmem_is_sc && !sc_ok);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      resv_valid <= 1'b0;
      resv_addr  <= 64'b0;
    end else if (illegal_instr_o) begin
      resv_valid <= 1'b0;                              // trap: drop any reservation
    end else if (exmem_valid) begin
      if (exmem_is_lr) begin
        resv_valid <= 1'b1;
        resv_addr  <= exmem_alu_result;
      end else if (exmem_is_sc) begin
        resv_valid <= 1'b0;                            // SC always consumes the reservation
      end else if (mem_we && resv_valid &&
                   (resv_addr[63:3] == exmem_alu_result[63:3])) begin
        resv_valid <= 1'b0;                            // a store/AMO hit the reserved granule
      end
    end
  end

  dmem dmem_inst (
      .clk       (clk),
      .addr      (exmem_alu_result),
      .wdata     (mem_wdata),
      .mem_write (mem_we),
      .width     (exmem_mem_width),
      .rdata     (mem_rdata)
  );
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      memwb_valid         <= 1'b0;  
      memwb_reg_write     <= 1'b0;  
      memwb_fp_reg_write  <= 1'b0;  
      memwb_rd            <= 5'b0;
    end else begin
      memwb_mem_rdata  <= exmem_is_sc ? {63'b0, !sc_ok} : mem_rdata;
      memwb_alu_result <= exmem_alu_result;
      memwb_pc_next    <= exmem_pc_next;
      memwb_rd         <= exmem_rd;
      memwb_reg_write  <= exmem_reg_write;
      memwb_fp_reg_write <= exmem_fp_reg_write;
      memwb_wb_sel     <= exmem_wb_sel;
      memwb_valid      <= exmem_valid;
    end
  end

  // WB stage
  always_comb begin
    case (memwb_wb_sel)
      WB_ALU:  wb_data = memwb_alu_result;
      WB_MEM:  wb_data = memwb_mem_rdata;
      WB_PC4:  wb_data = memwb_pc_next;   // JAL/JALR/C.JALR link value (PC + actual instr length)
      WB_MEXT: wb_data = memwb_alu_result;   // MUL/DIV result rides the ALU-result field
      default: wb_data = memwb_alu_result;
    endcase
  end

endmodule