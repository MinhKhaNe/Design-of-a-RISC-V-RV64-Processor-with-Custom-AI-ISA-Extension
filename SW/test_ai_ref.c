// Host check that the C emulation in ai.h matches the Python golden model (ai_vectors.txt from gen_ai_vectors.py).
//   gcc -O2 -DHOST_BUILD -Isrc test_ai_ref.c -o /tmp/test_ai_ref && /tmp/test_ai_ref ai_vectors.txt
#include <stdio.h>
#include <stdlib.h>
#include "ai.h"

int main(int argc, char **argv) {
    FILE *f = fopen(argc > 1 ? argv[1] : "ai_vectors.txt", "r");
    if (!f) { puts("cannot open vectors"); return 2; }
    unsigned op, sh; unsigned long long a, b, e; long n = 0, bad = 0;
    while (fscanf(f, "%x %x %llx %llx %llx", &op, &sh, &a, &b, &e) == 5) {
        uint64_t r = 0;
        if (op == 0)      r = ai_dot8(a, b);
        else if (op == 2) r = ai_max8(a, b);
        else {                                           // qrelu needs a compile-time shift on the core; emulate with a switch
            switch (sh) {
#define C(S) case S: r = AI_QRELU(S, a, b); break;
                C(0) C(1) C(2) C(3) C(4) C(5) C(6) C(7) C(8) C(9) C(10) C(11) C(12) C(13) C(14) C(15)
                C(16) C(17) C(18) C(19) C(20) C(21) C(22) C(23) C(24) C(25) C(26) C(27) C(28) C(29) C(30) C(31)
            }
        }
        if (r != e && ++bad < 10) printf("MISMATCH op=%u sh=%u a=%llx b=%llx got %llx exp %llx\n", op, sh, a, b, (unsigned long long)r, e);
        n++;
    }
    printf("%ld vectors, %ld mismatches -> %s\n", n, bad, bad ? "FAIL" : "PASS");
    return bad != 0;
}