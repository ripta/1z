const sifive_test_base: usize = 0x100000;
const pass_value: u32 = 0x5555;
const fail_value_tag: u32 = 0x3333;

pub fn pass() noreturn {
    finish(pass_value);
}

pub fn fail(code: u16) noreturn {
    finish((@as(u32, code) << 16) | fail_value_tag);
}

fn finish(value: u32) noreturn {
    const finisher: *volatile u32 = @ptrFromInt(sifive_test_base);
    finisher.* = value;
    while (true) asm volatile ("wfi");
}
