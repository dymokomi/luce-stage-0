/* Array number-crunching: the twin of bench/arrays.luc.  Compiled
 * -O3 -march=native this dot product vectorizes; the comparison
 * quantifies the interpreter's scalar gap. */
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    const long n = 200000;
    const long reps = 10;
    double *a = malloc((size_t)n * sizeof(double));
    double *b = malloc((size_t)n * sizeof(double));
    for (long i = 0; i < n; i++) {
        a[i] = (double)(i % 100) * 0.5;
        b[i] = (double)((i * 7) % 100) * 0.25;
    }
    double dot = 0.0;
    for (long r = 0; r < reps; r++) {
        double sum = 0.0;
        for (long i = 0; i < n; i++) {
            sum += a[i] * b[i];
        }
        dot += sum;
    }
    printf("%ld\n", (long)dot);
    free(a);
    free(b);
    return 0;
}
