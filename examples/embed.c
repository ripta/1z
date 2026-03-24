/*
 * embed.c -- Demonstrates embedding the 1z interpreter via the C API.
 *
 * Build:
 *   make build-example
 *
 * Run:
 *   ./zig-out/embed
 */

#include <stdio.h>
#include <string.h>
#include "onez.h"

/* Helper: evaluate a string literal (length computed automatically). */
#define EVAL(ctx, code) onez_eval((ctx), (code), strlen(code))

int main(void) {
    /* -- Initialize the interpreter -- */
    onez_t ctx = onez_init();
    if (!ctx) {
        fprintf(stderr, "onez_init failed\n");
        return 1;
    }

    /* -- Arithmetic via push/eval/pop -- */
    onez_push_int(ctx, 30);
    onez_push_int(ctx, 12);
    EVAL(ctx, "+");

    int64_t sum;
    onez_pop_int(ctx, &sum);
    printf("30 + 12 = %lld\n", (long long)sum);

    /* -- Define a word and call it -- */
    EVAL(ctx, "double: [ 2 * ] ;");
    onez_push_int(ctx, 21);
    EVAL(ctx, "double");

    int64_t doubled;
    onez_pop_int(ctx, &doubled);
    printf("double 21 = %lld\n", (long long)doubled);

    /* -- String concatenation -- */
    onez_push_string(ctx, "hello", 5);
    EVAL(ctx, "\" world\" #append");

    const char *str;
    size_t str_len;
    onez_pop_string(ctx, &str, &str_len);
    printf("concat = %.*s\n", (int)str_len, str);

    /* -- Error handling -- */
    int rc = EVAL(ctx, "1 0 /");
    if (rc != ONEZ_OK) {
        printf("error: %s\n", onez_last_error(ctx));
    }

    /* -- Stack introspection -- */
    onez_push_int(ctx, 42);
    onez_push_double(ctx, 3.14);
    onez_push_bool(ctx, true);

    size_t depth = onez_stack_depth(ctx);
    printf("stack depth = %zu\n", depth);
    for (size_t i = 0; i < depth; i++) {
        int type = onez_stack_type(ctx, i);
        printf("  [%zu] type = %d\n", i, type);
    }

    /* -- Clean up -- */
    onez_deinit(ctx);
    return 0;
}
