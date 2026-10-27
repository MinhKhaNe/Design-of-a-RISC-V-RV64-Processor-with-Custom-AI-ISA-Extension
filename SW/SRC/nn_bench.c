// CNN inference on the core: scalar vs Xai, per layer and per image, plus bit-exact checking against the Python reference
// (first NN_NIMG test images embedded in nn_data.h).  Same mailbox conventions as the other benchmarks.
//
// Mailbox (uint64 slots):
//   [2..7]   scalar cycles per layer (image 0): conv1, requant1, conv2, requant2, pool, fc
//   [8..13]  Xai    cycles per layer (image 0): same order
//   [14],[15] scalar whole inference (image 0, incl. argmax): cycles, instret
//   [16],[17] Xai    whole inference: cycles, instret
//   [18] scalar logit mismatches vs reference over all NN_NIMG images     [19] same for Xai
//   [20] images classified correctly by Xai                               [21] NN_NIMG
//   [22],[23] measurement overhead (cycles, instret), already subtracted from the figures above
#include "rt.h"
#include "nn_kernels.h"
#include "nn_data.h"

static nn_img_t img NN_A8;
static nn_buf_t bs, bx;

static void load_image(int i) {
    for (int k = 0; k < 64; k++) img.px[k] = nn_img[i * 64 + k];
    for (int k = 64; k < 72; k++) img.px[k] = 0;
}

int main(void) {
    uint64_t ovh_c, ovh_i, c, i, err = 0;
    TIMED(ovh_c, ovh_i, (void)0);
    MBOX[22] = ovh_c; MBOX[23] = ovh_i;

    load_image(0);
    const uint8_t *im = (const uint8_t *)nn_launder(img.px);

    // ---- per layer, scalar ----
    TIMED(c, i, nn_s_conv1(im, bs.acc1));                                  MBOX[2] = c - ovh_c;
    TIMED(c, i, nn_s_requant(bs.acc1, bs.act1, 6 * 6 * 8, NN_SH1));        MBOX[3] = c - ovh_c;
    TIMED(c, i, nn_s_conv2(bs.act1, bs.acc2));                             MBOX[4] = c - ovh_c;
    TIMED(c, i, nn_s_requant(bs.acc2, bs.act2, 4 * 4 * 16, NN_SH2));       MBOX[5] = c - ovh_c;
    TIMED(c, i, nn_s_pool(bs.act2, bs.pool));                              MBOX[6] = c - ovh_c;
    TIMED(c, i, nn_s_fc(bs.pool, bs.logits));                              MBOX[7] = c - ovh_c;
    // ---- per layer, Xai ----
    TIMED(c, i, nn_x_conv1(im, bx.acc1));                                  MBOX[8] = c - ovh_c;
    TIMED(c, i, nn_x_requant1(bx.acc1, bx.act1));                          MBOX[9] = c - ovh_c;
    TIMED(c, i, nn_x_conv2(bx.act1, bx.acc2));                             MBOX[10] = c - ovh_c;
    TIMED(c, i, nn_x_requant2(bx.acc2, bx.act2));                          MBOX[11] = c - ovh_c;
    TIMED(c, i, nn_x_pool(bx.act2, bx.pool));                              MBOX[12] = c - ovh_c;
    TIMED(c, i, nn_x_fc(bx.pool, bx.logits));                              MBOX[13] = c - ovh_c;

    // ---- whole inference, image 0 ----
    int ps, px;
    TIMED(c, i, ps = nn_run_scalar((const nn_img_t *)nn_launder(&img), &bs));  MBOX[14] = c - ovh_c; MBOX[15] = i - ovh_i;
    TIMED(c, i, px = nn_run_xai((const nn_img_t *)nn_launder(&img), &bx));     MBOX[16] = c - ovh_c; MBOX[17] = i - ovh_i;
    (void)ps; (void)px;

    // ---- correctness over all embedded images (not timed) ----
    uint64_t bad_s = 0, bad_x = 0, ok_x = 0;
    for (int n = 0; n < NN_NIMG; n++) {
        load_image(n);
        int pS = nn_run_scalar(&img, &bs), pX = nn_run_xai(&img, &bx);
        for (int k = 0; k < 10; k++) { bad_s += (bs.logits[k] != nn_expect[n * 10 + k]); bad_x += (bx.logits[k] != nn_expect[n * 10 + k]); }
        ok_x += (pX == nn_label[n]);
        (void)pS;
    }
    MBOX[18] = bad_s; MBOX[19] = bad_x; MBOX[20] = ok_x; MBOX[21] = NN_NIMG;
    err = bad_s + bad_x;
    bm_finish(err != 0);
}
