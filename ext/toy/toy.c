#include "toy.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

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
