// CNN inference kernels, scalar and Xai versions, on the SAME data layout (HWC: channels fastest):
//   image 8x8 (uint8, 0..127, stride 8) -> conv3x3 1->8 (6x6x8) -> requant -> conv3x3 8->16 (4x4x16) -> requant
//   -> maxpool2x2 (2x2x16) -> FC 64->10 -> int32 logits.      Weights / shifts: nn_weights.h (nn/train_quant.py).
// Requantisation = (acc + 2^(s-1)) >> s, ReLU, clamp to 127  (exactly the Xai qrelu).
// Alignment assumptions (all satisfied by nn_buf_t / the image buffer below): activation maps and weights are 8-byte
// aligned; conv1 reads 64 bits at byte offsets that are not multiples of 8 (this core's dmem accepts that).
#ifndef NN_KERNELS_H
#define NN_KERNELS_H
#include <stdint.h>
#include "ai.h"
#include "nn_weights.h"

#define NN_A8 __attribute__((aligned(8)))

typedef struct {
    int32_t acc1[6 * 6 * 8]   NN_A8;
    int8_t  act1[6 * 6 * 8]   NN_A8;
    int32_t acc2[4 * 4 * 16]  NN_A8;
    int8_t  act2[4 * 4 * 16]  NN_A8;
    int8_t  pool[64]          NN_A8;
    int32_t logits[10]        NN_A8;
} nn_buf_t;

// the image buffer must hold 8 extra bytes: the Xai conv1 loads 64 bits at the last window
typedef struct { uint8_t px[64 + 8] NN_A8; } nn_img_t;

// Ordered, sign-extending byte load for the scalar kernels (`lb` as a volatile asm with a memory operand, like ld64 for Xai).
// volatile asm statements keep their program order, so the compiler's scheduler cannot hoist every load of a long unrolled
// block to the top (which exhausts the registers and spills dozens of values to the stack); each value is loaded just
// before it is used.  The multiply/add arithmetic stays plain C.  Activations and the image are 0..127, so sign extension
// is exact.
#ifdef HOST_BUILD
static inline int32_t nn_ld8(const void *p) { return *(const int8_t *)p; }
#else
typedef int8_t __attribute__((may_alias)) nn_i8a;
static inline int32_t nn_ld8(const void *p) {
    int32_t v;
    __asm__ volatile ("lb %0, %1" : "=r"(v) : "m"(*(const nn_i8a *)p));
    return v;
}
#endif

static inline int32_t nn_max32(int32_t a, int32_t b) { int32_t d = a - b; return a - (d & (d >> 31)); }
static inline int32_t nn_min32(int32_t a, int32_t b) { int32_t d = a - b; return b + (d & (d >> 31)); }
static inline const void *nn_launder(const void *p)  { __asm__ volatile ("" : "+r"(p)); return p; }

// ======================================================================= scalar (plain RV64IM, branch-free, unrolled)
// Scalar kernels, tuned with the same effort as the Xai ones: the loaded input values are shared by several output channels
// (register blocking), every load goes through nn_ld8 (ordered, no hoisting/spilling), outputs through st32 (a real `sw`),
// clamps are branch-free.  The multiply is `mulw` (int32 arithmetic), exactly what the C promotes to; its latency is a
// property of the core, not of the code.
__attribute__((noinline))
static void nn_s_conv1(const uint8_t *img, int32_t *acc) {
    for (int y = 0; y < 6; y++)
        for (int x = 0; x < 6; x++) {
            const uint8_t *p = img + y * 8 + x;
            // the 9 pixels of the window are loaded once and reused by all 8 filters
            const int32_t i0 = nn_ld8(p),      i1 = nn_ld8(p + 1),  i2 = nn_ld8(p + 2);
            const int32_t i3 = nn_ld8(p + 8),  i4 = nn_ld8(p + 9),  i5 = nn_ld8(p + 10);
            const int32_t i6 = nn_ld8(p + 16), i7 = nn_ld8(p + 17), i8 = nn_ld8(p + 18);
            int32_t *o = acc + (y * 6 + x) * 8;
#pragma GCC unroll 8
            for (int oc = 0; oc < 8; oc++) {
                const int8_t *w = nn_w1 + oc * 9;
                int32_t s = nn_b1[oc];
                const int32_t v0 = nn_ld8(w), v1 = nn_ld8(w + 1), v2 = nn_ld8(w + 2);       // 3 loads, then 3 multiplies
                s += i0 * v0; s += i1 * v1; s += i2 * v2;
                const int32_t v3 = nn_ld8(w + 3), v4 = nn_ld8(w + 4), v5 = nn_ld8(w + 5);
                s += i3 * v3; s += i4 * v4; s += i5 * v5;
                const int32_t v6 = nn_ld8(w + 6), v7 = nn_ld8(w + 7), v8 = nn_ld8(w + 8);
                s += i6 * v6; s += i7 * v7; s += i8 * v8;
                st32(o + oc, (uint32_t)s);
            }
        }
}

__attribute__((noinline))
static void nn_s_requant(const int32_t *acc, int8_t *out, int n, int sh) {
    const int32_t rnd = sh ? (1 << (sh - 1)) : 0;
    for (int i = 0; i < n; i += 4) {
#pragma GCC unroll 4
        for (int l = 0; l < 4; l++) out[i + l] = (int8_t)nn_min32(nn_max32((acc[i + l] + rnd) >> sh, 0), 127);
    }
}

__attribute__((noinline))
static void nn_s_conv2(const int8_t *in, int32_t *acc) {                     // in: 6x6x8
    for (int y = 0; y < 4; y++)
        for (int x = 0; x < 4; x++) {
            const int8_t *px = in + (y * 6 + x) * 8;
            int32_t *o = acc + (y * 4 + x) * 16;
            for (int oc = 0; oc < 16; oc += 4) {                              // 4 output channels share every loaded input byte
                const int8_t *w = nn_w2 + oc * 72;                            // filters oc..oc+3 at +0, +72, +144, +216
                const int8_t *q = px;
                int32_t s0 = nn_b2[oc], s1 = nn_b2[oc + 1], s2 = nn_b2[oc + 2], s3 = nn_b2[oc + 3];
                for (int ky = 0; ky < 3; ky++, q += 48, w += 24) {            // kernel row: input +48 bytes, weights +24 bytes
#pragma GCC unroll 3
                    for (int kx = 0; kx < 3; kx++) {
#pragma GCC unroll 8
                        for (int c = 0; c < 8; c++) {
                            const int32_t a = nn_ld8(q + kx * 8 + c);
                            const int8_t *wp = w + kx * 8 + c;
                            // all four weights are loaded before the first multiply: no load-use stall (loads keep program order)
                            const int32_t w0 = nn_ld8(wp), w1 = nn_ld8(wp + 72), w2 = nn_ld8(wp + 144), w3 = nn_ld8(wp + 216);
                            s0 += a * w0; s1 += a * w1; s2 += a * w2; s3 += a * w3;
                        }
                    }
                }
                st32(o + oc, (uint32_t)s0); st32(o + oc + 1, (uint32_t)s1); st32(o + oc + 2, (uint32_t)s2); st32(o + oc + 3, (uint32_t)s3);
            }
        }
}

__attribute__((noinline))
static void nn_s_pool(const int8_t *in, int8_t *out) {                       // 4x4x16 -> 2x2x16
    for (int py = 0; py < 2; py++)
        for (int px = 0; px < 2; px++) {
            const int8_t *b = in + ((2 * py) * 4 + 2 * px) * 16;
#pragma GCC unroll 16
            for (int c = 0; c < 16; c++)
                out[(py * 2 + px) * 16 + c] = (int8_t)nn_max32(nn_max32(b[c], b[16 + c]), nn_max32(b[64 + c], b[80 + c]));
        }
}

__attribute__((noinline))
static void nn_s_fc(const int8_t *f, int32_t *logits) {
    for (int k = 0; k < 10; k += 5) {                                         // 5 classes share every loaded feature
        const int8_t *w = nn_wf + k * 64;
        int32_t s0 = nn_bf[k], s1 = nn_bf[k + 1], s2 = nn_bf[k + 2], s3 = nn_bf[k + 3], s4 = nn_bf[k + 4];
        for (int jb = 0; jb < 64; jb += 16) {
#pragma GCC unroll 16
            for (int j = jb; j < jb + 16; j++) {
                const int32_t a = nn_ld8(f + j);
                const int32_t w0 = nn_ld8(w + j), w1 = nn_ld8(w + 64 + j), w2 = nn_ld8(w + 128 + j);
                const int32_t w3 = nn_ld8(w + 192 + j), w4 = nn_ld8(w + 256 + j);
                s0 += a * w0; s1 += a * w1; s2 += a * w2; s3 += a * w3; s4 += a * w4;
            }
        }
        st32(logits + k, (uint32_t)s0); st32(logits + k + 1, (uint32_t)s1); st32(logits + k + 2, (uint32_t)s2);
        st32(logits + k + 3, (uint32_t)s3); st32(logits + k + 4, (uint32_t)s4);
    }
}

// ======================================================================= Xai (dot8 / qrelu / max8)
__attribute__((noinline))
static void nn_x_conv1(const uint8_t *img, int32_t *acc) {
    // Group-outer loop: the 12 weight words of 4 filters are loaded once and stay in registers for all 36 pixels (the image
    // rows are re-read once per group).  Per pixel and group: 3 ld, 12 dot8 (4 independent chains), 8 add, 4 sw.
    // Outputs go through st32 (a real `sw`): the compiler cannot merge them into 64-bit stores with extra shift/mask code.
#pragma GCC unroll 2
    for (int g = 0; g < 8; g += 4) {
        const uint8_t *w = (const uint8_t *)nn_w1p + g * 24;          // filter f of the group at +24*f, row ky at +8*ky
        const uint64_t w00 = ld64(w),      w01 = ld64(w + 8),  w02 = ld64(w + 16);
        const uint64_t w10 = ld64(w + 24), w11 = ld64(w + 32), w12 = ld64(w + 40);
        const uint64_t w20 = ld64(w + 48), w21 = ld64(w + 56), w22 = ld64(w + 64);
        const uint64_t w30 = ld64(w + 72), w31 = ld64(w + 80), w32 = ld64(w + 88);
        for (int y = 0; y < 6; y++)
            for (int x = 0; x < 6; x++) {
                const uint8_t *p = img + y * 8 + x;
                const uint64_t r0 = ld64(p), r1 = ld64(p + 8), r2 = ld64(p + 16);
                int32_t *o = acc + (y * 6 + x) * 8 + g;
                const uint64_t s0 = ai_dot8(r0, w00) + ai_dot8(r1, w01) + ai_dot8(r2, w02);
                const uint64_t s1 = ai_dot8(r0, w10) + ai_dot8(r1, w11) + ai_dot8(r2, w12);
                const uint64_t s2 = ai_dot8(r0, w20) + ai_dot8(r1, w21) + ai_dot8(r2, w22);
                const uint64_t s3 = ai_dot8(r0, w30) + ai_dot8(r1, w31) + ai_dot8(r2, w32);
                st32(o,     (uint32_t)(nn_b1[g]     + (int32_t)s0));
                st32(o + 1, (uint32_t)(nn_b1[g + 1] + (int32_t)s1));
                st32(o + 2, (uint32_t)(nn_b1[g + 2] + (int32_t)s2));
                st32(o + 3, (uint32_t)(nn_b1[g + 3] + (int32_t)s3));
            }
    }
}

// qrelu needs a compile-time shift, hence a macro and one wrapper per layer
#define NN_X_REQUANT(ACC, OUT, N, SH)                                                          \
    do { for (int _k = 0; _k < (N); _k += 8) {                       /* N is a multiple of 8 */   \
             uint64_t _a0 = ld64((ACC) + _k),     _b0 = ld64((ACC) + _k + 2);                   \
             uint64_t _a1 = ld64((ACC) + _k + 4), _b1 = ld64((ACC) + _k + 6);                   \
             st32((OUT) + _k,     (uint32_t)AI_QRELU(SH, _a0, _b0));                             \
             st32((OUT) + _k + 4, (uint32_t)AI_QRELU(SH, _a1, _b1)); } } while (0)

__attribute__((noinline)) static void nn_x_requant1(const int32_t *acc, int8_t *out) { NN_X_REQUANT(acc, out, 6 * 6 * 8, NN_SH1); }
__attribute__((noinline)) static void nn_x_requant2(const int32_t *acc, int8_t *out) { NN_X_REQUANT(acc, out, 4 * 4 * 16, NN_SH2); }

__attribute__((noinline))
static void nn_x_conv2(const int8_t *in, int32_t *acc) {                     // in: 6x6x8, one 64-bit word per pixel
    for (int y = 0; y < 4; y++)
        for (int x = 0; x < 4; x++) {
            uint64_t v[9];
#pragma GCC unroll 9
            for (int t = 0; t < 9; t++) v[t] = ld64(in + ((y + t / 3) * 6 + (x + t % 3)) * 8);
            // Two output channels per iteration: their dot8 chains are independent, so with the order
            //   ld xa; ld xb; dot8(v,xa); dot8(v,xb); add; add
            // every loaded word is consumed at least one instruction later (no load-use stall), and the loop
            // runs half as often (fewer taken-branch flushes).  Filter oc+1 starts 72 bytes after filter oc.
            for (int oc = 0; oc < 16; oc += 2) {
                const uint8_t *wa = (const uint8_t *)nn_w2 + oc * 72;
                uint64_t sa = 0, sb = 0;
#pragma GCC unroll 9
                for (int t = 0; t < 9; t++) {
                    uint64_t xa = ld64(wa + t * 8), xb = ld64(wa + 72 + t * 8);
                    sa += ai_dot8(v[t], xa);
                    sb += ai_dot8(v[t], xb);
                }
                st32(acc + (y * 4 + x) * 16 + oc,     (uint32_t)(nn_b2[oc]     + (int32_t)sa));      // st32: not mergeable into sd
                st32(acc + (y * 4 + x) * 16 + oc + 1, (uint32_t)(nn_b2[oc + 1] + (int32_t)sb));
            }
        }
}

__attribute__((noinline))
static void nn_x_pool(const int8_t *in, int8_t *out) {
    for (int py = 0; py < 2; py++)
        for (int px = 0; px < 2; px++)
            for (int g = 0; g < 2; g++) {                                     // 16 channels = 2 words
                const int8_t *b = in + ((2 * py) * 4 + 2 * px) * 16 + g * 8;
                uint64_t m = ai_max8(ai_max8(ld64(b), ld64(b + 16)), ai_max8(ld64(b + 64), ld64(b + 80)));
                st64(out + (py * 2 + px) * 16 + g * 8, m);
            }
}

__attribute__((noinline))
static void nn_x_fc(const int8_t *f, int32_t *logits) {
    uint64_t v[8];
#pragma GCC unroll 8
    for (int j = 0; j < 8; j++) v[j] = ld64(f + j * 8);
    for (int k = 0; k < 10; k += 2) {                                          // two classes per iteration (see conv2)
        const uint8_t *wa = (const uint8_t *)nn_wf + k * 64;
        uint64_t sa = 0, sb = 0;
#pragma GCC unroll 8
        for (int j = 0; j < 8; j++) {
            uint64_t xa = ld64(wa + j * 8), xb = ld64(wa + 64 + j * 8);
            sa += ai_dot8(v[j], xa);
            sb += ai_dot8(v[j], xb);
        }
        st32(logits + k,     (uint32_t)(nn_bf[k]     + (int32_t)sa));
        st32(logits + k + 1, (uint32_t)(nn_bf[k + 1] + (int32_t)sb));
    }
}

// ======================================================================= whole network
static inline int nn_argmax(const int32_t *l) {
    int best = 0;
    for (int k = 1; k < 10; k++) if (l[k] > l[best]) best = k;
    return best;
}
static inline int nn_run_scalar(const nn_img_t *img, nn_buf_t *b) {
    nn_s_conv1(img->px, b->acc1);   nn_s_requant(b->acc1, b->act1, 6 * 6 * 8, NN_SH1);
    nn_s_conv2(b->act1, b->acc2);   nn_s_requant(b->acc2, b->act2, 4 * 4 * 16, NN_SH2);
    nn_s_pool(b->act2, b->pool);    nn_s_fc(b->pool, b->logits);
    return nn_argmax(b->logits);
}
static inline int nn_run_xai(const nn_img_t *img, nn_buf_t *b) {
    nn_x_conv1(img->px, b->acc1);   nn_x_requant1(b->acc1, b->act1);
    nn_x_conv2(b->act1, b->acc2);   nn_x_requant2(b->acc2, b->act2);
    nn_x_pool(b->act2, b->pool);    nn_x_fc(b->pool, b->logits);
    return nn_argmax(b->logits);
}
#endif