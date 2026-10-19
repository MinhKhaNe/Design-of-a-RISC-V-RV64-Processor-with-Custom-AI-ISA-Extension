// Minimal bare-metal runtime for the core: cycle counters + result "mailbox".
// Compile with -DHOST_BUILD to run the same program on the host PC (correctness check only).
#ifndef RT_H
#define RT_H
#include <stdint.h>

#define DONE_MAGIC 0x600DF00DUL

// Measure a statement: dc = cycles, di = retired instructions (includes the cost of the counter
// reads themselves; calibrate by timing an empty statement and subtracting it).
#define BARRIER() __asm__ volatile ("" ::: "memory")
#define TIMED(dc, di, stmt)                                              \
    do {                                                                 \
        uint64_t _c0, _i0, _c1, _i1;                                     \
        BARRIER(); _c0 = rdcycle(); _i0 = rdinstret();                   \
        stmt;                                                            \
        BARRIER(); _c1 = rdcycle(); _i1 = rdinstret();                   \
        (dc) = _c1 - _c0; (di) = _i1 - _i0;                              \
    } while (0)

#ifdef HOST_BUILD
// ---------------- host shim: counters are dummies, mailbox is a plain array ----------------
#include <stdio.h>
#include <stdlib.h>
static uint64_t host_mbox[32];
#define MBOX host_mbox
static inline uint64_t rdcycle(void)   { static uint64_t t; return t += 3; }
static inline uint64_t rdinstret(void) { static uint64_t t; return t += 1; }
static inline void bm_finish(uint64_t code) {
    for (int i = 1; i < 32; i++) if (host_mbox[i]) printf("MBOX[%d] = %llu\n", i, (unsigned long long)host_mbox[i]);
    printf("%s (code %llu)\n", code ? "FAIL" : "PASS", (unsigned long long)code);
    exit(code ? 1 : 0);
}
#else
// ---------------- the real core ----------------
#ifndef RAM_BASE
#define RAM_BASE 0x10000UL
#endif
#ifndef RAM_SIZE
#define RAM_SIZE 0x10000UL
#endif

// The last 256 bytes of dmem are the mailbox (linker symbol _mailbox; the stack grows down from there).
//   MBOX[0] = DONE_MAGIC when the program has finished (written LAST)
//   MBOX[1] = status code (0 = pass)
//   MBOX[2..31] = results chosen by the program (cycles, instret, mismatch counts, ...)
#define MBOX_BYTES 256UL
#define MBOX       ((volatile uint64_t *)(RAM_BASE + RAM_SIZE - MBOX_BYTES))

static inline uint64_t rdcycle(void)   { uint64_t x; __asm__ volatile ("rdcycle %0"   : "=r"(x)); return x; }
static inline uint64_t rdinstret(void) { uint64_t x; __asm__ volatile ("rdinstret %0" : "=r"(x)); return x; }

static inline void bm_finish(uint64_t code) {
    MBOX[1] = code;
    BARRIER();
    MBOX[0] = DONE_MAGIC;
    for (;;) { }
}
#endif
#endif