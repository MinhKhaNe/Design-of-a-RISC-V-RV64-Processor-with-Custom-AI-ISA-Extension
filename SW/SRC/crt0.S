# Bare-metal start-up for the rv64imafc core.
#   - code lives in imem (address 0), data/stack/mailbox live in dmem (RAM_BASE..)
#   - dmem is zeroed by the simulator, but .bss is cleared here too so the program
#     does not depend on that.
    .section .text.init, "ax"
    .globl _start
    .globl _trap
_start:
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop
    la      sp, _stack_top

    la      a0, __bss_start
    la      a1, __bss_end
1:  bgeu    a0, a1, 2f
    sd      zero, 0(a0)
    addi    a0, a0, 8
    j       1b
2:
    call    main
3:  j       3b                     # main returned: park

# Redirect target for illegal instructions (TRAP_PC): park here.
_trap:
4:  j       4b
