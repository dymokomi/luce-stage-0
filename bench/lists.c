/* List-bound work: the twin of bench/lists.luc.  A growable byte
 * buffer and a growable long buffer, built by append, read
 * sequentially and strided, transformed in place, and histogrammed —
 * the shapes a decoder runs.
 *
 * The growth schedule is Luce's, deliberately: room for eight
 * elements first and then 1.5x plus one element, the policy in
 * src/luce/runtime/heap.zig's `ensureCapacity`.  Doubling would be
 * the more usual C idiom, but then the two sides would copy their
 * buffers a different number of times and this row would be reporting
 * that difference instead of the cost of an element.  Everything else
 * here is plain C: realloc, an index, a counter array.
 *
 * Every operand is non-negative, so C's truncating / and % agree with
 * Luce's flooring pair, and no sum can overflow. */
#include <stdio.h>
#include <stdlib.h>

/* The Luce twin builds the same run; both sides must print the same
 * numbers, so these bounds are part of the benchmark, not knobs. */
#define ELEMENT_COUNT 3000000
#define STRIDE 4099

static void *grow(void *items, size_t count, size_t capacity_bytes, size_t width,
                  size_t *capacity_out) {
    size_t needed = (count + 1) * width;
    if (needed <= capacity_bytes) {
        *capacity_out = capacity_bytes;
        return items;
    }
    size_t grown = capacity_bytes;
    if (grown < 8 * width) grown = 8 * width;
    while (grown < needed) grown = grown + grown / 2 + width;
    void *moved = realloc(items, grown);
    if (!moved) {
        fprintf(stderr, "lists: out of memory at %zu elements\n", count);
        exit(1);
    }
    *capacity_out = grown;
    return moved;
}

int main(void) {
    const long n = ELEMENT_COUNT;

    /* 1. The growth path. */
    unsigned char *data = NULL;
    size_t data_count = 0, data_capacity = 0;
    for (long i = 0; i < n; i++) {
        data = grow(data, data_count, data_capacity, sizeof *data, &data_capacity);
        data[data_count++] = (unsigned char)((i * 7 + 11) % 251);
    }

    /* 2. Sequential read. */
    long total = 0;
    for (size_t at = 0; at < data_count; at++) total += data[at];

    /* 3. Strided read. */
    long walk = 0;
    long at = 0;
    for (long step = 0; step < n; step++) {
        walk += data[at];
        at += STRIDE;
        if (at >= n) at -= n;
    }

    /* 4. In-place transform. */
    for (long i = 0; i < n; i++) {
        data[i] = (unsigned char)((data[i] * 3 + 1) & 0xFF);
    }

    /* 5. Histogram, in a long buffer of 256 counters. */
    long *counts = NULL;
    size_t counts_count = 0, counts_capacity = 0;
    for (int slot = 0; slot < 256; slot++) {
        counts = grow(counts, counts_count, counts_capacity, sizeof *counts, &counts_capacity);
        counts[counts_count++] = 0;
    }
    for (size_t index = 0; index < data_count; index++) counts[data[index]]++;
    long weighted = 0;
    long peak = 0;
    for (long slot = 0; slot < 256; slot++) {
        weighted += counts[slot] * slot;
        if (counts[slot] > peak) peak = counts[slot];
    }

    /* 6. The same shapes at eight bytes an element. */
    const long m = n / 8;
    long *marks = NULL;
    size_t marks_count = 0, marks_capacity = 0;
    for (long i = 0; i < m; i++) {
        marks = grow(marks, marks_count, marks_capacity, sizeof *marks, &marks_capacity);
        marks[marks_count++] = (long)data[i * 8] * 65537 + i;
    }
    long mark_walk = 0;
    at = 0;
    for (long step = 0; step < m; step++) {
        mark_walk += marks[at] % 1000;
        at += STRIDE;
        if (at >= m) at -= m;
    }
    for (long i = 0; i < m; i++) marks[i] = marks[i] / 3 + 1;
    long mark_total = 0;
    for (long i = 0; i < m; i++) mark_total += marks[i] % 251;

    printf("%zu %ld %ld %ld %ld %zu %ld %ld\n",
           data_count, total, walk, weighted, peak, marks_count, mark_walk, mark_total);
    free(data);
    free(counts);
    free(marks);
    return 0;
}
