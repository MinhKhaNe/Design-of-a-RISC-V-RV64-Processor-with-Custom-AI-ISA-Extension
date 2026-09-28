module imem (
    input  logic [63:0] addr,
    output logic [31:0] instr
);

    logic [31:0] mem [0:1023];

    initial begin

        // =========================================================
        // INTEGER IMMEDIATE
        // =========================================================

        // 0x000: addi x1, x0, 5
        mem[0] = 32'h00500093;

        // 0x004: addi x2, x0, -3
        mem[1] = 32'hFFD00113;

        // =========================================================
        // INTEGER REGISTER-REGISTER
        // =========================================================

        // 0x008: add x3, x1, x2
        mem[2] = 32'h002081B3;

        // 0x00c: sub x4, x1, x2
        mem[3] = 32'h40208233;

        // 0x010: sll x5, x1, x2
        mem[4] = 32'h002092B3;

        // 0x014: slt x6, x2, x1
        mem[5] = 32'h00112333;

        // 0x018: sltu x7, x2, x1
        mem[6] = 32'h001133B3;

        // 0x01c: xor x8, x1, x2
        mem[7] = 32'h0020C433;

        // 0x020: srl x9, x1, x2
        mem[8] = 32'h0020D4B3;

        // 0x024: sra x10, x2, x1
        mem[9] = 32'h40115533;

        // 0x028: or x11, x1, x2
        mem[10] = 32'h0020E5B3;

        // 0x02c: and x12, x1, x2
        mem[11] = 32'h0020F633;

        // =========================================================
        // INTEGER IMMEDIATE
        // =========================================================

        // 0x030: slti x13, x2, -2
        mem[12] = 32'hFFE12693;

        // 0x034: sltiu x14, x2, 2
        mem[13] = 32'h00213713;

        // 0x038: xori x15, x1, 0x55
        mem[14] = 32'h0550C793;

        // 0x03c: ori x16, x1, 0x30
        mem[15] = 32'h0300E813;

        // 0x040: andi x17, x1, 7
        mem[16] = 32'h0070F893;

        // 0x044: slli x18, x1, 2
        mem[17] = 32'h00209913;

        // 0x048: srli x19, x1, 1
        mem[18] = 32'h0010D993;

        // 0x04c: srai x20, x2, 1
        mem[19] = 32'h40115A13;

        // =========================================================
        // RV64I W-INSTRUCTIONS
        // =========================================================

        // 0x050: addiw x21, x1, 7
        mem[20] = 32'h00708A9B;

        // 0x054: slliw x22, x1, 2
        mem[21] = 32'h00209B1B;

        // 0x058: srliw x23, x1, 1
        mem[22] = 32'h0010DB9B;

        // 0x05c: sraiw x24, x2, 1
        mem[23] = 32'h40115C1B;

        // 0x060: addw x25, x1, x2
        mem[24] = 32'h00208CBB;

        // 0x064: subw x26, x1, x2
        mem[25] = 32'h40208D3B;

        // 0x068: sllw x27, x1, x2
        mem[26] = 32'h00209DBB;

        // 0x06c: srlw x28, x1, x2
        mem[27] = 32'h0020DE3B;

        // 0x070: sraw x29, x2, x1
        mem[28] = 32'h40115EBB;

        // =========================================================
        // LUI / AUIPC
        // =========================================================

        // 0x074: lui x30, 0x12345
        mem[29] = 32'h12345F37;

        // 0x078: auipc x31, 0
        mem[30] = 32'h00000F97;

        // =========================================================
        // STORE
        // =========================================================

        // 0x07c: sb x1, 64(x0)
        mem[31] = 32'h04100023;

        // 0x080: sh x2, 72(x0)
        mem[32] = 32'h04201423;

        // 0x084: sw x3, 80(x0)
        mem[33] = 32'h04302823;

        // 0x088: sd x4, 88(x0)
        mem[34] = 32'h04403C23;

        // =========================================================
        // LOAD
        // =========================================================

        // 0x08c: lb x1, 64(x0)
        mem[35] = 32'h04000083;

        // 0x090: lh x2, 72(x0)
        mem[36] = 32'h04801103;

        // 0x094: lw x3, 80(x0)
        mem[37] = 32'h05002183;

        // 0x098: ld x4, 88(x0)
        mem[38] = 32'h05803203;

        // 0x09c: lbu x5, 64(x0)
        mem[39] = 32'h04004283;

        // 0x0a0: lhu x6, 72(x0)
        mem[40] = 32'h04805303;

        // 0x0a4: lwu x7, 80(x0)
        mem[41] = 32'h05006383;

        // =========================================================
        // BRANCH
        // =========================================================

        // 0x0a8: beq x1,x1,+8
        // skip next instruction
        mem[42] = 32'h00108463;

        // skipped
        // addi x20,x0,111
        mem[43] = 32'h06F00A13;

        // 0x0b0: bne x1,x2,+8
        mem[44] = 32'h00209463;

        // skipped
        mem[45] = 32'h0DE00A13;

        // 0x0b8: blt x2,x1,+8
        mem[46] = 32'h00114463;

        // skipped
        mem[47] = 32'h14D00A13;

        // 0x0c0: bge x1,x2,+8
        mem[48] = 32'h0020D463;

        // skipped
        mem[49] = 32'h1BC00A13;

        // 0x0c8: bltu x2,x1,+8
        // NOT TAKEN
        mem[50] = 32'h00116463;

        // 0x0cc: executed
        mem[51] = 32'h22B00A13;

        // 0x0d0: bgeu x2,x1,+8  (taken -> 0x0d8)
        mem[52] = 32'h00117463;

        // skipped
        mem[53] = 32'h29A00A13;

        // =========================================================
        // JAL
        // =========================================================

        // 0x0d8: jal x21,+8   (target 0x0e0)
        mem[54] = 32'h00800AEF;

        // 0x0dc: skipped
        mem[55] = 32'h30900A93;

        // =========================================================
        // JALR
        // =========================================================

        // 0x0e0: auipc x22,0            -> x22 = 0x0e0
        mem[56] = 32'h00000B17;

        // 0x0e4: addi x22,x22,16        -> x22 = 0x0f0 (address of the jalr target)
        //   FIX: was 32'h008B0B13 (imm=8 -> x22=0x0e8 = the jalr itself,
        //   which made the CPU jump to itself forever)
        mem[57] = 32'h010B0B13;

        // 0x0e8: jalr x23,x22,0         -> x23 = 0x0ec, PC = 0x0f0
        mem[58] = 32'h000B0BE7;

        // 0x0ec: skipped
        mem[59] = 32'h37800C13;

        // 0x0f0: jalr target: addi x25,x0,0x3e7 (x25 is overwritten later by the M tests)
        mem[60] = 32'h3E700C93;

        // =========================================================
        // RV64M TESTS  (x1 = -7, x2 = 3 unless noted)
        // =========================================================

        // 0x0f4: addi x1, x0, -7
        //        expect x1 = -7
        mem[61] = 32'hFF900093;

        // 0x0f8: addi x2, x0, 3
        //        expect x2 = 3
        mem[62] = 32'h00300113;

        // 0x0fc: mul   x3, x1, x2
        //        expect x3 = 0xffffffffffffffeb
        mem[63] = 32'h022081B3;

        // 0x100: mulh  x4, x1, x2
        //        expect x4 = 0xffffffffffffffff
        mem[64] = 32'h02209233;

        // 0x104: mulhsu x5, x1, x2
        //        expect x5 = 0xffffffffffffffff
        mem[65] = 32'h0220A2B3;

        // 0x108: mulhu x6, x1, x2
        //        expect x6 = 0x0000000000000002
        mem[66] = 32'h0220B333;

        // 0x10c: div   x7, x1, x2
        //        expect x7 = 0xfffffffffffffffe
        mem[67] = 32'h0220C3B3;

        // 0x110: divu  x8, x1, x2
        //        expect x8 = 0x5555555555555553
        mem[68] = 32'h0220D433;

        // 0x114: rem   x9, x1, x2
        //        expect x9 = 0xffffffffffffffff
        mem[69] = 32'h0220E4B3;

        // 0x118: remu  x10, x1, x2
        //        expect x10 = 0x0000000000000000
        mem[70] = 32'h0220F533;

        // 0x11c: div   x11, x1, x0
        //        expect x11 = 0xffffffffffffffff  (div by 0 -> -1)
        mem[71] = 32'h0200C5B3;

        // 0x120: divu  x12, x1, x0
        //        expect x12 = 0xffffffffffffffff  (divu by 0 -> all ones)
        mem[72] = 32'h0200D633;

        // 0x124: rem   x13, x1, x0
        //        expect x13 = 0xfffffffffffffff9  (rem by 0 -> dividend)
        mem[73] = 32'h0200E6B3;

        // 0x128: remu  x14, x1, x0
        //        expect x14 = 0xfffffffffffffff9  (remu by 0 -> dividend)
        mem[74] = 32'h0200F733;

        // 0x12c: addi  x15, x0, 1
        mem[75] = 32'h00100793;

        // 0x130: slli  x15, x15, 63
        //        expect x15 = 0x8000000000000000
        mem[76] = 32'h03F79793;

        // 0x134: addi  x16, x0, -1
        mem[77] = 32'hFFF00813;

        // 0x138: div   x17, x15, x16
        //        expect x17 = 0x8000000000000000  (overflow -> dividend)
        mem[78] = 32'h0307C8B3;

        // 0x13c: rem   x18, x15, x16
        //        expect x18 = 0            (overflow -> 0)
        mem[79] = 32'h0307E933;

        // 0x140: mulw  x19, x1, x2
        //        expect x19 = 0xffffffffffffffeb
        mem[80] = 32'h022089BB;

        // 0x144: divw  x20, x1, x2
        //        expect x20 = 0xfffffffffffffffe
        mem[81] = 32'h0220CA3B;

        // 0x148: divuw x21, x1, x2
        //        expect x21 = 0x0000000055555553
        mem[82] = 32'h0220DABB;

        // 0x14c: remw  x22, x1, x2
        //        expect x22 = 0xffffffffffffffff
        mem[83] = 32'h0220EB3B;

        // 0x150: remuw x23, x1, x2
        //        expect x23 = 0x0000000000000000
        mem[84] = 32'h0220FBBB;

        // 0x154: mul   x24, x3, x2
        //        expect x24 = 0xffffffffffffffc1  (uses x3 from mul above)
        mem[85] = 32'h02218C33;

        // 0x158: add   x25, x24, x2
        //        expect x25 = 0xffffffffffffffc4  (consumes MDU result right after it)
        mem[86] = 32'h002C0CB3;

        // =========================================================
        // END: infinite loop
        // =========================================================

        // 0x15c: jal x0, 0
        mem[87] = 32'h0000006F;

    end

    // PC is byte address
    assign instr = mem[addr[11:2]];

endmodule