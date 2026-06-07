.section .text.boot
.global _start
.type _start, @function

_start:
    la sp, __stack_top
    call onez_baremetal_main

1:
    wfi
    j 1b

.size _start, . - _start
