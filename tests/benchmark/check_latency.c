/*
 * check_latency.c -- Times onez_check() on a generated document.
 *
 * Usage: check_latency <stdlib-path> [reps]
 *
 * Each scenario checks the same 300-word document of about 10 KB. The plain scenario has no imports.
 * The imports scenario starts with stdlib imports. The parse error scenario leaves a bracket
 * unclosed mid-document. One handle serves every rep, as a long-lived host would use it.
 *
 * Prints one line per scenario: name, reps, median, minimum, and maximum in milliseconds, then the
 * diagnostics count and the return code of the last rep.
 *
 * Build and run it against a release library with `make benchmark-check-latency`.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "onez.h"

#define WORDS 300

static const char *IMPORTS =
    "use \"strings\" ;\n"
    "use \"sequences\" ;\n"
    "use \"sets\" ;\n"
    "use \"text\" ;\n";

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1e3 + (double)ts.tv_nsec / 1e6;
}

static int cmp_double(const void *a, const void *b) {
    double x = *(const double *)a;
    double y = *(const double *)b;
    return (x > y) - (x < y);
}

/* Builds the document. The rep number lands in the last word so each rep is a different text. */
static size_t build(char *buf, size_t cap, int imports, int broken, int rep) {
    size_t n = 0;

    if (imports) {
        n += (size_t)snprintf(buf + n, cap - n, "%s", IMPORTS);
    }

    for (int i = 0; i < WORDS; i++) {
        if (broken && i == WORDS / 2) {
            n += (size_t)snprintf(buf + n, cap - n, "broken: ( n -- n ) [ 1 +\n");
        }

        int v = i == WORDS - 1 ? rep : i;
        n += (size_t)snprintf(buf + n, cap - n, "word-%03d: ( n -- n ) [ %04d + ] ;\n", i, v);
    }

    return n;
}

static int run(onez_t ctx, const char *name, int imports, int broken, int reps) {
    size_t cap = 16384;
    char *buf = malloc(cap);
    double *ms = malloc((size_t)reps * sizeof(double));
    int rc = 0;

    onez_set_source(ctx, name, strlen(name));

    for (int rep = 0; rep < reps + 2; rep++) {
        size_t len = build(buf, cap, imports, broken, rep);
        double t0 = now_ms();
        rc = onez_check(ctx, buf, len);
        double t1 = now_ms();

        if (rep >= 2) {
            ms[rep - 2] = t1 - t0;
        }
    }

    qsort(ms, (size_t)reps, sizeof(double), cmp_double);
    printf("%-12s reps=%d median=%.3f min=%.3f max=%.3f diagnostics=%zu rc=%d\n", name, reps,
           ms[reps / 2], ms[0], ms[reps - 1], onez_diag_count(ctx), rc);

    if (onez_diag_count(ctx) > 0) {
        printf("%-12s first diagnostic: %s\n", "", onez_diag_message(ctx, 0));
    } else if (rc != 0) {
        printf("%-12s error: %s\n", "", onez_last_error(ctx));
    }

    free(ms);
    free(buf);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <stdlib-path> [reps]\n", argv[0]);
        return 2;
    }

    int reps = argc > 2 ? atoi(argv[2]) : 25;

    onez_t ctx = onez_init();
    if (!ctx) {
        fprintf(stderr, "onez_init failed\n");
        return 1;
    }

    onez_set_stdlib_path(ctx, argv[1], strlen(argv[1]));

    run(ctx, "plain", 0, 0, reps);
    run(ctx, "imports", 1, 0, reps);
    run(ctx, "parse-error", 0, 1, reps);

    onez_deinit(ctx);
    return 0;
}
