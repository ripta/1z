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

/* Callback function type for host-registered words. The callback receives
 * the onez_t context and a user_data pointer provided at registration time.
 *
 * The callback may use the normal push / pop / value APIs to interact with
 * the 1z stack and values. It should return ONEZ_OK (0) on success, or a
 * positive error code on failure. After failure, call `onez_last_error`
 * for a human-readable message.
 */
typedef int (*onez_callback_fn)(onez_t ctx, void *user_data);

/*
 * Opaque value handle. Valid until onez_deinit on the owning context.
 *
 * A handle is bound to the context that created it. Passing a handle to
 * a different context, or using it after the owning context has been
 * destroyed, is undefined behavior (same contract as onez_t itself).
 *
 * Each onez_pop_value call allocates a small arena cell that lives until
 * onez_deinit. Handles are cheap but not free; callers doing unbounded
 * pop_value calls on a long-lived context will accumulate memory.
 */
typedef void *onez_value_t;

/* Opaque type handle for dispatch integration. Obtained via onez_lookup_type. */
typedef void *onez_type_t;

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
#define ONEZ_TYPE_STRUCT      19

/* ---- Error codes ---- */

#define ONEZ_OK                 0
#define ONEZ_ERR_NULL_HANDLE   -1
#define ONEZ_ERR_TYPE_MISMATCH  1
#define ONEZ_ERR_STACK_UNDERFLOW 2
#define ONEZ_ERR_ALLOC          3
#define ONEZ_ERR_NULL_VALUE    -2
#define ONEZ_ERR_INDEX_OUT_OF_RANGE 4
#define ONEZ_ERR_KEY_NOT_FOUND      5
#define ONEZ_ERR_LOAD_FAILED        6
#define ONEZ_ERR_NOT_HOST_WORD      7
#define ONEZ_ERR_INVALID_EFFECT     8
#define ONEZ_ERR_WORD_NOT_FOUND     9
#define ONEZ_ERR_ISOLATION_UNDERFLOW 10
#define ONEZ_ERR_DEBUGGER_NOT_ACTIVE 11
#define ONEZ_ERR_BREAKPOINT_NOT_FOUND 12

/* ---- Debug event constants ---- */

#define ONEZ_EVENT_PAUSED          0
#define ONEZ_EVENT_RESUMED         1
#define ONEZ_EVENT_BREAKPOINT_HIT  2
#define ONEZ_EVENT_STEP_COMPLETED  3

/* ---- Local kind constants ---- */

#define ONEZ_LOCAL_COMPOUND 0
#define ONEZ_LOCAL_NATIVE   1

/* Debug event callback. Receives the event code, the onez_t handle, and
 * the user_data pointer provided to onez_debug_set_callback. */
typedef void (*onez_debug_callback_fn)(int event, onez_t handle, void *user_data);

/* ---- Diagnostic severity ---- *
 *
 * Returned by onez_diag_severity() to classify diagnostics produced by
 * onez_check(). Values match the declaration order of the internal
 * Severity enum, so the mapping is stable.
 */

#define ONEZ_DIAG_ERROR   0
#define ONEZ_DIAG_WARNING 1
#define ONEZ_DIAG_NOTE    2

/* ----- Lifecycle ----- */

/*
 * Create and initialize a new interpreter context with primitives only.
 * The prelude is NOT loaded. Call onez_load_prelude() afterwards to load
 * the default embedded prelude or a custom prelude from a file.
 *
 * Returns NULL on allocation failure.
 *
 * The standard library is discovered relative to the executable by default.
 * Call `onez_set_stdlib_path` after init if the stdlib lives elsewhere.
 */
onez_t onez_init_no_prelude(void);

/*
 * Load the prelude into a context created with onez_init_no_prelude().
 *
 * If path is NULL, the default embedded prelude is loaded.
 * If path is non-NULL, the file at the given null-terminated path is
 * read and used as the prelude source.
 *
 * Returns ONEZ_OK on success, or ONEZ_ERR_LOAD_FAILED on failure.
 */
int onez_load_prelude(onez_t ctx, const char *path);

/*
 * Create and initialize a new interpreter context. Loads the default
 * embedded prelude. Equivalent to onez_init_no_prelude() followed by
 * onez_load_prelude(ctx, NULL).
 *
 * Returns NULL on allocation or prelude failure.
 *
 * The standard library is discovered relative to the executable by default.
 * Call `onez_set_stdlib_path` after init if the stdlib lives elsewhere.
 */
onez_t onez_init(void);

/*
 * Destroy an interpreter context and free all associated memory.
 * Passing NULL is safe, and treated as noöp.
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

/*
 * Evaluate a .1z file by path. The null-terminated path is opened, read
 * line-by-line, and executed as if passed to onez_eval. No module is
 * created; definitions become visible in the current scope.
 *
 * Sets source attribution for error messages to the given file path.
 *
 * Returns ONEZ_OK on success, or a non-zero error code on failure.
 */
int onez_eval_file(onez_t ctx, const char *path);

/* ---- Isolation ---- */

/*
 * Push an isolation frame. Type registrations, dispatch entries, and
 * protocol obligations created after this call are scoped: they will
 * be discarded when onez_isolation_end is called. Stack values are
 * not affected -- only type-system side effects are isolated.
 *
 * Isolation frames nest: each begin must have a matching end.
 *
 * Returns ONEZ_OK on success, or ONEZ_ERR_ALLOC on allocation failure.
 */
int onez_isolation_begin(onez_t ctx);

/*
 * Pop an isolation frame, discarding type-system side effects created
 * since the matching onez_isolation_begin call.
 *
 * Must be called even if evaluation within the isolation scope failed,
 * to ensure frames are properly cleaned up.
 *
 * Returns ONEZ_OK on success.
 * Returns ONEZ_ERR_ISOLATION_UNDERFLOW if no isolation frame is active.
 */
int onez_isolation_end(onez_t ctx);

/*
 * Convenience wrapper: evaluate code within an isolation scope.
 *
 * Equivalent to:
 *
 *   onez_isolation_begin(ctx);
 *   int rc = onez_eval(ctx, code, len);
 *   onez_isolation_end(ctx); // <- always runs, even if eval failed
 *   return rc;
 *
 * Stack values survive; type-system side effects are discarded.
 */
int onez_eval_isolated(onez_t ctx, const char *code, size_t len);

/*
 * Register a host callback as a top-level 1z word.
 *
 * The name is copied. The callback receives the same onez_t handle passed to
 * onez_register_word and may use the normal push / pop / value APIs.
 */
int onez_register_word(onez_t ctx, const char *name, onez_callback_fn callback, void *user_data);

/*
 * Register a host callback as a top-level 1z word with an optional stack
 * effect annotation.
 *
 * effect_str may be NULL (no effect) or a stack effect string such as
 * "a b -- c" or "( a b -- c )". Parentheses are stripped automatically.
 * The annotated effect is visible through the 1z `help` word and the
 * >word-info introspection API.
 *
 * Returns ONEZ_ERR_INVALID_EFFECT if effect_str is non-NULL but malformed.
 */
int onez_register_word_with_effect(onez_t ctx, const char *name,
    const char *effect_str, onez_callback_fn callback, void *user_data);

/*
 * Remove a previously registered host word from the dictionary.
 *
 * Only words registered via onez_register_word can be unregistered.
 * Attempting to unregister a native or compound word returns
 * ONEZ_ERR_NOT_HOST_WORD.
 *
 * Returns ONEZ_OK on success.
 * Returns ONEZ_ERR_KEY_NOT_FOUND if the word is not in the dictionary.
 * Returns ONEZ_ERR_NOT_HOST_WORD if the word exists but is not a host callback.
 */
int onez_unregister_word(onez_t ctx, const char *name);

/*
 * Set a custom error message from within a host callback.
 *
 * Call this before returning a non-zero status from a callback to provide
 * a human-readable error message. The message is copied; the caller
 * retains ownership of `msg`. The string need not be null-terminated;
 * `len` bytes are read.
 *
 * If called outside a callback, the message is stored but has no effect
 * until the next error is raised.
 */
void onez_set_error(onez_t ctx, const char *msg, size_t len);

/* ---- Type lookup and dispatch ---- */

/*
 * Look up a type by name, returning an opaque handle for use with
 * onez_register_method. The handle remains valid for the lifetime of
 * the context.
 *
 * Returns NULL if the type is not found, or if ctx or name is NULL.
 */
onez_type_t onez_lookup_type(onez_t ctx, const char *name);

/*
 * Register a host callback as a method on an existing generic word for
 * a specific type combination.
 *
 * type_a and type_b are type handles obtained from onez_lookup_type.
 * Pass NULL for a wildcard:
 *   - type_a=NULL, type_b=NULL: unary wildcard (matches any single arg)
 *   - type_a=T,    type_b=NULL: unary method for type T
 *   - type_a=NULL, type_b=T:   binary wildcard on first, exact on second
 *   - type_a=T,    type_b=U:   exact binary method
 *
 * The word must already exist in the dictionary. If the same type
 * combination is already registered, the new callback overwrites it.
 *
 * Returns ONEZ_OK on success.
 * Returns ONEZ_ERR_WORD_NOT_FOUND if word_name is not in the dictionary.
 */
int onez_register_method(onez_t ctx, const char *word_name,
    onez_type_t type_a, onez_type_t type_b,
    onez_callback_fn callback, void *user_data);

/* ---- Module loading ---- */

/*
 * Load and execute a .1z file. The path is resolved using the same rules
 * as the 1z `load-file` primitive: relative paths resolve against the
 * current source directory, absolute paths are used directly.
 *
 * On success, the loaded module is pushed onto the stack. The caller may
 * pop it with onez_pop_value, import it with onez_eval(ctx, "import", 6),
 * or leave it on the stack.
 *
 * Returns ONEZ_OK on success, or ONEZ_ERR_LOAD_FAILED on failure.
 */
int onez_load_file(onez_t ctx, const char *path, size_t path_len);

/*
 * Load a module by name and import all its public words into the current
 * scope. Equivalent to `use "name" ;` in 1z source code.
 *
 * Module resolution searches the configured load paths and stdlib path.
 * Cached modules are reused without reloading.
 *
 * Returns ONEZ_OK on success, or ONEZ_ERR_LOAD_FAILED on failure.
 */
int onez_use_module(onez_t ctx, const char *name, size_t name_len);

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

/*
 * Push a symbol onto the stack. The data is copied; the caller retains
 * ownership of `data`. The string need not be null-terminated; `len`
 * bytes are copied.
 */
int onez_push_symbol(onez_t ctx, const char *data, size_t len);

/*
 * Push an array built from an array of value handles onto the stack.
 *
 * Returns ONEZ_OK on success.
 * Returns ONEZ_ERR_NULL_VALUE if any element handle is NULL.
 */
int onez_push_array(onez_t ctx, const onez_value_t *handles, size_t count);

/*
 * Pop any value from the stack as an opaque handle.
 *
 * On success, *out is set to a non-NULL handle and ONEZ_OK is returned.
 * Returns ONEZ_ERR_STACK_UNDERFLOW if the stack is empty.
 * Returns ONEZ_ERR_ALLOC if the arena allocation fails.
 * Returns ONEZ_ERR_NULL_HANDLE if ctx is NULL.
 */
int onez_pop_value(onez_t ctx, onez_value_t *out);

/*
 * Push a previously obtained value handle back onto the stack.
 *
 * The handle must belong to the same context. Passing a handle from a
 * different context is undefined behavior.
 *
 * Returns ONEZ_OK on success.
 * Returns ONEZ_ERR_NULL_HANDLE if ctx is NULL.
 * Returns ONEZ_ERR_NULL_VALUE if handle is NULL.
 * Returns ONEZ_ERR_ALLOC on stack allocation failure.
 */
int onez_push_value(onez_t ctx, onez_value_t handle);

/*
 * Return the type code of a value handle (ONEZ_TYPE_* constants).
 * Returns ONEZ_TYPE_UNKNOWN if handle is NULL.
 */
int onez_value_type(onez_value_t handle);

/* ---- Value access ---- */

/*
 * Return the number of elements in an array handle.
 * Returns 0 if handle is NULL or not an array.
 */
size_t onez_array_length(onez_value_t handle);

/*
 * Get the element at `index` from an array handle.
 *
 * On success, *out is set to a new handle and ONEZ_OK is returned.
 * Returns ONEZ_ERR_TYPE_MISMATCH if handle is not an array.
 * Returns ONEZ_ERR_INDEX_OUT_OF_RANGE if index >= array length.
 */
int onez_array_get(onez_t ctx, onez_value_t handle, size_t index, onez_value_t *out);

/*
 * Look up a string key in a hash handle.
 *
 * On success, *out is set to a new handle and ONEZ_OK is returned.
 * Returns ONEZ_ERR_TYPE_MISMATCH if handle is not a hash.
 * Returns ONEZ_ERR_KEY_NOT_FOUND if the key is not present.
 */
int onez_hash_get(onez_t ctx, onez_value_t handle, const char *key, size_t key_len, onez_value_t *out);

/*
 * Return the keys of a hash as an array handle of symbols.
 *
 * On success, *out is set to a new array handle and ONEZ_OK is returned.
 * Returns ONEZ_ERR_TYPE_MISMATCH if handle is not a hash.
 */
int onez_hash_keys(onez_t ctx, onez_value_t handle, onez_value_t *out);

/*
 * Look up a field by name on a struct instance handle.
 *
 * On success, *out is set to a new handle and ONEZ_OK is returned.
 * Returns ONEZ_ERR_TYPE_MISMATCH if handle is not a struct instance.
 * Returns ONEZ_ERR_KEY_NOT_FOUND if the field name is not present.
 */
int onez_struct_get(onez_t ctx, onez_value_t handle, const char *field, size_t field_len, onez_value_t *out);

/*
 * Return the tag name of a virtual type (tagged value) handle.
 *
 * On success, *out_ptr and *out_len are set to the name string.
 * The pointer is valid until onez_deinit.
 * Returns ONEZ_ERR_TYPE_MISMATCH if handle is not a tagged value.
 * Returns ONEZ_ERR_NULL_VALUE if handle is NULL.
 */
int onez_virtual_type_name(onez_value_t handle, const char **out_ptr, size_t *out_len);

/*
 * Unwrap a virtual type (tagged value) to get its inner value.
 *
 * On success, *out is set to a new handle for the inner value.
 * Returns ONEZ_ERR_TYPE_MISMATCH if handle is not a tagged value.
 */
int onez_virtual_unwrap(onez_t ctx, onez_value_t handle, onez_value_t *out);

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

/* ---- Static analysis ---- *
 *
 * onez_check() runs 1z's static analyzer over a chunk of source without
 * executing non-definition statements. It is the embedded equivalent of
 * the `--check` CLI flag: stack-effect inference, type checking, and
 * arity validation are performed and reported as diagnostics, which can
 * be iterated with the onez_diag_* accessors below.
 *
 * Behavior
 * --------
 * - The source is parsed line-by-line using the same statement processor
 *   that onez_eval() uses.
 * - Statements ending in `;` are treated as definitions: they are
 *   registered into the current local frame. All other statements are
 *   parsed and dropped; they are NOT executed.
 * - After parsing, the inference engine analyzes every compound word
 *   whose `source_file` matches `ctx.current_source` at the time of the
 *   call.
 * - Any #pragma directives in the checked source (`suppress-checks`,
 *   `suppress-undeclared`, `type-check`, `callsite-arity-mismatch`)
 *   affect severity and reporting exactly as they would under `--check`.
 *
 * Persistence
 * -----------
 * onez_check() is persistent by default: definitions added by the call
 * remain in the dictionary after it returns. This matches onez_eval().
 * Repeated onez_check() calls against different source names accumulate;
 * calls against the same source name redefine those words.
 *
 * To run an ephemeral check, wrap the call in an isolation bracket. This
 * is the composable way to opt into ephemeral semantics, and it lets the
 * caller read diagnostics BEFORE the isolation frame is popped:
 *
 *   // Check a snippet without leaking definitions into the host context.
 *   onez_isolation_begin(ctx);
 *   int rc = onez_check(ctx, src, len);
 *   for (size_t i = 0; i < onez_diag_count(ctx); i++) {
 *       fprintf(stderr, "%s: %s\n",
 *               onez_diag_source(ctx, i),
 *               onez_diag_message(ctx, i));
 *   }
 *   onez_isolation_end(ctx);
 *
 * No dedicated `onez_check_isolated` helper is provided because the
 * bracket form above is both trivial and more flexible.
 *
 * Source scoping
 * --------------
 * Analysis filters to words whose `source_file` equals `ctx.current_source`
 * at the time of the call. To check multiple independent snippets, set a
 * distinct source name with onez_set_source() before each call (for
 * example, a file path or a synthetic name like "snippet-1"). Without
 * explicit source control, every word defined under the default "<repl>"
 * source is re-analyzed on each call.
 *
 * Return code
 * -----------
 * Returns ONEZ_OK (0) when no error-severity diagnostics were produced
 * and parsing succeeded. Returns 1 if any error diagnostic was produced
 * or if parsing failed. Warnings and notes DO NOT affect the return
 * code; iterate with onez_diag_* to discover them.
 *
 * Parse errors vs inference diagnostics
 * -------------------------------------
 * Parse errors surface through onez_last_error() and DO NOT populate the
 * diagnostics list: onez_diag_count() returns 0 in that case. This
 * matches the LSP separation between syntax errors and inference output.
 * Callers that want to treat both uniformly can check onez_last_error()
 * whenever onez_check() returns a non-zero code.
 *
 * Diagnostic lifetime
 * -------------------
 * Each onez_check() call clears the previous diagnostics list before
 * running. Any pointers returned by a previous onez_diag_message(),
 * onez_diag_source(), or onez_diag_word() call are invalidated at the
 * start of the next onez_check() on the same handle. Other API calls
 * (including onez_eval) do not touch the diagnostics list.
 */
int onez_check(onez_t ctx, const char *code, size_t len);

/*
 * Return the number of diagnostics produced by the most recent
 * onez_check() call on this handle. Returns 0 on a null handle.
 */
size_t onez_diag_count(onez_t ctx);

/*
 * Return the severity of the diagnostic at `index`. One of
 * ONEZ_DIAG_ERROR, ONEZ_DIAG_WARNING, or ONEZ_DIAG_NOTE.
 * Returns -1 on a null handle or out-of-range index.
 */
int onez_diag_severity(onez_t ctx, size_t index);

/*
 * Return the null-terminated message of the diagnostic at `index`.
 * Returns NULL on a null handle or out-of-range index.
 *
 * The returned pointer is valid only until the next onez_check() call
 * on this handle. Hosts that need to retain diagnostic data across
 * checks must copy the string.
 */
const char *onez_diag_message(onez_t ctx, size_t index);

/*
 * Return the null-terminated source-file name attributed to the
 * diagnostic at `index`. Returns NULL when the underlying diagnostic
 * has no associated source file, on a null handle, or on an
 * out-of-range index.
 *
 * The returned pointer is valid only until the next onez_check() call
 * on this handle. Hosts that need to retain diagnostic data across
 * checks must copy the string.
 */
const char *onez_diag_source(onez_t ctx, size_t index);

/*
 * Return the source line of the diagnostic at `index`. Returns 0 when
 * the line is unknown, the handle is null, or the index is out of
 * range. Callers that need to distinguish "unknown line" from
 * "out-of-range index" should check onez_diag_count() first.
 */
size_t onez_diag_line(onez_t ctx, size_t index);

/*
 * Return the null-terminated name of the word the diagnostic at
 * `index` was reported against. Returns NULL on a null handle or
 * out-of-range index.
 *
 * The returned pointer is valid only until the next onez_check() call
 * on this handle. Hosts that need to retain diagnostic data across
 * checks must copy the string.
 */
const char *onez_diag_word(onez_t ctx, size_t index);

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

/*
 * Register library names that are statically linked into the executable.
 *
 * When `lib-open` encounters one of these names at runtime, it uses
 * dlopen(NULL) to access the main executable's symbol table instead of
 * loading a shared library. This enables AOT executables built with
 * --link-static=LIB to resolve FFI symbols without a runtime .so/.dylib.
 *
 * This is a single-shot, non-additive call: it replaces any previously
 * registered list rather than appending to it. Must be called before
 * running any 1z code.
 *
 * The name strings are copied; the caller retains ownership of the array
 * and its contents.
 */
int onez_set_static_libs(onez_t ctx, const char **names, unsigned int count);

/* ---- Debugger ---- */

/*
 * Activate the debugger. Allocates and attaches a debugger to the context.
 * If the debugger was previously disabled, re-attaches the existing instance
 * (preserving breakpoints and callbacks).
 *
 * Returns ONEZ_OK on success.
 */
int onez_debug_enable(onez_t ctx);

/*
 * Deactivate the debugger. Detaches from the context but preserves the
 * debugger instance so breakpoints and callbacks survive re-enable.
 *
 * Returns ONEZ_OK on success.
 * Returns ONEZ_ERR_DEBUGGER_NOT_ACTIVE if the debugger has not been enabled.
 */
int onez_debug_disable(onez_t ctx);

/*
 * Register or replace the debug event callback. May be called before or
 * after onez_debug_enable.
 *
 * The callback fires from within the execution loop when the debugger
 * pauses. The host calls stepping APIs (step_into, step_over, step_finish,
 * continue) from within the callback to control what happens next. When
 * the callback returns, execution resumes with whatever mode was set.
 *
 * Pass NULL to remove the callback.
 *
 * Returns ONEZ_OK on success.
 */
int onez_debug_set_callback(onez_t ctx, onez_debug_callback_fn callback, void *user_data);

/*
 * Set stepper mode to step_into. Pauses before the next instruction.
 *
 * Returns ONEZ_OK on success.
 * Returns ONEZ_ERR_DEBUGGER_NOT_ACTIVE if the debugger has not been enabled.
 */
int onez_debug_step_into(onez_t ctx);

/*
 * Set stepper mode to step_over. Pauses when returning to the current
 * call depth or shallower.
 *
 * Returns ONEZ_OK on success.
 * Returns ONEZ_ERR_DEBUGGER_NOT_ACTIVE if the debugger has not been enabled.
 */
int onez_debug_step_over(onez_t ctx);

/*
 * Set stepper mode to step_finish. Runs until the current word returns.
 *
 * Returns ONEZ_OK on success.
 * Returns ONEZ_ERR_DEBUGGER_NOT_ACTIVE if the debugger has not been enabled.
 */
int onez_debug_step_finish(onez_t ctx);

/*
 * Set stepper mode to continue. Runs until the next breakpoint or end.
 *
 * Returns ONEZ_OK on success.
 * Returns ONEZ_ERR_DEBUGGER_NOT_ACTIVE if the debugger has not been enabled.
 */
int onez_debug_continue(onez_t ctx);

/* ---- Breakpoints ---- */

/*
 * Add a word-name breakpoint. Pauses when the named word is executed.
 *
 * Returns a breakpoint ID (>= 1) on success, or 0 if the debugger is
 * not active, name is NULL, or allocation fails.
 */
unsigned int onez_breakpoint_add_word(onez_t ctx, const char *name);

/*
 * Add a source-location breakpoint. Pauses at the given file and line.
 *
 * Returns a breakpoint ID (>= 1) on success, or 0 on failure.
 */
unsigned int onez_breakpoint_add_source(onez_t ctx, const char *file,
                                        unsigned int file_len,
                                        unsigned int line);

/*
 * Add a conditional breakpoint. Pauses on the named word when the 1z
 * condition expression evaluates to true on a cloned stack.
 *
 * Returns a breakpoint ID (>= 1) on success, or 0 on failure.
 */
unsigned int onez_breakpoint_add_conditional(onez_t ctx, const char *word,
                                             const char *condition);

/*
 * Enable a breakpoint by ID.
 *
 * Returns ONEZ_OK on success.
 * Returns ONEZ_ERR_BREAKPOINT_NOT_FOUND if the ID does not exist.
 * Returns ONEZ_ERR_DEBUGGER_NOT_ACTIVE if the debugger has not been enabled.
 */
int onez_breakpoint_enable(onez_t ctx, unsigned int id);

/*
 * Disable a breakpoint by ID. Disabled breakpoints are retained but do
 * not trigger.
 *
 * Returns ONEZ_OK on success.
 * Returns ONEZ_ERR_BREAKPOINT_NOT_FOUND if the ID does not exist.
 * Returns ONEZ_ERR_DEBUGGER_NOT_ACTIVE if the debugger has not been enabled.
 */
int onez_breakpoint_disable(onez_t ctx, unsigned int id);

/*
 * Delete a breakpoint by ID. Permanently removes the breakpoint.
 *
 * Returns ONEZ_OK on success.
 * Returns ONEZ_ERR_BREAKPOINT_NOT_FOUND if the ID does not exist.
 * Returns ONEZ_ERR_DEBUGGER_NOT_ACTIVE if the debugger has not been enabled.
 */
int onez_breakpoint_delete(onez_t ctx, unsigned int id);

/* ---- Debug State Inspection ---- */

/*
 * Return the name of the word currently being executed.
 * Returns a null-terminated, library-owned string valid until the next
 * stepping command or onez_deinit.
 * Returns NULL if the debugger is not active or the call stack is empty.
 */
const char *onez_debug_current_word(onez_t ctx);

/*
 * Return the source location of the current instruction.
 * Writes the source file path (null-terminated, library-owned), line number,
 * and column number to the provided out-parameters.
 *
 * Returns ONEZ_OK on success.
 * Returns ONEZ_ERR_DEBUGGER_NOT_ACTIVE if the debugger has not been enabled.
 * Returns ONEZ_ERR_INDEX_OUT_OF_RANGE if the call stack is empty.
 */
int onez_debug_current_source(onez_t ctx, const char **out_file, unsigned int *out_line, unsigned int *out_col);

/*
 * Return the number of frames on the call stack.
 * Returns 0 if the debugger is not active or the handle is NULL.
 */
size_t onez_debug_frame_count(onez_t ctx);

/*
 * Return the word name at call stack frame `index` (0 = innermost).
 * Returns a null-terminated, library-owned string valid until the next
 * stepping command or onez_deinit.
 * Returns NULL if the debugger is not active or the index is out of range.
 */
const char *onez_debug_frame_word(onez_t ctx, size_t index);

/*
 * Return the source file at call stack frame `index` (0 = innermost).
 * Returns a null-terminated, library-owned string valid until the next
 * stepping command or onez_deinit.
 * Returns NULL if the debugger is not active or the index is out of range.
 */
const char *onez_debug_frame_file(onez_t ctx, size_t index);

/*
 * Return the source line number at call stack frame `index` (0 = innermost).
 * Returns -1 if the debugger is not active or the index is out of range.
 */
int onez_debug_frame_line(onez_t ctx, size_t index);

/*
 * Return the source column at call stack frame `index` (0 = innermost).
 * Returns -1 if the debugger is not active or the index is out of range.
 */
int onez_debug_frame_column(onez_t ctx, size_t index);

/*
 * Return the number of local bindings in the innermost local frame.
 * Returns 0 if the debugger is not active or there are no local frames.
 */
size_t onez_debug_local_count(onez_t ctx);

/*
 * Return the name of the local binding at `index` in the innermost frame.
 * Returns a null-terminated, library-owned string valid until the next
 * stepping command or onez_deinit.
 * Returns NULL if the debugger is not active or the index is out of range.
 */
const char *onez_debug_local_name(onez_t ctx, size_t index);

/*
 * Return the kind of the local binding at `index` in the innermost frame.
 * Returns ONEZ_LOCAL_COMPOUND (0) or ONEZ_LOCAL_NATIVE (1).
 * Returns -1 if the debugger is not active or the index is out of range.
 */
int onez_debug_local_kind(onez_t ctx, size_t index);

/*
 * Non-destructive read of the value at stack position `index` (0 = top).
 * Writes an onez_value_t handle to *out without popping the value.
 *
 * Returns ONEZ_OK on success.
 * Returns ONEZ_ERR_INDEX_OUT_OF_RANGE if index >= stack depth.
 */
int onez_stack_peek(onez_t ctx, size_t index, onez_value_t *out);

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
