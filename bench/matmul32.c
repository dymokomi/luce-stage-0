/* Dense matrix multiply at binary32 — the twin of bench/matmul32.luc,
 * and the 32-bit companion to bench/matmul.c.  Same rank-1 layout,
 * same ikj order, same small-integer factors so every element of C is
 * an exact whole number in binary32 and the checksum compares
 * exactly.  -O3 vectorizes the j loop four lanes wide here where the
 * `double` twin gets two; the gap against Luce is the honest measure
 * of whether the narrow float bought anything. */
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    const long n = 400;
    float *a = malloc(sizeof(float) * n * n);
    float *b = malloc(sizeof(float) * n * n);
    float *c = calloc(n * n, sizeof(float));
    for (long i = 0; i < n * n; i++) {
        a[i] = (float)((i * 7) % 4);
        b[i] = (float)((i * 13) % 4);
    }
    for (long i = 0; i < n; i++) {
        for (long k = 0; k < n; k++) {
            float pivot = a[i * n + k];
            for (long j = 0; j < n; j++) {
                c[i * n + j] += pivot * b[k * n + j];
            }
        }
    }
    long checksum = 0;
    for (long i = 0; i < n * n; i++) checksum += (long)c[i];
    printf("%ld\n", checksum);
    free(a);
    free(b);
    free(c);
    return 0;
}
