/* Float arithmetic: a mandelbrot membership count.  The Luce twin is
 * bench/math.luc; identical algorithm, identical IEEE results. */
#include <stdio.h>

int main(void) {
    const long size = 2236;
    const long max_iter = 60;
    long inside = 0;
    for (long py = 0; py < size; py++) {
        for (long px = 0; px < size; px++) {
            double x0 = (double)px * (3.0 / (double)size) - 2.25;
            double y0 = (double)py * (2.5 / (double)size) - 1.25;
            double x = 0.0;
            double y = 0.0;
            long iter = 0;
            while (iter < max_iter && x * x + y * y <= 4.0) {
                double next_x = x * x - y * y + x0;
                y = 2.0 * x * y + y0;
                x = next_x;
                iter++;
            }
            if (iter == max_iter) inside++;
        }
    }
    printf("%ld\n", inside);
    return 0;
}
