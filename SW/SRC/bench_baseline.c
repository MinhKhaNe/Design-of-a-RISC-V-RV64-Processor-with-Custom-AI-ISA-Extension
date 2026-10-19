// Baseline (scalar RV64IM) AI kernels: dot, GEMM, 3x3 conv, requantise+ReLU, 2x2 max-pool.
// Every kernel is checked against NumPy golden data (bench_data.h) and timed with the
// cycle / instret CSRs.
//
// Mailbox layout (uint64 slots):
//   [2],[3]   dot      cycles, instret        [12] dot      mismatches
//   [4],[5]   gemm     cycles, instret        [13] gemm     mismatches
//   [6],[7]   conv3x3  cycles, instret        [14] conv3x3  mismatches
//   [8],[9]   requant  cycles, instret        [15] requant  mismatches
//   [10],[11] maxpool  cycles, instret        [16] maxpool  mismatches
//   [17],[18] measurement overhead (cycles, instret) -- already subtracted from the above
#include "rt.h"
#include "bench_data.h"

// Hide the input values from the optimiser so the kernels cannot be folded at compile time.
static inline const void *launder(const void *p) { __asm__ volatile ("" : "+r"(p)); return p; }

__attribute__((noinline))
static int32_t dot_i8(const int8_t *a, const int8_t *b, int n) {
    int32_t s = 0;
    for (int i = 0; i < n; i++) s += (int32_t)a[i] * b[i];
    return s;
}

__attribute__((noinline))
static void gemm_i8(const int8_t *A, const int8_t *B, int32_t *C, int m, int k, int n) {
    for (int i = 0; i < m; i++)
        for (int j = 0; j < n; j++) {
            int32_t s = 0;
            for (int x = 0; x < k; x++) s += (int32_t)A[i * k + x] * B[x * n + j];
            C[i * n + j] = s;
        }
}

__attribute__((noinline))
static void conv3x3_i8(const int8_t *img, int iw, const int8_t *w, int32_t *out, int oh, int ow) {
    for (int y = 0; y < oh; y++)
        for (int x = 0; x < ow; x++) {
            int32_t s = 0;
            for (int ky = 0; ky < 3; ky++)
                for (int kx = 0; kx < 3; kx++)
                    s += (int32_t)img[(y + ky) * iw + x + kx] * w[ky * 3 + kx];
            out[y * ow + x] = s;
        }
}

__attribute__((noinline))
static void requant_relu(const int32_t *in, int8_t *out, int n, int shift) {
    for (int i = 0; i < n; i++) {
        int32_t r = (in[i] + (1 << (shift - 1))) >> shift;
        if (r < 0)   r = 0;
        if (r > 127) r = 127;
        out[i] = (int8_t)r;
    }
}

__attribute__((noinline))
static void maxpool2x2(const int8_t *in, int iw, int8_t *out, int oh, int ow) {
    for (int y = 0; y < oh; y++)
        for (int x = 0; x < ow; x++) {
            const int8_t *p = in + (2 * y) * iw + 2 * x;
            int8_t m = p[0];
            if (p[1]      > m) m = p[1];
            if (p[iw]     > m) m = p[iw];
            if (p[iw + 1] > m) m = p[iw + 1];
            out[y * ow + x] = m;
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

    TIMED(ovh_c, ovh_i, (void)0);                                           // calibration: empty region
    MBOX[17] = ovh_c; MBOX[18] = ovh_i;

    TIMED(c, i, dot_r = dot_i8((const int8_t *)launder(dot_a), (const int8_t *)launder(dot_b), DOT_N));
    MBOX[2] = c - ovh_c; MBOX[3] = i - ovh_i;
    e = (dot_r != dot_exp); MBOX[12] = e; err += e;

    TIMED(c, i, gemm_i8((const int8_t *)launder(gemm_a), (const int8_t *)launder(gemm_b), gemm_out, GEMM_M, GEMM_K, GEMM_N));
    MBOX[4] = c - ovh_c; MBOX[5] = i - ovh_i;
    e = diff_i32(gemm_out, gemm_exp, GEMM_M * GEMM_N); MBOX[13] = e; err += e;

    TIMED(c, i, conv3x3_i8((const int8_t *)launder(conv_img), IMG_W, (const int8_t *)launder(conv_w), conv_out, CONV_OH, CONV_OW));
    MBOX[6] = c - ovh_c; MBOX[7] = i - ovh_i;
    e = diff_i32(conv_out, conv_exp, CONV_OH * CONV_OW); MBOX[14] = e; err += e;

    TIMED(c, i, requant_relu(conv_out, req_out, CONV_OH * CONV_OW, REQ_SHIFT));
    MBOX[8] = c - ovh_c; MBOX[9] = i - ovh_i;
    e = diff_i8(req_out, req_exp, CONV_OH * CONV_OW); MBOX[15] = e; err += e;

    TIMED(c, i, maxpool2x2(req_out, CONV_OW, pool_out, POOL_H, POOL_W));
    MBOX[10] = c - ovh_c; MBOX[11] = i - ovh_i;
    e = diff_i8(pool_out, pool_exp, POOL_H * POOL_W); MBOX[16] = e; err += e;

    bm_finish(err != 0);
}