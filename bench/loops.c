/* Tight integer loops: multiply, remainder, accumulate.  The Luce
 * twin is bench/loops.luc; both print the same checksum. */
#include <stdio.h>

int main(void) {
    const long n = 3000;
    long total = 0;
    for (long i = 0; i < n; i++) {
        for (long j = 0; j < n; j++) {
            total += (i * j) % 7;
        }
    }
    printf("%ld\n", total);
    return 0;
}
