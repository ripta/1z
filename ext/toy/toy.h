#ifndef TOY_H
#define TOY_H

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

#endif
