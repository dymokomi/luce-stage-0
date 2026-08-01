/* Dense matrix multiply — the same n x n float multiply as
 * bench/matmul.luc: rank-1 layout, manual row indexing, ikj order,
 * quarter-integer values so the checksum is exact.  -O3 vectorizes
 * the j loop; the gap against scalar Luce is the honest measure of
 * SIMD. */
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    const long n = 400;
    double *a = malloc(sizeof(double) * n * n);
    double *b = malloc(sizeof(double) * n * n);
    double *c = calloc(n * n, sizeof(double));
    for (long i = 0; i < n * n; i++) {
        a[i] = (double)((i * 7) % 16) * 0.25;
        b[i] = (double)((i * 13) % 16) * 0.25;
    }
    for (long i = 0; i < n; i++) {
        for (long k = 0; k < n; k++) {
            double pivot = a[i * n + k];
            for (long j = 0; j < n; j++) {
                c[i * n + j] += pivot * b[k * n + j];
            }
        }
    }
    double checksum = 0.0;
    for (long i = 0; i < n * n; i++) checksum += c[i];
    printf("%ld\n", (long)checksum);
    free(a);
    free(b);
    free(c);
    return 0;
}
