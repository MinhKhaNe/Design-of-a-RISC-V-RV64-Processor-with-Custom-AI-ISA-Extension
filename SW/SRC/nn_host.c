// PC check of the CNN kernels on the WHOLE test set (540 images): scalar and Xai (C emulation of dot8/qrelu/max8)
// must reproduce the Python integer reference bit for bit (int32 logits), and give the accuracy.
//   gcc -O2 -DHOST_BUILD -Isrc src/nn_host.c -o nn_host && ./nn_host nn/nn_test_images.bin nn/nn_test_labels.bin nn/nn_test_logits.bin
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "nn_kernels.h"

static unsigned char *slurp(const char *path, long *n) {
    FILE *f = fopen(path, "rb"); if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(2); }
    fseek(f, 0, SEEK_END); *n = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char *b = malloc(*n); if (fread(b, 1, *n, f) != (size_t)*n) exit(2); fclose(f); return b;
}

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: nn_host images.bin labels.bin logits.bin\n"); return 2; }
    long ni, nl, ng;
    unsigned char *im = slurp(argv[1], &ni), *lb = slurp(argv[2], &nl);
    int32_t *gold = (int32_t *)slurp(argv[3], &ng);
    long n = nl;
    if (ni != n * 64 || ng != n * 40) { fprintf(stderr, "file size mismatch\n"); return 2; }
    static nn_img_t img; static nn_buf_t bs, bx;
    long bad_s = 0, bad_x = 0, ok_s = 0, ok_x = 0;
    for (long i = 0; i < n; i++) {
        memset(&img, 0, sizeof img); memcpy(img.px, im + i * 64, 64);
        int ps = nn_run_scalar(&img, &bs), px = nn_run_xai(&img, &bx);
        bad_s += memcmp(bs.logits, gold + i * 10, 40) != 0;
        bad_x += memcmp(bx.logits, gold + i * 10, 40) != 0;
        ok_s += (ps == lb[i]); ok_x += (px == lb[i]);
    }
    printf("%ld images: scalar logits != reference on %ld, xai logits != reference on %ld\n", n, bad_s, bad_x);
    printf("accuracy: scalar %.2f%%  xai %.2f%%\n", 100.0 * ok_s / n, 100.0 * ok_x / n);
    printf("%s\n", (bad_s == 0 && bad_x == 0) ? "PASS (bit-exact)" : "FAIL");
    return (bad_s || bad_x) ? 1 : 0;
}
