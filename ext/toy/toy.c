#include "toy.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>

int toy_add(int a, int b) {
    return a + b;
}

int toy_strlen(const char *s) {
    return (int)strlen(s);
}

char *toy_greeting(const char *name) {
    int len = snprintf(NULL, 0, "Hello, %s!", name);
    char *buf = malloc(len + 1);
    if (!buf) return NULL;
    snprintf(buf, len + 1, "Hello, %s!", name);
    return buf;
}

int toy_checksum(const unsigned char *buf, int len) {
    int sum = 0;
    for (int i = 0; i < len; i++) {
        sum += buf[i];
    }
    return sum;
}

void toy_fill(unsigned char *buf, int len, unsigned char val) {
    for (int i = 0; i < len; i++) {
        buf[i] = val;
    }
}

struct toy_counter {
    int value;
};

toy_counter *toy_open(void) {
    toy_counter *c = malloc(sizeof(toy_counter));
    if (!c) return NULL;
    c->value = 0;
    return c;
}

void toy_increment(toy_counter *c) {
    c->value++;
}

int toy_read(toy_counter *c) {
    return c->value;
}

void toy_close(toy_counter *c) {
    free(c);
}

int8_t toy_negate_i8(int8_t x) {
    return -x;
}

int16_t toy_add_i16(int16_t a, int16_t b) {
    return a + b;
}

uint16_t toy_add_u16(uint16_t a, uint16_t b) {
    return a + b;
}

float toy_float_add(float a, float b) {
    return a + b;
}

bool toy_is_positive(int x) {
    return x > 0;
}

int toy_bool_to_int(bool b) {
    return b ? 1 : 0;
}

size_t toy_usize_identity(size_t x) {
    return x;
}

ssize_t toy_isize_negate(ssize_t x) {
    return -x;
}

uint64_t toy_u64_max(void) {
    return UINT64_MAX;
}

void toy_divmod(int a, int b, int *quotient, int *remainder) {
    *quotient = a / b;
    *remainder = a % b;
}

int toy_add_with_carry(int a, int b, int *result) {
    *result = a + b;
    return (*result < a) ? 1 : 0;
}

void toy_sincos_approx(double x, double *sin_out, double *cos_out) {
    *sin_out = x - (x * x * x) / 6.0;
    *cos_out = 1.0 - (x * x) / 2.0;
}

void toy_classify(int x, bool *is_positive, bool *is_zero) {
    *is_positive = x > 0;
    *is_zero = x == 0;
}

void toy_widen_add(int a, int b, int64_t *wide_sum) {
    *wide_sum = (int64_t)a + (int64_t)b;
}

void toy_double_u8(uint8_t input, uint8_t *doubled) {
    *doubled = input * 2;
}

void toy_f32_out(float a, float b, float *sum) {
    *sum = a + b;
}

int toy_double_inout(int *val) {
    int original = *val;
    *val = original * 2;
    return original;
}

int toy_open_out(toy_counter **out) {
    *out = malloc(sizeof(toy_counter));
    if (!*out) return -1;
    (*out)->value = 0;
    return 0;
}

int toy_close_status(toy_counter *c) {
    free(c);
    return 0;
}

int toy_apply2(int a, int b, int (*fn)(int, int)) {
    return fn(a, b);
}

void toy_sort_ints(int *arr, int len, int (*cmp)(const void *, const void *)) {
    qsort(arr, len, sizeof(int), cmp);
}
