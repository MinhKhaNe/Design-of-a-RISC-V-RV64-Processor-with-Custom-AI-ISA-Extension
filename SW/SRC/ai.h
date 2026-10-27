// Xai custom-0 instructions (dot8 / qrelu / max8) + 64-bit load / 32-bit store helpers.
//   RISC-V build : GNU as `.insn` encodings (the compiler does not need to know the instructions)
//   -DHOST_BUILD : plain C emulation of the same semantics (spec: ai_verif/ai_model.py), so the kernels can be
//                  checked for correctness on a PC.
#ifndef AI_H
#define AI_H
#include <stdint.h>

#ifdef HOST_BUILD
#include <string.h>        // memcpy, host emulation only: the bare-metal toolchain has no libc headers
// ---------------- host emulation ----------------
static inline uint64_t ai_dot8(uint64_t a, uint64_t b) {
    int64_t s = 0;
    for (int i = 0; i < 8; i++) s += (int64_t)(int8_t)(a >> (8 * i)) * (int64_t)(int8_t)(b >> (8 * i));
    return (uint64_t)s;
}
static inline uint64_t ai_qrelu_ref(unsigned sh, uint64_t a, uint64_t b) {
    uint32_t lane[4] = { (uint32_t)a, (uint32_t)(a >> 32), (uint32_t)b, (uint32_t)(b >> 32) };
    uint64_t out = 0;
    for (int l = 0; l < 4; l++) {
        int64_t v = (int32_t)lane[l];
        int64_t r = (v + (sh ? (1LL << (sh - 1)) : 0)) >> sh;      // arithmetic shift (gcc)
        if (r < 0)   r = 0;
        if (r > 127) r = 127;
        out |= (uint64_t)r << (8 * l);
    }
    return out;
}
#define AI_QRELU(SH, A, B) ai_qrelu_ref((SH), (A), (B))
static inline uint64_t ai_max8(uint64_t a, uint64_t b) {
    uint64_t out = 0;
    for (int i = 0; i < 8; i++) {
        int8_t x = (int8_t)(a >> (8 * i)), y = (int8_t)(b >> (8 * i));
        out |= (uint64_t)(uint8_t)(x > y ? x : y) << (8 * i);
    }
    return out;
}
static inline uint64_t ld64(const void *p)       { uint64_t v; memcpy(&v, p, 8); return v; }
static inline void     st32(void *p, uint32_t v) { memcpy(p, &v, 4); }
static inline void     st64(void *p, uint64_t v) { memcpy(p, &v, 8); }
#else
// ---------------- the real core ----------------
// R-type, opcode custom-0 = 0x0B:  .insn r opcode, funct3, funct7, rd, rs1, rs2
static inline uint64_t ai_dot8(uint64_t a, uint64_t b) {
    uint64_t r;
    __asm__ (".insn r 0x0B, 0, 0, %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
    return r;
}
static inline uint64_t ai_max8(uint64_t a, uint64_t b) {
    uint64_t r;
    __asm__ (".insn r 0x0B, 2, 0, %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
    return r;
}
// the shift amount is encoded in funct7[4:0]: SH must be a compile-time constant (0..31)
#define AI_QRELU(SH, A, B) ({ uint64_t _r; \
    __asm__ (".insn r 0x0B, 1, %3, %0, %1, %2" : "=r"(_r) : "r"(A), "r"(B), "i"(SH)); _r; })

// Explicit `ld` / `sw` / `sd` so the compiler cannot split them into byte accesses (the core's dmem accepts
// misaligned addresses; bench_ai.c / nn_kernels.h rely on that for the conv / max-pool windows).
// The address is passed as a MEMORY operand ("m"), not as "0(reg)": the compiler can then fold a constant offset into
// the instruction (`ld a5,8(a4)`) instead of emitting a separate `addi` per load, and, because the load is not
// `volatile`, it is free to schedule it early (no load-use stall).  may_alias + aligned(1): the access is treated as
// touching any object (no strict-aliasing reordering against ordinary int8/int32 accesses) and no alignment is assumed.
typedef uint64_t __attribute__((may_alias, aligned(1))) ai_u64a;
typedef uint32_t __attribute__((may_alias, aligned(1))) ai_u32a;

static inline uint64_t ld64(const void *p) {
    uint64_t v;
    __asm__ ("ld %0, %1" : "=r"(v) : "m"(*(const ai_u64a *)p));
    return v;
}
static inline void st32(void *p, uint32_t v) {
    __asm__ volatile ("sw %1, %0" : "=m"(*(ai_u32a *)p) : "r"(v));
}
static inline void st64(void *p, uint64_t v) {
    __asm__ volatile ("sd %1, %0" : "=m"(*(ai_u64a *)p) : "r"(v));
}
#endif
#endif