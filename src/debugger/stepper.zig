/// Stepper tracks the current stepping mode for the debugger.
pub const Stepper = struct {
    mode: Mode = .step_into,

    pub const Mode = enum {
        step_into,
        continue_running,
    };
};
