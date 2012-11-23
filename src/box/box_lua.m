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
#include "box_lua.h"
#include "lua/init.h"
#include <fiber.h>
#include "box.h"
#include "request.h"
#include "txn.h"

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "lj_obj.h"
#include "lj_ctype.h"
#include "lj_cdata.h"
#include "lj_cconv.h"

#include "pickle.h"
#include "tuple.h"
#include "space.h"
#include "index.h"
#include "port.h"

/* contents of box.lua */
extern const char box_lua[];

/**
 * All box connections share the same Lua state. We use
 * Lua coroutines (lua_newthread()) to have multiple
 * procedures running at the same time.
 */
static lua_State *root_L;

/*
 * Functions, exported in box_lua.h should have prefix
 * "box_lua_"; functions, available in Lua "box"
 * should start with "lbox_".
 */

/** {{{ box.tuple Lua library
 *
 * To avoid extra copying between Lua memory and garbage-collected
 * tuple memory, provide a Lua userdata object 'box.tuple'.  This
 * object refers to a tuple instance in the slab allocator, and
 * allows accessing it using Lua primitives (array subscription,
 * iteration, etc.). When Lua object is garbage-collected,
 * tuple reference counter in the slab allocator is decreased,
 * allowing the tuple to be eventually garbage collected in
 * the slab allocator.
 */

static const char *tuplelib_name = "box.tuple";

static void
lbox_pushtuple(struct lua_State *L, struct tuple *tuple);

static inline struct tuple *
lua_checktuple(struct lua_State *L, int narg)
{
	struct tuple *t = *(void **) luaL_checkudata(L, narg, tuplelib_name);
	assert(t->refs);
	return t;
}

struct tuple *
lua_istuple(struct lua_State *L, int narg)
{
	if (lua_getmetatable(L, narg) == 0)
		return NULL;
	luaL_getmetatable(L, tuplelib_name);
	struct tuple *tuple = 0;
	if (lua_equal(L, -1, -2))
		tuple = * (void **) lua_touserdata(L, narg);
	lua_pop(L, 2);
	return tuple;
}

static int
lbox_tuple_gc(struct lua_State *L)
{
	struct tuple *tuple = lua_checktuple(L, 1);
	tuple_ref(tuple, -1);
	return 0;
}

static int
lbox_tuple_len(struct lua_State *L)
{
	struct tuple *tuple = lua_checktuple(L, 1);
	lua_pushnumber(L, tuple->field_count);
	return 1;
}

static int
lbox_tuple_slice(struct lua_State *L)
{
	struct tuple *tuple = lua_checktuple(L, 1);
	int argc = lua_gettop(L) - 1;
	int start, end;

	/*
	 * Prepare the range. The second argument is optional.
	 * If the end is beyond tuple size, adjust it.
	 * If no arguments, or start > end, return an error.
	 */
	if (argc == 0 || argc > 2)
		luaL_error(L, "tuple.slice(): bad arguments");
	start = lua_tointeger(L, 2);
	if (start < 0)
		start += tuple->field_count;
	if (argc == 2) {
		end = lua_tointeger(L, 3);
		if (end < 0)
			end += tuple->field_count;
		else if (end > tuple->field_count)
			end = tuple->field_count;
	} else {
		end = tuple->field_count;
	}
	if (end <= start)
		luaL_error(L, "tuple.slice(): start must be less than end");

	u8 *field = tuple->data;
	int fieldno = 0;
	int stop = end - 1;

	while (field < tuple->data + tuple->bsize) {
		size_t len = load_varint32((void **) &field);
		if (fieldno >= start) {
			lua_pushlstring(L, (char *) field, len);
			if (fieldno == stop)
				break;
		}
		field += len;
		fieldno += 1;
	}
	return end - start;
}


/**
 * Given a tuple, range of fields to remove (start and end field
 * numbers), and a list of fields to paste, calculate the size of
 * the resulting tuple.
 *
 * @param L      lua stack, contains a list of arguments to paste
 * @param start  offset in the lua stack where paste arguments start
 * @param tuple  old tuple
 * @param offset cut field offset
 * @param len    how many fields to cut
 * @param[out]   sizes of the left and right part
 *
 * @return size of the new tuple
*/
static size_t
transform_calculate(struct lua_State *L, struct tuple *tuple,
		    int start, int argc, int offset, int len,
		    size_t lr[2])
{
	/* calculate size of the new tuple */
	void *tuple_end = tuple->data + tuple->bsize;
	void *tuple_field = tuple->data;

	lr[0] = tuple_range_size(&tuple_field, tuple_end, offset);

	/* calculate sizes of supplied fields */
	size_t mid = 0;
	for (int i = start ; i <= argc ; i++) {
		switch (lua_type(L, i)) {
		case LUA_TNUMBER:
			mid += varint32_sizeof(sizeof(u32)) + sizeof(u32);
			break;
		case LUA_TCDATA:
			mid += varint32_sizeof(sizeof(u64)) + sizeof(u64);
			break;
		case LUA_TSTRING: {
			size_t field_size = lua_objlen(L, i);
			mid += varint32_sizeof(field_size) + field_size;
			break;
		}
		default:
			luaL_error(L, "tuple.transform(): unsupported field type '%s'",
				   lua_typename(L, lua_type(L, i)));
			break;
		}
	}

	/* calculate size of the removed fields */
	tuple_range_size(&tuple_field, tuple_end, len);

	/* calculate last part of the tuple fields */
	lr[1] = tuple_end - tuple_field;

	return lr[0] + mid + lr[1];
}

static inline void
transform_set_field(u8 **ptr, const void *data, size_t size)
{
	*ptr = save_varint32(*ptr, size);
	memcpy(*ptr, data, size);
	*ptr += size;
}

/**
 * Tuple transforming function.
 *
 * Remove the fields designated by 'offset' and 'len' from an tuple,
 * and replace them with the elements of supplied data fields,
 * if any.
 *
 * Function returns newly allocated tuple.
 * It does not change any parent tuple data.
 */
static int
lbox_tuple_transform(struct lua_State *L)
{
	struct tuple *tuple = lua_checktuple(L, 1);
	int argc = lua_gettop(L);
	if (argc < 3)
		luaL_error(L, "tuple.transform(): bad arguments");
	int offset = lua_tointeger(L, 2);
	int len = lua_tointeger(L, 3);

	/* validate offset and len */
	if (offset < 0) {
		if (-offset > tuple->field_count)
			luaL_error(L, "tuple.transform(): offset is out of bound");
		offset += tuple->field_count;
	} else if (offset > tuple->field_count) {
		offset = tuple->field_count;
	}
	if (len < 0)
		luaL_error(L, "tuple.transform(): len is negative");
	if (len > tuple->field_count - offset)
		len = tuple->field_count - offset;

	/* calculate size of the new tuple */
	size_t lr[2]; /* left and right part sizes */
	size_t size = transform_calculate(L, tuple, 4, argc, offset, len, lr);

	/* allocate new tuple */
	struct tuple *dest = tuple_alloc(size);
	dest->field_count = (tuple->field_count - len) + (argc - 3);

	/* construct tuple */
	memcpy(dest->data, tuple->data, lr[0]);
	u8 *ptr = dest->data + lr[0];
	for (int i = 4; i <= argc; i++) {
		switch (lua_type(L, i)) {
		case LUA_TNUMBER: {
			u32 v = lua_tonumber(L, i);
			transform_set_field(&ptr, &v, sizeof(v));
			break;
		}
		case LUA_TCDATA: {
			u64 v = tarantool_lua_tointeger64(L, i);
			transform_set_field(&ptr, &v, sizeof(v));
			break;
		}
		case LUA_TSTRING: {
			size_t field_size = 0;
			const char *v = luaL_checklstring(L, i, &field_size);
			transform_set_field(&ptr, v, field_size);
			break;
		}
		default:
			/* default type check is done in transform_calculate()
			 * function */
			break;
		}
	}
	memcpy(ptr, tuple_field(tuple, offset + len), lr[1]);

	lbox_pushtuple(L, dest);
	return 1;
}

/*
 * Tuple find function.
 *
 * Find each or one tuple field according to the specified key.
 *
 * Function returns indexes of the tuple fields that match
 * key criteria.
 *
 */
static int
tuple_find(struct lua_State *L, struct tuple *tuple, size_t offset,
	   const char *key, size_t key_size,
	   bool all)
{
	int top = lua_gettop(L);
	int idx = offset;
	if (idx >= tuple->field_count)
		return 0;
	u8 *field = tuple_field(tuple, idx);
	while (field < tuple->data + tuple->bsize) {
		size_t len = load_varint32((void **) &field);
		if (len == key_size && (memcmp(field, key, len) == 0)) {
			lua_pushinteger(L, idx);
			if (!all)
				break;
		}
		field += len;
		idx++;
	}
	return lua_gettop(L) - top;
}

static int
lbox_tuple_find_do(struct lua_State *L, bool all)
{
	struct tuple *tuple = lua_checktuple(L, 1);
	int argc = lua_gettop(L);
	size_t offset = 0;
	switch (argc - 1) {
	case 1: break;
	case 2:
		offset = lua_tointeger(L, 2);
		break;
	default:
		luaL_error(L, "tuple.find(): bad arguments");
	}
	size_t key_size = 0;
	const char *key = NULL;
	u32 u32v;
	u64 u64v;
	switch (lua_type(L, argc)) {
	case LUA_TNUMBER:
		u32v = lua_tonumber(L, argc);
		key_size = sizeof(u32);
		key = (const char*)&u32v;
		break;
	case LUA_TCDATA:
		u64v = tarantool_lua_tointeger64(L, argc);
		key_size = sizeof(u64);
		key = (const char*)&u64v;
		break;
	case LUA_TSTRING:
		key = luaL_checklstring(L, argc, &key_size);
		break;
	default:
		luaL_error(L, "tuple.find(): bad field type");
	}
	return tuple_find(L, tuple, offset, key, key_size, all);
}

static int
lbox_tuple_find(struct lua_State *L)
{
	return lbox_tuple_find_do(L, false);
}

static int
lbox_tuple_findall(struct lua_State *L)
{
	return lbox_tuple_find_do(L, true);
}

static int
lbox_tuple_unpack(struct lua_State *L)
{
	struct tuple *tuple = lua_checktuple(L, 1);
	u8 *field = tuple->data;

	while (field < tuple->data + tuple->bsize) {
		size_t len = load_varint32((void **) &field);
		lua_pushlstring(L, (char *) field, len);
		field += len;
	}
	assert(lua_gettop(L) == tuple->field_count + 1);
	return tuple->field_count;
}

/**
 * Implementation of tuple __index metamethod.
 *
 * Provides operator [] access to individual fields for integer
 * indexes, as well as searches and invokes metatable methods
 * for strings.
 */
static int
lbox_tuple_index(struct lua_State *L)
{
	struct tuple *tuple = lua_checktuple(L, 1);
	/* For integer indexes, implement [] operator */
	if (lua_isnumber(L, 2)) {
		int i = luaL_checkint(L, 2);
		if (i >= tuple->field_count)
			luaL_error(L, "%s: index %d is out of bounds (0..%d)",
				   tuplelib_name, i, tuple->field_count-1);
		void *field = tuple_field(tuple, i);
		u32 len = load_varint32(&field);
		lua_pushlstring(L, field, len);
		return 1;
	}
	/* If we got a string, try to find a method for it. */
	lua_getmetatable(L, 1);
	lua_getfield(L, -1, lua_tostring(L, 2));
	return 1;
}

static int
lbox_tuple_tostring(struct lua_State *L)
{
	struct tuple *tuple = lua_checktuple(L, 1);
	/* @todo: print the tuple */
	struct tbuf *tbuf = tbuf_alloc(fiber->gc_pool);
	tuple_print(tbuf, tuple->field_count, tuple->data);
	lua_pushlstring(L, tbuf->data, tbuf->size);
	return 1;
}

static void
lbox_pushtuple(struct lua_State *L, struct tuple *tuple)
{
	if (tuple) {
		void **ptr = lua_newuserdata(L, sizeof(void *));
		luaL_getmetatable(L, tuplelib_name);
		lua_setmetatable(L, -2);
		*ptr = tuple;
		tuple_ref(tuple, 1);
	} else {
		lua_pushnil(L);
	}
}

/**
 * Sequential access to tuple fields. Since tuple is a list-like
 * structure, iterating over tuple fields is faster
 * than accessing fields using an index.
 */
static int
lbox_tuple_next(struct lua_State *L)
{
	struct tuple *tuple = lua_checktuple(L, 1);
	int argc = lua_gettop(L) - 1;
	u8 *field = NULL;
	size_t len;

	if (argc == 0 || (argc == 1 && lua_type(L, 2) == LUA_TNIL))
		field = tuple->data;
	else if (argc == 1 && lua_islightuserdata(L, 2))
		field = lua_touserdata(L, 2);
	else
		luaL_error(L, "tuple.next(): bad arguments");

	(void)field;
	assert(field >= tuple->data);
	if (field < tuple->data + tuple->bsize) {
		len = load_varint32((void **) &field);
		lua_pushlightuserdata(L, field + len);
		lua_pushlstring(L, (char *) field, len);
		return 2;
	}
	lua_pushnil(L);
	return  1;
}

/** Iterator over tuple fields. Adapt lbox_tuple_next
 * to Lua iteration conventions.
 */
static int
lbox_tuple_pairs(struct lua_State *L)
{
	lua_pushcfunction(L, lbox_tuple_next);
	lua_pushvalue(L, -2); /* tuple */
	lua_pushnil(L);
	return 3;
}

static const struct luaL_reg lbox_tuple_meta [] = {
	{"__gc", lbox_tuple_gc},
	{"__len", lbox_tuple_len},
	{"__index", lbox_tuple_index},
	{"__tostring", lbox_tuple_tostring},
	{"next", lbox_tuple_next},
	{"pairs", lbox_tuple_pairs},
	{"slice", lbox_tuple_slice},
	{"transform", lbox_tuple_transform},
	{"find", lbox_tuple_find},
	{"findall", lbox_tuple_findall},
	{"unpack", lbox_tuple_unpack},
	{NULL, NULL}
};

/* }}} */

/** {{{ box.index Lua library: access to spaces and indexes
 */

static const char *indexlib_name = "box.index";
static const char *iteratorlib_name = "box.index.iterator";

static struct iterator *
lua_checkiterator(struct lua_State *L, int i)
{
	struct iterator **it = luaL_checkudata(L, i, iteratorlib_name);
	assert(it != NULL);
	return *it;
}

static void
lbox_pushiterator(struct lua_State *L, struct iterator *it)
{
	void **ptr = lua_newuserdata(L, sizeof(void *));
	luaL_getmetatable(L, iteratorlib_name);
	lua_setmetatable(L, -2);
	*ptr = it;
}

static int
lbox_iterator_gc(struct lua_State *L)
{
	struct iterator *it = lua_checkiterator(L, -1);
	it->free(it);
	return 0;
}

static Index *
lua_checkindex(struct lua_State *L, int i)
{
	Index **index = luaL_checkudata(L, i, indexlib_name);
	assert(index != NULL);
	return *index;
}

static int
lbox_index_new(struct lua_State *L)
{
	int n = luaL_checkint(L, 1); /* get space id */
	int idx = luaL_checkint(L, 2); /* get index id in */
	/* locate the appropriate index */
	struct space *sp = space_find(n);
	Index *index = index_find(sp, idx);

	/* create a userdata object */
	void **ptr = lua_newuserdata(L, sizeof(void *));
	*ptr = index;
	/* set userdata object metatable to indexlib */
	luaL_getmetatable(L, indexlib_name);
	lua_setmetatable(L, -2);

	return 1;
}

static int
lbox_index_tostring(struct lua_State *L)
{
	Index *index = lua_checkindex(L, 1);
	lua_pushfstring(L, "index %d in space %d",
			index_n(index), space_n(index->space));
	return 1;
}

static int
lbox_index_len(struct lua_State *L)
{
	Index *index = lua_checkindex(L, 1);
	lua_pushinteger(L, [index size]);
	return 1;
}

static int
lbox_index_part_count(struct lua_State *L)
{
	Index *index = lua_checkindex(L, 1);
	lua_pushinteger(L, index->key_def->part_count);
	return 1;
}

static int
lbox_index_min(struct lua_State *L)
{
	Index *index = lua_checkindex(L, 1);
	lbox_pushtuple(L, [index min]);
	return 1;
}

static int
lbox_index_max(struct lua_State *L)
{
	Index *index = lua_checkindex(L, 1);
	lbox_pushtuple(L, [index max]);
	return 1;
}

/**
 * Convert an element on Lua stack to a part of an index
 * key.
 *
 * Lua type system has strings, numbers, booleans, tables,
 * userdata objects. Tarantool indexes only support 32/64-bit
 * integers and strings.
 *
 * Instead of considering each Tarantool <-> Lua type pair,
 * here we follow the approach similar to one in lbox_pack()
 * (see tarantool_lua.m):
 *
 * Lua numbers are converted to 32 or 64 bit integers,
 * if key part is integer. In all other cases,
 * Lua types are converted to Lua strings, and these
 * strings are used as key parts.
 */

void append_key_part(struct lua_State *L, int i,
		     struct tbuf *tbuf, enum field_data_type type)
{
	const char *str;
	size_t size;
	u32 v_u32;
	u64 v_u64;

	if (lua_type(L, i) == LUA_TNUMBER) {
		if (type == NUM64) {
			v_u64 = (u64) lua_tonumber(L, i);
			str = (char *) &v_u64;
			size = sizeof(u64);
		} else {
			v_u32 = (u32) lua_tointeger(L, i);
			str = (char *) &v_u32;
			size = sizeof(u32);
		}
	} else {
		str = luaL_checklstring(L, i, &size);
	}
	write_varint32(tbuf, size);
	tbuf_append(tbuf, str, size);
}

static int
lbox_index_iter_closure(struct lua_State *L);

/**
 * @brief Lua iterator over a Taratnool/Box index.
 * @example lua iter = box.space[0].index[0]:iterator(box.index.ITER_GE, 1);
 *   print(iter(), iter()).
 * @param L lua stack
 * @see http://www.lua.org/pil/7.1.html
 * @return number of return values put on the stack
 */
static int
lbox_index_iterator(struct lua_State *L)
{
	Index *index = lua_checkindex(L, 1);
	int argc = lua_gettop(L) - 1;

	enum iteration_strategy strategy;
	if (argc > 0) {
		/* first parameter must be iterator flags */
		strategy = (enum iteration_strategy) luaL_checkint(L, 2);
	} else {
		strategy = ITER_ALL;
	}

	void *key = NULL;
	int field_count = 0;

	if (argc == 2 && lua_istuple(L, 3)) {
		/* Searching by tuple. */
		struct tuple *tuple = lua_checktuple(L, 3);
		key = tuple->data;
		field_count = tuple->field_count;
	} else if (argc == 2 && lua_isnil(L, 3)) {
		key = NULL;
		field_count = 0;
	} else if (argc >= 2) {
		/* Single or multi- part key. */
		field_count = argc - 1;
		struct tbuf *data = tbuf_alloc(fiber->gc_pool);
			for (int i = 0; i < field_count; ++i)
				append_key_part(L, i + 3, data,
						index->key_def->parts[i].type);
		key = data->data;
	}

	struct iterator *it = [index allocIterator];
	[index initIterator: it :strategy :key :field_count];
	lbox_pushiterator(L, it);

	lua_pushcclosure(L, &lbox_index_iter_closure, 1);
	return 1;
}

static int
lbox_index_iter_closure(struct lua_State *L)
{
	/* extract closure arguments */
	struct iterator *it = lua_checkiterator(L, lua_upvalueindex(1));

	struct tuple *tuple = it->next(it);

	/* If tuple is NULL, pushes nil as end indicator. */
	lbox_pushtuple(L, tuple);
	return 1;
}

/**
 * Lua index subtree count function.
 * Iterate over an index, count the number of tuples which equal the
 * provided search criteria. The argument can either point to a
 * tuple, a key, or one or more key parts. Returns the number of matched
 * tuples.
 */
static int
lbox_index_count(struct lua_State *L)
{
	Index *index = lua_checkindex(L, 1);
	int argc = lua_gettop(L) - 1;
	if (argc == 0)
		luaL_error(L, "index.count(): one or more arguments expected");
	/* preparing single or multi-part key */
	void *key;
	int key_part_count;
	if (argc == 1 && lua_type(L, 2) == LUA_TUSERDATA) {
		/* Searching by tuple. */
		struct tuple *tuple = lua_checktuple(L, 2);
		key = tuple->data;
		key_part_count = tuple->field_count;
	} else {
		/* Single or multi- part key. */
		key_part_count = argc;
		struct tbuf *data = tbuf_alloc(fiber->gc_pool);
		for (int i = 0; i < argc; ++i)
			append_key_part(L, i + 2, data,
					index->key_def->parts[i].type);
		key = data->data;
	}
	u32 count = 0;
	/* preparing index iterator */
	struct iterator *it = index->position;
	[index initIterator: it :ITER_EQ :key :key_part_count];
	/* iterating over the index and counting tuples */
	struct tuple *tuple;
	while ((tuple = it->next(it)) != NULL) {
		if (tuple->flags & GHOST)
			continue;
		count++;
	}
	/* returning subtree size */
	lua_pushnumber(L, count);
	return 1;
}

static const struct luaL_reg lbox_index_meta[] = {
	{"__tostring", lbox_index_tostring},
	{"__len", lbox_index_len},
	{"part_count", lbox_index_part_count},
	{"min", lbox_index_min},
	{"max", lbox_index_max},
	{"iterator", lbox_index_iterator},
	{"count", lbox_index_count},
	{NULL, NULL}
};

static const struct luaL_reg indexlib [] = {
	{"new", lbox_index_new},
	{NULL, NULL}
};

static const struct luaL_reg lbox_iterator_meta[] = {
	{"__gc", lbox_iterator_gc},
	{NULL, NULL}
};

/* }}} */

/** {{{ Lua I/O: facilities to intercept box output
 * and push into Lua stack.
 */

struct port_lua
{
	struct port_vtab *vtab;
	struct lua_State *L;
};

static inline struct port_lua *
port_lua(struct port *port) { return (struct port_lua *) port; }

/*
 * For addU32/dupU32 do nothing -- the only u32 Box can give
 * us is tuple count, and we don't need it, since we intercept
 * everything into Lua stack first.
 * @sa iov_add_multret
 */

static void
port_lua_add_tuple(struct port *port, struct tuple *tuple,
		   u32 flags __attribute__((unused)))
{
	lua_State *L = port_lua(port)->L;
	@try {
		lbox_pushtuple(L, tuple);
	} @catch (...) {
		tnt_raise(ClientError, :ER_PROC_LUA, lua_tostring(L, -1));
	}
}

struct port_vtab port_lua_vtab = {
	port_lua_add_tuple,
	port_null_eof,
};

static struct port *
port_lua_create(struct lua_State *L)
{
	struct port_lua *port = palloc(fiber->gc_pool, sizeof(struct port_lua));
	port->vtab = &port_lua_vtab;
	port->L = L;
	return (struct port *) port;
}

/**
 * Convert a Lua table to a tuple with as little
 * overhead as possible.
 */
static struct tuple *
lua_table_to_tuple(struct lua_State *L, int index)
{
	u32 field_count = 0;
	u32 tuple_len = 0;

	size_t field_len;

	/** First go: calculate tuple length. */
	lua_pushnil(L);  /* first key */
	while (lua_next(L, index) != 0) {
		++field_count;

		switch (lua_type(L, -1)) {
		case LUA_TNUMBER:
		{
			uint64_t n = lua_tonumber(L, -1);
			field_len = n > UINT32_MAX ? sizeof(uint64_t) : sizeof(uint32_t);
			break;
		}
		case LUA_TCDATA:
		{
			/* Check if we can convert. */
			(void) tarantool_lua_tointeger64(L, -1);
			field_len = sizeof(u64);
			break;
		}
		case LUA_TSTRING:
		{
			(void) lua_tolstring(L, -1, &field_len);
			break;
		}
		default:
			tnt_raise(ClientError, :ER_PROC_RET,
				  lua_typename(L, lua_type(L, -1)));
			break;
		}
		tuple_len += field_len + varint32_sizeof(field_len);
		lua_pop(L, 1);
	}
	struct tuple *tuple = tuple_alloc(tuple_len);
	/*
	 * Important: from here and on if there is an exception,
	 * the tuple is leaked.
	 */
	tuple->field_count = field_count;
	u8 *pos = tuple->data;

	/* Second go: store data in the tuple. */

	lua_pushnil(L);  /* first key */
	while (lua_next(L, index) != 0) {
		switch (lua_type(L, -1)) {
		case LUA_TNUMBER:
		{
			uint64_t n = lua_tonumber(L, -1);
			if (n > UINT32_MAX) {
				pos = memcpy(save_varint32(pos, sizeof(n)), &n,
							   sizeof(n)) + sizeof(n);
			} else {
				uint32_t n32 = (uint32_t) n;
				pos = memcpy(save_varint32(pos, sizeof(n32)), &n32,
							   sizeof(n32)) + sizeof(n32);
			}
			break;
		}
		case LUA_TCDATA:
		{
			uint64_t n = tarantool_lua_tointeger64(L, -1);
			pos = memcpy(save_varint32(pos, sizeof(n)), &n, sizeof(n))
				+ sizeof(n);
			break;
		}
		case LUA_TSTRING:
		{
			const char *field = lua_tolstring(L, -1, &field_len);
			pos = memcpy(save_varint32(pos, field_len), field, field_len)
				+ field_len;
			break;
		}
		default:
			assert(false);
			break;
		}
		lua_pop(L, 1);
	}
	return tuple;
}

static void
port_add_lua_ret(struct port *port, struct lua_State *L, int index)
{
	int type = lua_type(L, index);
	struct tuple *tuple;
	switch (type) {
	case LUA_TTABLE:
	{
		tuple = lua_table_to_tuple(L, index);
		break;
	}
	case LUA_TNUMBER:
	{
		size_t len = sizeof(u32);
		u32 num = lua_tointeger(L, index);
		tuple = tuple_alloc(len + varint32_sizeof(len));
		tuple->field_count = 1;
		memcpy(save_varint32(tuple->data, len), &num, len);
		break;
	}
	case LUA_TCDATA:
	{
		u64 num = tarantool_lua_tointeger64(L, index);
		size_t len = sizeof(u64);
		tuple = tuple_alloc(len + varint32_sizeof(len));
		tuple->field_count = 1;
		memcpy(save_varint32(tuple->data, len), &num, len);
		break;
	}
	case LUA_TSTRING:
	{
		size_t len;
		const char *str = lua_tolstring(L, index, &len);
		tuple = tuple_alloc(len + varint32_sizeof(len));
		tuple->field_count = 1;
		memcpy(save_varint32(tuple->data, len), str, len);
		break;
	}
	case LUA_TNIL:
	case LUA_TBOOLEAN:
	{
		const char *str = tarantool_lua_tostring(L, index);
		size_t len = strlen(str);
		tuple = tuple_alloc(len + varint32_sizeof(len));
		tuple->field_count = 1;
		memcpy(save_varint32(tuple->data, len), str, len);
		break;
	}
	case LUA_TUSERDATA:
	{
		tuple = lua_istuple(L, index);
		if (tuple)
			break;
	}
	default:
		/*
		 * LUA_TNONE, LUA_TTABLE, LUA_THREAD, LUA_TFUNCTION
		 */
		tnt_raise(ClientError, :ER_PROC_RET, lua_typename(L, type));
		break;
	}
	@try {
		port_add_tuple(port, tuple, BOX_RETURN_TUPLE);
	} @finally {
		if (tuple->refs == 0)
			tuple_free(tuple);
	}
}

/**
 * Add all elements from Lua stack to fiber iov.
 *
 * To allow clients to understand a complex return from
 * a procedure, we are compatible with SELECT protocol,
 * and return the number of return values first, and
 * then each return value as a tuple.
 */
static void
port_add_lua_multret(struct port *port, struct lua_State *L)
{
	int nargs = lua_gettop(L);
	for (int i = 1; i <= nargs; ++i)
		port_add_lua_ret(port, L, i);
}

/* }}} */

/**
 * The main extension provided to Lua by Tarantool/Box --
 * ability to call INSERT/UPDATE/SELECT/DELETE from within
 * a Lua procedure.
 *
 * This is a low-level API, and it expects
 * all arguments to be packed in accordance
 * with the binary protocol format (iproto
 * header excluded).
 *
 * Signature:
 * box.process(op_code, request)
 */
static int lbox_process(lua_State *L)
{
	u32 op = lua_tointeger(L, 1); /* Get the first arg. */
	struct tbuf req;
	size_t sz;
	req.data = (char *) luaL_checklstring(L, 2, &sz); /* Second arg. */
	req.capacity = req.size = sz;
	if (op == CALL) {
		/*
		 * We should not be doing a CALL from within a CALL.
		 * To invoke one stored procedure from another, one must
		 * do it in Lua directly. This deals with
		 * infinite recursion, stack overflow and such.
		 */
		return luaL_error(L, "box.process(CALL, ...) is not allowed");
	}
	int top = lua_gettop(L); /* to know how much is added by rw_callback */

	size_t allocated_size = palloc_allocated(fiber->gc_pool);
	struct port *port_lua = port_lua_create(L);
	@try {
		mod_process(port_lua, op, &req);
	} @finally {
		/*
		 * This only works as long as port_lua doesn't
		 * use fiber->cleanup and fiber->gc_pool.
		 */
		ptruncate(fiber->gc_pool, allocated_size);
	}
	return lua_gettop(L) - top;
}

static const struct luaL_reg boxlib[] = {
	{"process", lbox_process},
	{NULL, NULL}
};

/**
 * A helper to find a Lua function by name and put it
 * on top of the stack.
 */
static
void box_lua_find(lua_State *L, const char *name, const char *name_end)
{
	int index = LUA_GLOBALSINDEX;
	const char *start = name, *end;

	while ((end = memchr(start, '.', name_end - start))) {
		lua_checkstack(L, 3);
		lua_pushlstring(L, start, end - start);
		lua_gettable(L, index);
		if (! lua_istable(L, -1))
			tnt_raise(ClientError, :ER_NO_SUCH_PROC,
				  name_end - name, name);
		start = end + 1; /* next piece of a.b.c */
		index = lua_gettop(L); /* top of the stack */
	}
	lua_pushlstring(L, start, name_end - start);
	lua_gettable(L, index);
	if (! lua_isfunction(L, -1)) {
		/* lua_call or lua_gettable would raise a type error
		 * for us, but our own message is more verbose. */
		tnt_raise(ClientError, :ER_NO_SUCH_PROC,
			  name_end - name, name);
	}
	/* setting stack that it would contain only
	 * the function pointer. */
	if (index != LUA_GLOBALSINDEX) {
		lua_replace(L, 1);
		lua_settop(L, 1);
	}
}

/**
 * Invoke a Lua stored procedure from the binary protocol
 * (implementation of 'CALL' command code).
 */
void
box_lua_execute(struct request *request, struct txn *txn, struct port *port)
{
	(void) txn;
	struct tbuf *data = request->data;
	lua_State *L = lua_newthread(root_L);
	int coro_ref = luaL_ref(root_L, LUA_REGISTRYINDEX);
	/* Request flags: not used. */
	(void) (read_u32(data) & BOX_ALLOWED_REQUEST_FLAGS);
	@try {
		u32 field_len = read_varint32(data);
		void *field = read_str(data, field_len); /* proc name */
		box_lua_find(L, field, field + field_len);
		/* Push the rest of args (a tuple). */
		u32 nargs = read_u32(data);
		luaL_checkstack(L, nargs, "call: out of stack");
		for (int i = 0; i < nargs; i++) {
			field_len = read_varint32(data);
			field = read_str(data, field_len);
			lua_pushlstring(L, field, field_len);
		}
		lua_call(L, nargs, LUA_MULTRET);
		/* Send results of the called procedure to the client. */
		port_add_lua_multret(port, L);
	} @catch (tnt_Exception *e) {
		@throw;
	} @catch (...) {
		tnt_raise(ClientError, :ER_PROC_LUA, lua_tostring(L, -1));
	} @finally {
		/*
		 * Allow the used coro to be garbage collected.
		 * @todo: cache and reuse it instead.
		 */
		luaL_unref(root_L, LUA_REGISTRYINDEX, coro_ref);
	}
}

static
void mod_lua_init_index_constants(struct lua_State *L, int index) {
	for (int i = 0;
	     iteration_strategy_vals[i] != iteration_strategy_MAX;
	     i++) {
		enum iteration_strategy val = iteration_strategy_vals[i];
		assert(strncmp(iteration_strategy_strs[val], "ITER_", 5) == 0);
		lua_pushnumber(L, val);
		/* cut ITER_ prefix from enum name */
		lua_setfield(L, index, iteration_strategy_strs[val] + 5);
	}
}

void
mod_lua_init(struct lua_State *L)
{
	/* box, box.tuple */
	tarantool_lua_register_type(L, tuplelib_name, lbox_tuple_meta);
	luaL_register(L, "box", boxlib);
	lua_pop(L, 1);
	/* box.index */
	tarantool_lua_register_type(L, indexlib_name, lbox_index_meta);
	luaL_register(L, "box.index", indexlib);
	mod_lua_init_index_constants(L, -2);
	lua_pop(L, 1);
	tarantool_lua_register_type(L, iteratorlib_name, lbox_iterator_meta);
	/* Load box.lua */
	if (luaL_dostring(L, box_lua))
		panic("Error loading box.lua: %s", lua_tostring(L, -1));

	assert(lua_gettop(L) == 0);

	root_L = L;
}
