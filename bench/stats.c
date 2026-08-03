/* Vector statistics — the same reductions as bench/stats.luc,
 * mirroring src/luce/std/math.luc's implementations operation for
 * operation (left-to-right accumulation, two-pass variance), so the
 * printed integers match exactly.
 *
 * The extrema are as close as C gets rather than the same operation:
 * `a < b ? a : b` answers by operand order where Luce's `min` answers
 * IEEE-754-2019 minimumNumber.  They agree on this data, which has no
 * NaN and no negative zero, and they compile differently — see the
 * header of bench/stats.luc. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static double vec_sum(const double *xs, long n) {
    double total = 0.0;
    for (long i = 0; i < n; i++) total += xs[i];
    return total;
}

static double vec_min(const double *xs, long n) {
    double smallest = xs[0];
    for (long i = 1; i < n; i++) smallest = xs[i] < smallest ? xs[i] : smallest;
    return smallest;
}

static double vec_max(const double *xs, long n) {
    double largest = xs[0];
    for (long i = 1; i < n; i++) largest = xs[i] > largest ? xs[i] : largest;
    return largest;
}

static double vec_dot(const double *xs, const double *ys, long n) {
    double total = 0.0;
    for (long i = 0; i < n; i++) total += xs[i] * ys[i];
    return total;
}

static double vec_variance(const double *xs, long n) {
    double center = vec_sum(xs, n) / (double)n;
    double total = 0.0;
    for (long i = 0; i < n; i++) {
        double d = xs[i] - center;
        total += d * d;
    }
    return total / (double)n;
}

int main(void) {
    const long n = 2000000;
    double *a = malloc(sizeof(double) * n);
    double *b = malloc(sizeof(double) * n);
    for (long i = 0; i < n; i++) {
        a[i] = (double)((i * 7) % 32) * 0.25;
        b[i] = (double)((i * 13) % 32) * 0.25;
    }
    double checksum = 0.0;
    for (int r = 0; r < 6; r++) {
        checksum += vec_dot(a, b, n);
        checksum += vec_variance(a, n);
        checksum += sqrt(vec_dot(b, b, n));
    }
    long low = (long)(vec_min(b, n) * 4.0);
    long high = (long)(vec_max(b, n) * 4.0);
    printf("%ld %ld %ld %ld\n", (long)vec_sum(a, n), low, high, (long)checksum);
    free(a);
    free(b);
    return 0;
}
