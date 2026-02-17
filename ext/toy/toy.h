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
uint64_t toy_u64_max(void);

void toy_divmod(int a, int b, int *quotient, int *remainder);
int toy_add_with_carry(int a, int b, int *result);
void toy_sincos_approx(double x, double *sin_out, double *cos_out);
void toy_classify(int x, bool *is_positive, bool *is_zero);
void toy_widen_add(int a, int b, int64_t *wide_sum);
void toy_double_u8(uint8_t input, uint8_t *doubled);
void toy_f32_out(float a, float b, float *sum);

#endif
