/* Local shim compiled into liblua5.4 alongside the vendored sources; not part
 * of upstream Lua. See VENDORING.md "Local-only files". */

#include "lua.h"

/* ffi-callback error hook for lib/lua.1z's registered callbacks. Invoked from
 * the trampoline's boundary frame after the Zig stack has unwound, so the
 * lua_error longjmp back into the driving lua_pcallk skips no live 1z frames.
 * Never returns. */
void onez_lua_error_hook(void *state, void *userdata, const char *message) {
    (void)userdata;
    lua_State *L = (lua_State *)state;
    lua_pushstring(L, message);
    lua_error(L);
}
