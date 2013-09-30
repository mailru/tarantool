/*
 * Redistribution and use in source and binary forms, with or
 * without modification, are permitted provided that the following
 * conditions are met:
 *
 * 1. Redistributions of source code must retain the above
 *    copyright notice, this list of conditions and the
 *    following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above
 *    copyright notice, this list of conditions and the following
 *    disclaimer in the documentation and/or other materials
 *    provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY <COPYRIGHT HOLDER> ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
 * <COPYRIGHT HOLDER> OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
 * BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
 * THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

#include <stdlib.h>

extern "C" {
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
} /* extern "C" */

#include "ipc.h"
#include "lua/ipc.h"
#include "lua/init.h"

static const char channel_lib[]   = "box.ipc.channel";

/******************** channel ***************************/

static int
lbox_ipc_channel(struct lua_State *L)
{
	lua_Integer size = 1;

	if (lua_gettop(L) > 0) {
		if (lua_gettop(L) != 1 || !lua_isnumber(L, 1))
			luaL_error(L, "fiber.channel(size): bad arguments");

		size = lua_tointeger(L, -1);
		if (size < 0)
			luaL_error(L, "box.channel(size): negative size");
	}
	struct ipc_channel *ch = ipc_channel_new(size);
	if (!ch)
		luaL_error(L, "box.channel: Not enough memory");

	void **ptr = (void **) lua_newuserdata(L, sizeof(void *));
	luaL_getmetatable(L, channel_lib);

	lua_pushstring(L, "rid");	/* first object id */
	lua_pushnumber(L, 1);
	lua_settable(L, -3);

	lua_setmetatable(L, -2);
	*ptr = ch;
	return 1;
}

static inline struct ipc_channel *
lbox_check_channel(struct lua_State *L, int narg)
{
	return *(struct ipc_channel **) luaL_checkudata(L, narg, channel_lib);
}

static int
lbox_ipc_channel_gc(struct lua_State *L)
{
	if (lua_gettop(L) != 1 || !lua_isuserdata(L, 1))
		return 0;
	struct ipc_channel *ch = lbox_check_channel(L, -1);
	ipc_channel_delete(ch);
	return 0;
}

static int
lbox_ipc_channel_is_full(struct lua_State *L)
{
	if (lua_gettop(L) != 1 || !lua_isuserdata(L, 1))
		luaL_error(L, "usage: channel:is_full()");
	struct ipc_channel *ch = lbox_check_channel(L, -1);
	lua_pushboolean(L, ipc_channel_is_full(ch));
	return 1;
}

static int
lbox_ipc_channel_is_empty(struct lua_State *L)
{
	if (lua_gettop(L) != 1 || !lua_isuserdata(L, 1))
		luaL_error(L, "usage: channel:is_empty()");
	struct ipc_channel *ch = lbox_check_channel(L, -1);
	lua_pushboolean(L, ipc_channel_is_empty(ch));
	return 1;
}

static int
lbox_ipc_channel_put(struct lua_State *L)
{
	ev_tstamp timeout = 0;
	int top = lua_gettop(L);
	struct ipc_channel *ch;

	switch (top) {
	case 2:
		timeout = TIMEOUT_INFINITY;
		break;
	case 3:
		if (!lua_isnumber(L, -1))
			luaL_error(L, "timeout must be a number");
		timeout = lua_tonumber(L, -1);
		if (timeout < 0)
			luaL_error(L, "wrong timeout");
		break;
	default:
		luaL_error(L, "usage: channel:put(var [, timeout])");
	}
	ch = lbox_check_channel(L, -top);

	lua_getmetatable(L, -top);

	lua_pushstring(L, "rid");
	lua_gettable(L, -2);

	lua_Integer rid = lua_tointeger(L, -1);
	if (rid < 0x7FFFFFFF)
		rid++;
	else
		rid = 1;

	lua_pushstring(L, "rid");	/* update object id */
	lua_pushnumber(L, rid);
	lua_settable(L, -4);

	lua_pushnumber(L, rid);
	lua_pushvalue(L, 2);
	lua_settable(L, -4);


	int retval;
	if (ipc_channel_put_timeout(ch, (void *)rid, timeout) == 0) {
		retval = 1;
	} else {
		/* put timeout */
		retval = 0;
		lua_pushnumber(L, rid);
		lua_pushnil(L);
		lua_settable(L, -4);
	}

	lua_settop(L, top);
	lua_pushboolean(L, retval);
	return 1;
}

static int
lbox_ipc_channel_get(struct lua_State *L)
{
	int top = lua_gettop(L);
	ev_tstamp timeout;

	if (top > 2 || top < 1 || !lua_isuserdata(L, -top))
		luaL_error(L, "usage: channel:get([timeout])");

	if (top == 2) {
		if (!lua_isnumber(L, 2))
			luaL_error(L, "timeout must be a number");
		timeout = lua_tonumber(L, 2);
		if (timeout < 0)
			luaL_error(L, "wrong timeout");
	} else {
		timeout = TIMEOUT_INFINITY;
	}

	struct ipc_channel *ch = lbox_check_channel(L, 1);

	lua_Integer rid = (lua_Integer)ipc_channel_get_timeout(ch, timeout);

	if (!rid) {
		lua_pushnil(L);
		return 1;
	}

	lua_getmetatable(L, 1);

	lua_pushstring(L, "broadcast_message");
	lua_gettable(L, -2);

	if (lua_isnil(L, -1)) {	/* common messages */
		lua_pop(L, 1);		/* nil */

		lua_pushnumber(L, rid);		/* extract and delete value */
		lua_gettable(L, -2);

		lua_pushnumber(L, rid);
		lua_pushnil(L);
		lua_settable(L, -4);
	}

	lua_remove(L, -2);	/* cleanup stack (metatable) */
	return 1;
}

static int
lbox_ipc_channel_broadcast(struct lua_State *L)
{
	struct ipc_channel *ch;

	if (lua_gettop(L) != 2)
		luaL_error(L, "usage: channel:broadcast(variable)");

	ch = lbox_check_channel(L, -2);

	if (!ipc_channel_has_readers(ch))
		return lbox_ipc_channel_put(L);

	lua_getmetatable(L, -2);			/* 3 */

	lua_pushstring(L, "broadcast_message");		/* 4 */

	/* save old value */
	lua_pushstring(L, "broadcast_message");
	lua_gettable(L, 3);				/* 5 */

	lua_pushstring(L, "broadcast_message");		/* save object */
	lua_pushvalue(L, 2);
	lua_settable(L, 3);

	int count = ipc_channel_broadcast(ch, (void *)1);

	lua_settable(L, 3);

	lua_pop(L, 1);		/* stack cleanup */
	lua_pushnumber(L, count);

	return 1;
}

static int
lbox_ipc_channel_has_readers(struct lua_State *L)
{
	if (lua_gettop(L) != 1)
		luaL_error(L, "usage: channel:has_readers()");
	struct ipc_channel *ch = lbox_check_channel(L, -1);
	lua_pushboolean(L, ipc_channel_has_readers(ch));
	return 1;
}

static int
lbox_ipc_channel_has_writers(struct lua_State *L)
{
	if (lua_gettop(L) != 1)
		luaL_error(L, "usage: channel:has_writers()");
	struct ipc_channel *ch = lbox_check_channel(L, -1);
	lua_pushboolean(L, ipc_channel_has_writers(ch));
	return 1;
}

void
tarantool_lua_ipc_init(struct lua_State *L)
{
	static const struct luaL_reg channel_meta[] = {
		{"__gc",	lbox_ipc_channel_gc},
		{"is_full",	lbox_ipc_channel_is_full},
		{"is_empty",	lbox_ipc_channel_is_empty},
		{"put",		lbox_ipc_channel_put},
		{"get",		lbox_ipc_channel_get},
		{"broadcast",	lbox_ipc_channel_broadcast},
		{"has_readers",	lbox_ipc_channel_has_readers},
		{"has_writers",	lbox_ipc_channel_has_writers},
		{NULL, NULL}
	};
	tarantool_lua_register_type(L, channel_lib, channel_meta);

	static const struct luaL_reg ipc_meta[] = {
		{"channel",	lbox_ipc_channel},
		{NULL, NULL}
	};


	lua_getfield(L, LUA_GLOBALSINDEX, "box");

	lua_pushstring(L, "ipc");
	lua_newtable(L);			/* box.ipc table */
	luaL_register(L, NULL, ipc_meta);
	lua_settable(L, -3);
	lua_pop(L, 1);
}

