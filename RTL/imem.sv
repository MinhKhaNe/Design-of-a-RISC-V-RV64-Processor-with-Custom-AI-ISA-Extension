module imem #(
    parameter int    MEM_BYTES = 4096,
    parameter string INIT_FILE = ""
) (
    input  logic [63:0] addr,
    output logic [31:0] instr
);

    localparam int AW = $clog2(MEM_BYTES);           // byte-address bits
    localparam int NW = MEM_BYTES / 2;               // number of 16-bit parcels

    logic [15:0] mem [0:NW-1];

    initial begin
      for (int i = 0; i < NW; i++) mem[i] = 16'h0001;   // c.nop: harmless wrong-path fetches
      if (INIT_FILE != "") begin
        $readmemh(INIT_FILE, mem);
      end else begin

        // ===== C.LI / C.ADD / C.MV / C.ADDI / C.ADDIW / C.SLLI =====
        // 0x000: c.li x1, 5                 -> x1 = 5
        mem[0]  = 16'h4095;
        // 0x002: c.li x2, -3                -> x2 = -3
        mem[1]  = 16'h5175;
        // 0x004: c.add x1, x2               -> x1 = 2
        mem[2]  = 16'h908A;
        // 0x006: c.mv x3, x1                -> x3 = 2
        mem[3]  = 16'h8186;
        // 0x008: c.addi x3, 10              -> x3 = 12
        mem[4]  = 16'h01A9;
        // 0x00a: c.addiw x3, -1             -> x3 = 11
        mem[5]  = 16'h31FD;
        // 0x00c: c.slli x3, 4               -> x3 = 0xb0
        mem[6]  = 16'h0192;

        // ===== C.LUI =====
        // 0x00e: c.lui x4, 1                -> x4 = 0x1000
        mem[7]  = 16'h6205;
        // 0x010: c.lui x5, -1 (0xfffff)     -> x5 = 0xfffffffffffff000
        mem[8]  = 16'h72FD;

        // ===== C.ADDI16SP / C.ADDI4SPN (sp = x2) =====
        // 0x012: c.li x2, 16                -> x2 = 0x10
        mem[9]  = 16'h4141;
        // 0x014: c.slli x2, 4               -> x2 = 0x100
        mem[10] = 16'h0112;
        // 0x016: c.addi16sp sp, 64          -> x2 = 0x140
        mem[11] = 16'h6121;
        // 0x018: c.addi16sp sp, -32         -> x2 = 0x120
        mem[12] = 16'h713D;
        // 0x01a: c.addi4spn x8, sp, 16      -> x8 = 0x130
        mem[13] = 16'h0800;

        // ===== C.SD / C.SW / C.LD / C.LW (base x8 = 0x130) =====
        // 0x01c: c.li x9, 21                -> x9 = 0x15
        mem[14] = 16'h44D5;
        // 0x01e: c.sd x9, 0(x8)             -> mem64[0x130] = 0x15
        mem[15] = 16'hE004;
        // 0x020: c.sw x9, 8(x8)             -> mem32[0x138] = 0x15
        mem[16] = 16'hC404;
        // 0x022: c.ld x10, 0(x8)            -> x10 = 0x15
        mem[17] = 16'h6008;
        // 0x024: c.lw x11, 8(x8)            -> x11 = 0x15
        mem[18] = 16'h440C;
        // 0x026: c.li x12, -2               -> x12 = 0xfffffffffffffffe
        mem[19] = 16'h5679;
        // 0x028: c.sw x12, 16(x8)           -> mem32[0x140] = 0xfffffffe
        mem[20] = 16'hC810;
        // 0x02a: c.lw x13, 16(x8)           -> x13 = 0xfffffffffffffffe (sign-extended)
        mem[21] = 16'h4814;

        // ===== C.SDSP / C.LDSP / C.SWSP / C.LWSP (sp = 0x120) =====
        // 0x02c: c.sdsp x9, 8(sp)           -> mem64[0x128] = 0x15
        mem[22] = 16'hE426;
        // 0x02e: c.ldsp x14, 8(sp)          -> x14 = 0x15
        mem[23] = 16'h6722;
        // 0x030: c.swsp x12, 16(sp)         -> mem32[0x130] = 0xfffffffe
        mem[24] = 16'hC832;
        // 0x032: c.lwsp x15, 16(sp)         -> x15 = 0xfffffffffffffffe
        mem[25] = 16'h47C2;

        // ===== C.SUB / C.XOR / C.OR / C.AND / C.ADDW / C.SUBW =====
        // 0x034: c.li x8, 12                -> x8 = 12
        mem[26] = 16'h4431;
        // 0x036: c.li x9, 10                -> x9 = 10
        mem[27] = 16'h44A9;
        // 0x038: c.sub x8, x9               -> x8 = 2
        mem[28] = 16'h8C05;
        // 0x03a: c.xor x8, x9               -> x8 = 8
        mem[29] = 16'h8C25;
        // 0x03c: c.or x8, x9                -> x8 = 10
        mem[30] = 16'h8C45;
        // 0x03e: c.li x8, 12                -> x8 = 12
        mem[31] = 16'h4431;
        // 0x040: c.and x8, x9               -> x8 = 8
        mem[32] = 16'h8C65;
        // 0x042: c.addw x8, x9              -> x8 = 18
        mem[33] = 16'h9C25;
        // 0x044: c.subw x8, x9              -> x8 = 8
        mem[34] = 16'h9C05;

        // ===== C.SRLI / C.SRAI / C.ANDI =====
        // 0x046: c.srli x8, 1               -> x8 = 4
        mem[35] = 16'h8005;
        // 0x048: c.srai x12, 1              -> x12 = 0xffffffffffffffff
        mem[36] = 16'h8605;
        // 0x04a: c.andi x9, -4              -> x9 = 8
        mem[37] = 16'h98F1;

        // ===== C.NOP + 32-BIT INSTR AT 2-BYTE ALIGNMENT =====
        // 0x04c: c.nop
        mem[38] = 16'h0001;
        // 0x04e: addi x16, x0, 0x123        -> x16 = 0x123 (0x12300813, straddles word boundary)
        mem[39] = 16'h0813;
        mem[40] = 16'h1230;
        // 0x052: c.addi x16, 1              -> x16 = 0x124
        mem[41] = 16'h0805;

        // ===== C.BEQZ / C.BNEZ (forward) =====
        // 0x054: c.beqz x8, +4              (x8 = 4 -> NOT taken)
        mem[42] = 16'hC011;
        // 0x056: c.li x17, 1                -> executed, x17 = 1
        mem[43] = 16'h4885;
        // 0x058: c.bnez x8, +4              (taken -> 0x05c)
        mem[44] = 16'hE011;
        // 0x05a: c.li x18, 15               -> SKIPPED, x18 = 0
        mem[45] = 16'h493D;
        // 0x05c: c.li x19, 7                -> x19 = 7
        mem[46] = 16'h499D;

        // ===== C.J =====
        // 0x05e: c.j +6                     (-> 0x064)
        mem[47] = 16'hA019;
        // 0x060: c.li x20, 15               -> SKIPPED, x20 = 0
        mem[48] = 16'h4A3D;
        // 0x062: c.li x21, 15               -> SKIPPED, x21 = 0
        mem[49] = 16'h4ABD;
        // 0x064: c.li x22, 9                -> x22 = 9
        mem[50] = 16'h4B25;

        // ===== C.JALR (link must be PC+2) =====
        // 0x066: auipc x24, 0               -> x24 = 0x066 (32-bit at 2-byte alignment)
        mem[51] = 16'h0C17;
        mem[52] = 16'h0000;
        // 0x06a: c.addi x24, 12             -> x24 = 0x072
        mem[53] = 16'h0C31;
        // 0x06c: c.jalr x24                 -> x1 = 0x06e, PC = 0x072
        mem[54] = 16'h9C02;
        // 0x06e: addi x25, x0, 0x7b         -> SKIPPED (32-bit, straddles word boundary)
        mem[55] = 16'h0C93;
        mem[56] = 16'h07B0;
        // 0x072: c.mv x25, x1               -> x25 = 0x06e
        mem[57] = 16'h8C86;

        // ===== C.JR =====
        // 0x074: auipc x26, 0               -> x26 = 0x074
        mem[58] = 16'h0D17;
        mem[59] = 16'h0000;
        // 0x078: c.addi x26, 10             -> x26 = 0x07e
        mem[60] = 16'h0D29;
        // 0x07a: c.jr x26                   -> PC = 0x07e
        mem[61] = 16'h8D02;
        // 0x07c: c.li x27, 15               -> SKIPPED, x27 = 0
        mem[62] = 16'h4DBD;
        // 0x07e: c.li x28, 3                -> x28 = 3
        mem[63] = 16'h4E0D;

        // ===== MIXED 16/32-BIT WITH M-EXT + FORWARDING =====
        // 0x080: mul x29, x8, x9            -> x29 = 32 (x8 = 4, x9 = 8)
        mem[64] = 16'h0EB3;
        mem[65] = 16'h0294;
        // 0x084: c.add x29, x8              -> x29 = 36 (consumes MDU result)
        mem[66] = 16'h9EA2;
        // 0x086: div x30, x29, x8           -> x30 = 9 (32-bit at 2-byte alignment)
        mem[67] = 16'hCF33;
        mem[68] = 16'h028E;
        // 0x08a: c.add x30, x30             -> x30 = 18 (consumes MDU result)
        mem[69] = 16'h9F7A;

        // ===== LOAD-USE HAZARD WITH C INSTRS =====
        // 0x08c: c.ldsp x10, 8(sp)          -> x10 = 0x15
        mem[70] = 16'h6522;
        // 0x08e: c.add x10, x10             -> x10 = 0x2a (needs load-use stall)
        mem[71] = 16'h952A;

        // ===== C.BEQZ TAKEN / C.BNEZ NOT TAKEN =====
        // 0x090: c.li x8, 0                 -> x8 = 0
        mem[72] = 16'h4401;
        // 0x092: c.beqz x8, +4              (taken -> 0x096)
        mem[73] = 16'hC011;
        // 0x094: c.li x31, 15               -> SKIPPED
        mem[74] = 16'h4FBD;
        // 0x096: c.bnez x8, +4              (NOT taken)
        mem[75] = 16'hE011;
        // 0x098: c.li x31, 21               -> x31 = 21
        mem[76] = 16'h4FD5;

        // ===== BACKWARD C.BNEZ LOOP =====
        // 0x09a: c.li x8, 3
        mem[77] = 16'h440D;
        // 0x09c: c.li x9, 0
        mem[78] = 16'h4481;
        // 0x09e: c.addi x9, 1               (loop body)
        mem[79] = 16'h0485;
        // 0x0a0: c.addi x8, -1
        mem[80] = 16'h147D;
        // 0x0a2: c.bnez x8, -4              (-> 0x09e; ends with x8 = 0, x9 = 3)
        mem[81] = 16'hFC75;

        // ===== END: infinite loop =====
        // 0x0a4: c.j 0
        mem[82] = 16'hA001;

      end
    end

    // PC is a byte address; fetch two consecutive 16-bit parcels.
    // If instr[1:0] != 2'b11, only instr[15:0] is valid (compressed).
    logic [AW-2:0] a, a1;
    assign a     = addr[AW-1:1];
    assign a1    = a + 1'b1;                         // wraps inside the memory
    assign instr = {mem[a1], mem[a]};

endmodule