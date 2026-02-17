#ifndef TOY_H
#define TOY_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <sys/types.h>

int toy_add(int a, int b);
int toy_strlen(const char *s);
char *toy_greeting(const char *name);
int toy_checksum(const unsigned char *buf, int len);
void toy_fill(unsigned char *buf, int len, unsigned char val);

typedef struct toy_counter toy_counter;
toy_counter *toy_open(void);
void toy_increment(toy_counter *c);
int toy_read(toy_counter *c);
void toy_close(toy_counter *c);

int8_t toy_negate_i8(int8_t x);
int16_t toy_add_i16(int16_t a, int16_t b);
uint16_t toy_add_u16(uint16_t a, uint16_t b);
float toy_float_add(float a, float b);
bool toy_is_positive(int x);
int toy_bool_to_int(bool b);
size_t toy_usize_identity(size_t x);
ssize_t toy_isize_negate(ssize_t x);

#endif
