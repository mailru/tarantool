/*
 * Copyright 2010-2021, Tarantool AUTHORS, please see AUTHORS file.
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
#include "iproto_thread.h"

#include <lua/utils.h>
#include <uri/uri.h>

#include "box/error.h"
#include "box/iproto.h"

static bool
iproto_thread_check_uri(const char *source)
{
	struct uri uri;
	/* URI format is [host:]service */
	if (source == NULL || uri_parse(&uri, source) || !uri.service) {
		diag_set(ClientError, ER_CFG, "listen",
			 "expected host:service or /unix.socket");
		return false;
	}
	return true;
}

static int
iproto_thread_check_idx(struct lua_State *L)
{
	if (lua_gettop(L) != 1)
		return luaL_error(L, "Usage: iproto_thread.check_idx(idx)");
	int64_t idx = luaL_toint64(L, 1);
	if (! iproto_check_thread_idx(idx))
		return luaL_error(L, "Invalid iproto thread index");
	return 0;
}

static int
iproto_thread_listen(struct lua_State *L)
{
	if (lua_gettop(L) != 2)
		return luaL_error(L, "Usage: iproto_thread.iproto_thread_listen(uri)");
	int64_t idx = luaL_toint64(L, 1);
	const char *uri = lua_tostring(L, 2);
	if (! iproto_thread_check_uri(uri))
		luaT_error(L);
	iproto_listen(uri, idx);
	return 0;
}

int
luaopen_iproto_thread(struct lua_State *L)
{
	static const luaL_Reg iproto_thread_lib[] = {
		{ "check_idx", iproto_thread_check_idx },
		{ "listen", iproto_thread_listen },
		{ NULL, NULL}
	};
	luaL_register_module(L, "iproto_thread", iproto_thread_lib);
	return 1;
}
