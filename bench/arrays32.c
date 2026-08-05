/* The twin of bench/arrays32.luc: a repeated integer dot product over
 * int32_t arrays, the 32-bit companion to bench/arrays.c.  Same
 * shape, same values, same accumulator widths — int32_t per rep and
 * long for the total — so the two print the same number and the
 * harness will time them.  -O3 vectorizes the inner loop four lanes
 * wide where the 64-bit twin gets two. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    const long n = 200000;
    const long reps = 400;
    int32_t *a = malloc(sizeof(int32_t) * n);
    int32_t *b = malloc(sizeof(int32_t) * n);
    for (long i = 0; i < n; i++) {
        a[i] = (int32_t)(i % 100);
        b[i] = (int32_t)((i * 7) % 100);
    }
    long dot = 0;
    for (long r = 0; r < reps; r++) {
        int32_t sum = 0;
        for (long i = 0; i < n; i++) sum += a[i] * b[i];
        dot += sum;
    }
    printf("%ld\n", dot);
    free(a);
    free(b);
    return 0;
}
