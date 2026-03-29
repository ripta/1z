/*
 * onez.h -- Public C API for embedding the 1z interpreter.
 *
 * Link against lib1z.a / lib1z.dylib, and libffi.
 *
 * Thread safety: a single onez_t handle must not be used from multiple
 * threads concurrently. Create separate handles for separate threads.
 *
 * String ownership follows the SQLite convention: strings returned by
 * the library (e.g. onez_last_error, onez_pop_string) are owned by the
 * library and remain valid until the next API call on the same handle.
 * Strings passed into the library, e.g., `onez_eval`, `onez_push_string`,
 * are copied, such that the caller retains ownership.
 */

#ifndef ONEZ_H
#define ONEZ_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque interpreter handle. */
typedef void *onez_t;

/* ---- Type codes, as returned by onez_stack_type ---- */

#define ONEZ_TYPE_UNKNOWN     0
#define ONEZ_TYPE_FIXNUM      1
#define ONEZ_TYPE_FLOAT       2
#define ONEZ_TYPE_BOOLEAN     3
#define ONEZ_TYPE_STRING      4
#define ONEZ_TYPE_SYMBOL      5
#define ONEZ_TYPE_ARRAY       6
#define ONEZ_TYPE_QUOTATION   7
#define ONEZ_TYPE_HASH        8
#define ONEZ_TYPE_VECTOR      9
#define ONEZ_TYPE_BYTE_ARRAY  10
#define ONEZ_TYPE_SET         11
#define ONEZ_TYPE_MUTABLE_MAP 12
#define ONEZ_TYPE_STREAM      13
#define ONEZ_TYPE_RESOURCE    14
#define ONEZ_TYPE_TAGGED      15
#define ONEZ_TYPE_ITERATOR    16
#define ONEZ_TYPE_TYPE_VAL    17
#define ONEZ_TYPE_UNIT        18

/* ---- Error codes ---- */

#define ONEZ_OK                 0
#define ONEZ_ERR_NULL_HANDLE   -1
#define ONEZ_ERR_TYPE_MISMATCH  1
#define ONEZ_ERR_STACK_UNDERFLOW 2
#define ONEZ_ERR_ALLOC          3

/* ----- Lifecycle ----- */

/*
 * Create and initialize a new interpreter context. Loads the prelude.
 *
 * Returns NULL on allocation or prelude failure.
 *
 * The standard library is discovered relative to the executable by default.
 * Call `onez_set_stdlib_path` after init if the stdlib lives elsewhere.
 */
onez_t onez_init(void);

/*
 * Destroy an interpreter context and free all associated memory.
 * Passing NULL is safe, and trated as noöp.
 */
void onez_deinit(onez_t ctx);

/* ---- Eval ---- */

/*
 * Evaluate a string of 1z source code. The source is not required to be
 * null-terminated; `len` bytes starting at `code` are read.
 *
 * Returns ONEZ_OK (0) on success, or a positive error code on failure.
 * After failure, call `onez_last_error` for a human-readable message.
 */
int onez_eval(onez_t ctx, const char *code, size_t len);

/* ---- Push (C -> 1z stack) ---- */

int onez_push_int(onez_t ctx, int64_t value);
int onez_push_double(onez_t ctx, double value);
int onez_push_bool(onez_t ctx, bool value);

/*
 * Push a string onto the stack. The data is copied; the caller retains
 * ownership of `data`. The string need not be null-terminated; `len`
 * bytes are copied.
 */
int onez_push_string(onez_t ctx, const char *data, size_t len);

/* ---- Pop (1z stack -> C) ---- */

/*
 * Pop a value from the stack into the output parameter.
 *
 * Returns ONEZ_OK on success.
 * Returns ONEZ_ERR_STACK_UNDERFLOW if the stack is empty.
 * Returns ONEZ_ERR_TYPE_MISMATCH if the top value is the wrong type, and said value is pushed back.
 */
int onez_pop_int(onez_t ctx, int64_t *out);
int onez_pop_double(onez_t ctx, double *out);
int onez_pop_bool(onez_t ctx, bool *out);

/*
 * Pop a string from the stack. On success, *out_ptr and *out_len are set.
 *
 * The returned pointer is NOT null-terminated; use out_len for the length.
 * The pointer is valid until the next API call on this handle.
 */
int onez_pop_string(onez_t ctx, const char **out_ptr, size_t *out_len);

/* ---- Stack introspection ---- */

/* Return the number of values currently on the stack. */
size_t onez_stack_depth(onez_t ctx);

/*
 * Return the type code of the value at the given stack index, where 0 is top of stack.
 * Returns ONEZ_TYPE_UNKNOWN for out-of-range indices.
 */
int onez_stack_type(onez_t ctx, size_t index);

/* ---- Error reporting ---- */

/*
 * Return a null-terminated error message from the last failed operation,
 * or NULL if no error has occurred. The pointer is valid until the next
 * API call on this handle.
 */
const char *onez_last_error(onez_t ctx);

/*
 * Print structured error details to stderr. Includes source location,
 * error type, stack traces, and hints when available.
 */
void onez_print_error(onez_t ctx);

/* ---- Configuration ---- */

/*
 * Override the standard library search path. The data is copied.
 * Call this after `onez_init` if the stdlib is not in the default location.
 */
int onez_set_stdlib_path(onez_t ctx, const char *path, size_t len);

/*
 * Set the source name used in error messages. The data is copied.
 * Defaults to "<repl>". onez_set_args sets this to argv[0] automatically.
 */
int onez_set_source(onez_t ctx, const char *data, size_t len);

/*
 * Set command-line arguments on the context. Populates program_args for
 * sys-info access and sets source attribution to argv[0].
 * The argv strings are NOT copied; they must remain valid for the lifetime
 * of the handle.
 */
int onez_set_args(onez_t ctx, int argc, char **argv);

/* ---- AOT Runtime ---- */

/*
 * Register the AOT-compiled dispatch table with the runtime.
 * `table` is an array of function pointers (NULL for uncompiled slots).
 * `size` is the number of entries.
 */
int onez_runtime_register_compiled(onez_t rt, int32_t (**table)(uintptr_t), const char **names, uint32_t size);

/*
 * Execute the AOT entry word. Returns 0 on success, non-zero on error.
 */
int32_t onez_runtime_run(onez_t rt, uint32_t entry_word_id);

#ifdef __cplusplus
}
#endif

#endif /* ONEZ_H */
