#include "ir.h"
#include <stdint.h>
#include <stddef.h>

int ir_disasm_init(void) {
    return 0;
}

void ir_disasm_free(void) {
}

void ir_disasm_add_symbol(const char *name, uint64_t addr, uint64_t size) {
    (void)name; (void)addr; (void)size;
}

const char* ir_disasm_find_symbol(uint64_t addr, int64_t *offset) {
    (void)addr; (void)offset;
    return NULL;
}

int ir_disasm(const char *name,
              const void *start,
              size_t      size,
              bool        asm_addr,
              ir_ctx     *ctx,
              FILE       *f) {
    (void)name; (void)start; (void)size; (void)asm_addr; (void)ctx; (void)f;
    return 0;
}
