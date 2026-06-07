const platform = @import("virt-platform");

pub export fn onez_baremetal_main() noreturn {
    platform.uart.writeAll("1z baremetal uart stub\n");
    platform.shutdown.pass();
}
