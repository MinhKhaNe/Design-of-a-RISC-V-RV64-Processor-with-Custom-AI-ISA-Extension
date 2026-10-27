// Smoke test: exercises .rodata (dmem.hex), .bss, the stack, mul/div, loops and the counters.
#include "rt.h"

static const int32_t tbl[8] = {3, 1, 4, 1, 5, 9, 2, 6};   // .rodata -> loaded into dmem
static int32_t buf[16];                                    // .bss    -> must read as zero first

__attribute__((noinline)) static uint64_t work(uint64_t *bss_was_zero) {
    uint64_t z = 0;
    for (int i = 0; i < 16; i++) z |= (uint64_t)buf[i];     // all zero before we write
    *bss_was_zero = (z == 0);

    uint64_t sum = 0;
    for (int i = 1; i <= 100; i++) sum += (uint64_t)i;           // 5050
    for (int i = 0; i < 16; i++) buf[i] = i * i;
    uint64_t sq = 0;
    for (int i = 0; i < 16; i++) sq += (uint64_t)buf[i];         // 1240
    uint64_t t = 0;
    for (int i = 0; i < 8; i++) t += (uint64_t)tbl[i];           // 31
    volatile uint64_t x = 123456789ULL * 37ULL;
    uint64_t m = x % 1000003ULL;                                  // 887492
    uint64_t d = x / 1000003ULL;                                  // 4567
    return sum + (sq << 16) + (t << 32) + (m << 40) + d;
}

int main(void) {
    uint64_t zero_ok;
    BARRIER();
    uint64_t c0 = rdcycle(), i0 = rdinstret();
    uint64_t r  = work(&zero_ok);
    uint64_t c1 = rdcycle(), i1 = rdinstret();
    BARRIER();

    const uint64_t expect = 5050ULL + (1240ULL << 16) + (31ULL << 32) + (887492ULL << 40) + 4567ULL;
    MBOX[2] = c1 - c0;      // cycles
    MBOX[3] = i1 - i0;      // retired instructions
    MBOX[4] = r;
    MBOX[5] = expect;
    MBOX[6] = zero_ok;
    bm_finish((r == expect && zero_ok) ? 0 : 1);
}