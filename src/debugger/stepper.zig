/// Stepper tracks the current stepping mode for the debugger.
pub const Stepper = struct {
    mode: Mode = .step_into,
    /// Target call stack depth for step_over and step_finish modes.
    target_depth: usize = 0,

    pub const Mode = enum {
        step_into,
        continue_running,
        step_over,
        step_finish,
    };
};
