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
