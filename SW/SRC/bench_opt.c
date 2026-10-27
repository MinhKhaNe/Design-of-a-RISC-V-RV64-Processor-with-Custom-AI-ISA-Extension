// "Strong scalar" baseline: the same five kernels as bench_baseline.c, but hand-optimised for THIS core, using only
// RV64IM instructions (no Xai).  It is the fair opponent for the Xai speedup numbers.
//   * loops are unrolled (fewer taken branches: each costs 2 flush cycles on this core)
//   * min / max / clamp are branch-free (a data-dependent taken branch costs 2 cycles)
//   * B is read transposed (gemm_bt) so a GEMM inner product walks two contiguous byte rows with constant offsets
//   * 3x3 weights live in registers; window offsets are constants
// It cannot remove the multiplier latency (mul_div_unit holds the pipeline ~5 cycles per mul): that is exactly what dot8 removes.
// Same mailbox layout as bench_baseline.c / bench_ai.c.
#include "rt.h"
#include "bench_data.h"

static inline const void *launder(const void *p) { __asm__ volatile ("" : "+r"(p)); return p; }

// branch-free (values here are far from the int32 limits)
static inline int32_t max32(int32_t a, int32_t b) { int32_t d = a - b; return a - (d & (d >> 31)); }
static inline int32_t min32(int32_t a, int32_t b) { int32_t d = a - b; return b + (d & (d >> 31)); }

__attribute__((noinline))
static int32_t dot_opt(const int8_t *a, const int8_t *b, int n) {
    int32_t s = 0;
    for (int i = 0; i < n; i += 8)
        s += (int32_t)a[i]   * b[i]   + (int32_t)a[i+1] * b[i+1] + (int32_t)a[i+2] * b[i+2] + (int32_t)a[i+3] * b[i+3]
           + (int32_t)a[i+4] * b[i+4] + (int32_t)a[i+5] * b[i+5] + (int32_t)a[i+6] * b[i+6] + (int32_t)a[i+7] * b[i+7];
    return s;
}

__attribute__((noinline))
static void gemm_opt(const int8_t *A, const int8_t *BT, int32_t *C, int m, int n) {   // K = 16
    for (int i = 0; i < m; i++) {
        const int8_t *ar = A + 16 * i;
        for (int j = 0; j < n; j++) {
            const int8_t *br = BT + 16 * j;
            int32_t s = 0;
#pragma GCC unroll 16
            for (int k = 0; k < 16; k++) s += (int32_t)ar[k] * br[k];
            C[i * n + j] = s;
        }
    }
}

__attribute__((noinline))
static void conv3x3_opt(const int8_t *img, int iw, const int8_t *w, int32_t *out, int oh, int ow) {
    const int32_t w00 = w[0], w01 = w[1], w02 = w[2], w10 = w[3], w11 = w[4], w12 = w[5], w20 = w[6], w21 = w[7], w22 = w[8];
    for (int y = 0; y < oh; y++) {
        const int8_t *p = img + y * iw;
        for (int x = 0; x < ow; x++, p++) {
            out[y * ow + x] = p[0]        * w00 + p[1]        * w01 + p[2]        * w02
                            + p[iw]       * w10 + p[iw + 1]   * w11 + p[iw + 2]   * w12
                            + p[2 * iw]   * w20 + p[2 * iw+1] * w21 + p[2 * iw+2] * w22;
        }
    }
}

__attribute__((noinline))
static void requant_relu_opt(const int32_t *in, int8_t *out, int n, int shift) {
    const int32_t rnd = 1 << (shift - 1);
    for (int i = 0; i < n; i += 4) {
#pragma GCC unroll 4
        for (int l = 0; l < 4; l++) {
            int32_t r = (in[i + l] + rnd) >> shift;
            out[i + l] = (int8_t)min32(max32(r, 0), 127);
        }
    }
}

__attribute__((noinline))
static void maxpool2x2_opt(const int8_t *in, int iw, int8_t *out, int oh, int ow) {
    for (int y = 0; y < oh; y++) {
        const int8_t *p = in + (2 * y) * iw;
#pragma GCC unroll 7
        for (int x = 0; x < 7; x++) {                         // ow == 7
            int32_t m = max32(max32(p[2 * x], p[2 * x + 1]), max32(p[iw + 2 * x], p[iw + 2 * x + 1]));
            out[y * ow + x] = (int8_t)m;
        }
    }
}

static int32_t gemm_out[GEMM_M * GEMM_N];
static int32_t conv_out[CONV_OH * CONV_OW];
static int8_t  req_out[CONV_OH * CONV_OW];
static int8_t  pool_out[POOL_H * POOL_W];

static uint64_t diff_i32(const int32_t *a, const int32_t *b, int n) { uint64_t e = 0; for (int i = 0; i < n; i++) e += (a[i] != b[i]); return e; }
static uint64_t diff_i8 (const int8_t  *a, const int8_t  *b, int n) { uint64_t e = 0; for (int i = 0; i < n; i++) e += (a[i] != b[i]); return e; }

int main(void) {
    uint64_t ovh_c, ovh_i, c, i, err = 0, e;
    int32_t  dot_r = 0;

    TIMED(ovh_c, ovh_i, (void)0);
    MBOX[17] = ovh_c; MBOX[18] = ovh_i;

    TIMED(c, i, dot_r = dot_opt((const int8_t *)launder(dot_a), (const int8_t *)launder(dot_b), DOT_N));
    MBOX[2] = c - ovh_c; MBOX[3] = i - ovh_i;
    e = (dot_r != dot_exp); MBOX[12] = e; err += e;

    TIMED(c, i, gemm_opt((const int8_t *)launder(gemm_a), (const int8_t *)launder(gemm_bt), gemm_out, GEMM_M, GEMM_N));
    MBOX[4] = c - ovh_c; MBOX[5] = i - ovh_i;
    e = diff_i32(gemm_out, gemm_exp, GEMM_M * GEMM_N); MBOX[13] = e; err += e;

    TIMED(c, i, conv3x3_opt((const int8_t *)launder(conv_img), IMG_W, (const int8_t *)launder(conv_w), conv_out, CONV_OH, CONV_OW));
    MBOX[6] = c - ovh_c; MBOX[7] = i - ovh_i;
    e = diff_i32(conv_out, conv_exp, CONV_OH * CONV_OW); MBOX[14] = e; err += e;

    TIMED(c, i, requant_relu_opt(conv_out, req_out, CONV_OH * CONV_OW, REQ_SHIFT));
    MBOX[8] = c - ovh_c; MBOX[9] = i - ovh_i;
    e = diff_i8(req_out, req_exp, CONV_OH * CONV_OW); MBOX[15] = e; err += e;

    TIMED(c, i, maxpool2x2_opt(req_out, CONV_OW, pool_out, POOL_H, POOL_W));
    MBOX[10] = c - ovh_c; MBOX[11] = i - ovh_i;
    e = diff_i8(pool_out, pool_exp, POOL_H * POOL_W); MBOX[16] = e; err += e;

    bm_finish(err != 0);
}