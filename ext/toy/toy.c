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
