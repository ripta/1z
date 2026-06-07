pub const mmio_base: usize = 0x10000000;

const tx_offset = 0;
const line_status_offset = 5;
const line_status_thre = 1 << 5;

pub const Writer = struct {
    base: usize = mmio_base,

    pub fn writeByte(self: Writer, byte: u8) void {
        const status: *volatile u8 = @ptrFromInt(self.base + line_status_offset);
        const tx: *volatile u8 = @ptrFromInt(self.base + tx_offset);
        while ((status.* & line_status_thre) == 0) {}
        tx.* = byte;
    }

    pub fn writeAll(self: Writer, bytes: []const u8) void {
        for (bytes) |byte| self.writeByte(byte);
    }
};

pub fn writer() Writer {
    return .{};
}

pub fn writeByte(byte: u8) void {
    writer().writeByte(byte);
}

pub fn writeAll(bytes: []const u8) void {
    writer().writeAll(bytes);
}
