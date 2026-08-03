/* String manipulation: the same work as bench/strings.luc — build a
 * big text, split it, count a needle, case-fold, replace — written
 * the plain C way (one big buffer, offset scans, no libc search
 * helpers, so both sides run the same naive algorithms). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The Luce twin builds the same text; both sides must print the same
 * numbers, so this bound is part of the benchmark and not a knob. */
#define ITEM_COUNT 400000
/* The longest one piece can be: "item-" + an int's ten digits + a
 * ';' + the terminator snprintf writes.  Deriving the buffer from the
 * loop bound rather than picking a round number means a changed bound
 * cannot silently outgrow it. */
#define PIECE_MAX (5 + 10 + 1 + 1)

int main(void) {
    /* Build "item-0;item-1;...". */
    size_t capacity = (size_t)ITEM_COUNT * PIECE_MAX;
    char *text = malloc(capacity);
    if (!text) return 1;
    size_t length = 0;
    for (int i = 0; i < ITEM_COUNT; i++) {
        int wrote = snprintf(text + length, capacity - length, "item-%d;", i);
        /* A benchmark that overran its buffer would still print a
         * number, and the harness compares numbers.  Say so instead. */
        if (wrote < 0 || (size_t)wrote >= capacity - length) {
            fprintf(stderr, "strings: %d items do not fit in %zu bytes\n", ITEM_COUNT, capacity);
            return 1;
        }
        length += (size_t)wrote;
    }

    /* Split on ';', keeping empty pieces: count them and sum their
     * lengths (the Luce side allocates a List of pieces; the C idiom
     * is offsets — the scan is the same). */
    long piece_count = 0;
    long total_len = 0;
    size_t run = 0;
    for (size_t at = 0; at < length; at++) {
        if (text[at] == ';') {
            total_len += (long)(at - run);
            piece_count++;
            run = at + 1;
        }
    }
    total_len += (long)(length - run);
    piece_count++;

    /* Count occurrences of "1" by naive scan. */
    const char *needle = "1";
    size_t needle_len = strlen(needle);
    long ones = 0;
    for (size_t at = 0; at + needle_len <= length; at++) {
        int matched = 1;
        for (size_t i = 0; i < needle_len; i++) {
            if (text[at + i] != needle[i]) { matched = 0; break; }
        }
        if (matched) { ones++; at += needle_len - 1; }
    }

    /* ASCII upper into a fresh buffer. */
    char *upper_text = malloc(length + 1);
    for (size_t at = 0; at < length; at++) {
        char c = text[at];
        upper_text[at] = (c >= 'a' && c <= 'z') ? (char)(c - 32) : c;
    }
    size_t upper_len = length;

    /* Replace every "item-" with "x" into a fresh buffer. */
    const char *old = "item-";
    size_t old_len = strlen(old);
    char *replaced = malloc(length + 1);
    size_t out = 0;
    size_t at = 0;
    while (at < length) {
        int matched = at + old_len <= length;
        for (size_t i = 0; matched && i < old_len; i++) {
            if (text[at + i] != old[i]) matched = 0;
        }
        if (matched) {
            replaced[out++] = 'x';
            at += old_len;
        } else {
            replaced[out++] = text[at++];
        }
    }

    printf("%zu %ld %ld %ld %zu %zu\n",
           length, piece_count, total_len, ones, upper_len, out);
    free(text);
    free(upper_text);
    free(replaced);
    return 0;
}
