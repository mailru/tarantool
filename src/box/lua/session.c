/*
 * Copyright 2010-2016, Tarantool AUTHORS, please see AUTHORS file.
 *
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
#include "session.h"
#include "lua/utils.h"
#include "lua/trigger.h"

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <sio.h>

#include "box/box.h"
#include "box/session.h"
#include "box/user.h"

static const char *sessionlib_name = "box.session";

/* Create session and pin it to fiber */
static int
lbox_session_create(struct lua_State *L)
{
	struct session *session = fiber_get_session(fiber());
	if (session == NULL) {
		int fd = luaL_optinteger(L, 1, -1);
		session = session_create_on_demand(fd);
		if (session == NULL)
			return luaT_error(L);
	}
	/* If a session already exists, simply reset its type */
	session->type = STR2ENUM(session_type, luaL_optstring(L, 2, "console"));

	lua_pushnumber(L, session->id);
	return 1;
}

/**
 * Return a unique monotonic session
 * identifier. The identifier can be used
 * to check whether or not a session is alive.
 * 0 means there is no session (e.g.
 * a procedure is running in a detached
 * fiber).
 */
static int
lbox_session_id(struct lua_State *L)
{
	lua_pushnumber(L, current_session()->id);
	return 1;
}

/**
 * Return session type: one of "binary", "console",
 * "replication", "background"
 */
static int
lbox_session_type(struct lua_State *L)
{
	lua_pushstring(L, session_type_strs[current_session()->type]);
	return 1;
}

/**
 * Return the id of currently executed request.
 * Many requests share the same session so this is only
 * valid at session start. 0 for non-iproto sessions.
 */
static int
lbox_session_sync(struct lua_State *L)
{
	lua_pushnumber(L, current_session()->sync);
	return 1;
}

/**
 * Session user id.
 * Note: effective user id (current_user()->uid)
 * may be different in a setuid function.
 */
static int
lbox_session_uid(struct lua_State *L)
{
	/*
	 * Sic: push session user, not the current user,
	 * which may differ inside a setuid function.
	 */
	lua_pushnumber(L, current_session()->credentials.uid);
	return 1;
}

/**
 * Session user name.
 * Note: effective user name may be different in
 * a setuid function.
 */
static int
lbox_session_user(struct lua_State *L)
{
	struct user *user = user_by_id(current_user()->uid);
	if (user)
		lua_pushstring(L, user->def->name);
	else
		lua_pushnil(L);
	return 1;
}

/** Session user id. */
static int
lbox_session_su(struct lua_State *L)
{
	if (!box_is_configured())
		luaL_error(L, "Please call box.cfg{} first");
	int top = lua_gettop(L);
	if (top < 1)
		luaL_error(L, "session.su(): bad arguments");
	struct session *session = current_session();
	if (session == NULL)
		luaL_error(L, "session.su(): session does not exist");
	struct user *user;
	if (lua_type(L, 1) == LUA_TSTRING) {
		size_t len;
		const char *name = lua_tolstring(L, 1, &len);
		user = user_find_by_name(name, len);
	} else {
		user = user_find(lua_tonumber(L, 1));
	}
	if (user == NULL)
		luaT_error(L);
	if (top == 1) {
		credentials_init(&session->credentials, user->auth_token,
				 user->def->uid);
		fiber_set_user(fiber(), &session->credentials);
		return 0; /* su */
	}

	struct credentials su_credentials;
	credentials_init(&su_credentials, user->auth_token, user->def->uid);
	fiber_set_user(fiber(), &su_credentials);

	/* sudo */
	luaL_checktype(L, 2, LUA_TFUNCTION);
	int error = lua_pcall(L, top - 2, LUA_MULTRET, 0);
	fiber_set_user(fiber(), &session->credentials);

	if (error)
		luaT_error(L);
	return lua_gettop(L) - 1;
}

/**
 * Check whether or not a session exists.
 */
static int
lbox_session_exists(struct lua_State *L)
{
	if (lua_gettop(L) != 1)
		luaL_error(L, "session.exists(sid): bad arguments");

	uint64_t sid = luaL_checkint64(L, -1);
	lua_pushboolean(L, session_find(sid) != NULL);
	return 1;
}

/**
 * Check whether or not a session exists.
 */
static int
lbox_session_fd(struct lua_State *L)
{
	if (lua_gettop(L) != 1)
		luaL_error(L, "session.fd(sid): bad arguments");

	uint64_t sid = luaL_checkint64(L, -1);
	struct session *session = session_find(sid);
	if (session == NULL)
		luaL_error(L, "session.fd(): session does not exist");
	lua_pushinteger(L, session->fd);
	return 1;
}


/**
 * Pretty print peer name.
 */
static int
lbox_session_peer(struct lua_State *L)
{
	if (lua_gettop(L) > 1)
		luaL_error(L, "session.peer(sid): bad arguments");

	int fd;
	struct session *session;
	if (lua_gettop(L) == 1)
		session = session_find(luaL_checkint(L, 1));
	else
		session = current_session();
	if (session == NULL)
		luaL_error(L, "session.peer(): session does not exist");
	fd = session->fd;
	if (fd < 0) {
		lua_pushnil(L); /* no associated peer */
		return 1;
	}

	struct sockaddr_storage addr;
	socklen_t addrlen = sizeof(addr);
	if (sio_getpeername(fd, (struct sockaddr *)&addr, &addrlen) < 0)
		luaL_error(L, "session.peer(): getpeername() failed");

	lua_pushstring(L, sio_strfaddr((struct sockaddr *)&addr, addrlen));
	return 1;
}

/**
 * run on_connect|on_disconnect trigger
 */
static int
lbox_push_on_connect_event(struct lua_State *L, void *event)
{
	(void) L;
	(void) event;
	return 0;
}

static int
lbox_push_on_auth_event(struct lua_State *L, void *event)
{
	lua_pushstring(L, (const char *)event);
	return 1;
}

static int
lbox_session_on_connect(struct lua_State *L)
{
	return lbox_trigger_reset(L, 2, &session_on_connect,
				  lbox_push_on_connect_event);
}

static int
lbox_session_run_on_connect(struct lua_State *L)
{
	struct session *session = current_session();
	if (session_run_on_connect_triggers(session) != 0)
		return luaT_error(L);
	return 0;
}

static int
lbox_session_on_disconnect(struct lua_State *L)
{
	return lbox_trigger_reset(L, 2, &session_on_disconnect,
				  lbox_push_on_connect_event);
}

static int
lbox_session_run_on_disconnect(struct lua_State *L)
{
	struct session *session = current_session();
	session_run_on_disconnect_triggers(session);
	(void) L;
	return 0;
}

static int
lbox_session_on_auth(struct lua_State *L)
{
	return lbox_trigger_reset(L, 2, &session_on_auth,
				  lbox_push_on_auth_event);
}

static int
lbox_session_run_on_auth(struct lua_State *L)
{
	const char *username = luaL_optstring(L, 1, "");
	if (session_run_on_auth_triggers(username) != 0)
		return luaT_error(L);
	return 0;
}

void
session_storage_cleanup(int sid)
{
	static int ref = LUA_REFNIL;
	struct lua_State *L = tarantool_L;

	int top = lua_gettop(L);

	if (ref == LUA_REFNIL) {
		lua_getfield(L, LUA_REGISTRYINDEX, "_LOADED");
		if (!lua_istable(L, -1))
			goto exit;
		lua_getfield(L, -1, "session");
		if (!lua_istable(L, -1))
			goto exit;
		lua_getmetatable(L, -1);
		if (!lua_istable(L, -1))
			goto exit;
		lua_getfield(L, -1, "aggregate_storage");
		if (!lua_istable(L, -1))
			goto exit;
		ref = luaL_ref(L, LUA_REGISTRYINDEX);
	}
	lua_rawgeti(L, LUA_REGISTRYINDEX, ref);

	lua_pushnil(L);
	lua_rawseti(L, -2, sid);
exit:
	lua_settop(L, top);
}

void
box_lua_session_init(struct lua_State *L)
{
	static const struct luaL_Reg session_internal_lib[] = {
		{"create", lbox_session_create},
		{"run_on_connect",    lbox_session_run_on_connect},
		{"run_on_disconnect", lbox_session_run_on_disconnect},
		{"run_on_auth", lbox_session_run_on_auth},
		{NULL, NULL}
	};
	luaL_register(L, "box.internal.session", session_internal_lib);
	lua_pop(L, 1);

	static const struct luaL_Reg sessionlib[] = {
		{"id", lbox_session_id},
		{"type", lbox_session_type},
		{"sync", lbox_session_sync},
		{"uid", lbox_session_uid},
		{"user", lbox_session_user},
		{"su", lbox_session_su},
		{"fd", lbox_session_fd},
		{"exists", lbox_session_exists},
		{"peer", lbox_session_peer},
		{"on_connect", lbox_session_on_connect},
		{"on_disconnect", lbox_session_on_disconnect},
		{"on_auth", lbox_session_on_auth},
		{NULL, NULL}
	};
	luaL_register_module(L, sessionlib_name, sessionlib);
	lua_pop(L, 1);
}
