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
#include "index.h"
#include "tree.h"
#include "say.h"
#include "tuple.h"
#include "pickle.h"
#include "exception.h"
#include "space.h"
#include "assoc.h"

/* TODO(roman): split hash index to new file */

static struct index_traits index_traits = {
	.allows_partial_key = true,
};

static struct index_traits hash_index_traits = {
	.allows_partial_key = false,
};

const char *field_data_type_strs[] = {"NUM", "NUM64", "STR", "\0"};
const char *index_type_strs[] = { "HASH", "TREE", "\0" };

STRS(iteration_strategy, ITERATION_STRATEGY);
ENUM_VALS(iteration_strategy, ITERATION_STRATEGY);

/* {{{ Index -- base class for all indexes. ********************/

@interface HashIndex: Index
- (void) reserve: (u32) n_tuples;
@end

@interface HashStrIndex: HashIndex {
	 struct mh_lstrptr_t *str_hash;
};
@end

@interface Hash64Index: HashIndex {
	struct mh_i64ptr_t *int64_hash;
};
@end

@interface Hash32Index: HashIndex {
	 struct mh_i32ptr_t *int_hash;
};
@end


@implementation Index

@class Hash32Index;
@class Hash64Index;
@class HashStrIndex;
@class TreeIndex;

+ (struct index_traits *) traits
{
	return &index_traits;
}

+ (Index *) alloc: (enum index_type) type
	 :(struct key_def *) key_def
	 :(struct space *) space
{
	switch (type) {
	case HASH:
		/* Hash index, check key type.
		 * Hash index always has a single-field key.
		 */
		switch (key_def->parts[0].type) {
		case NUM:
			return [Hash32Index alloc]; /* 32-bit integer hash */
		case NUM64:
			return [Hash64Index alloc]; /* 64-bit integer hash */
		case STRING:
			return [HashStrIndex alloc]; /* string hash */
		default:
			break;
		}
		break;
	case TREE:
		return [TreeIndex alloc: key_def :space];
	default:
		break;
	}
	panic("unsupported index type");
}

- (id) init: (struct key_def *) key_def_arg :(struct space *) space_arg
{
	self = [super init];
	if (self) {
		traits = [object_getClass(self) traits];
		key_def = key_def_arg;
		space = space_arg;
		position = [self allocIterator];
	}
	return self;
}

- (void) free
{
	position->free(position);
	[super free];
}

- (void) beginBuild
{
	[self subclassResponsibility: _cmd];
}

- (void) buildNext: (struct tuple *)tuple
{
	(void) tuple;
	[self subclassResponsibility: _cmd];
}

- (void) endBuild
{
	[self subclassResponsibility: _cmd];
}

- (void) build: (Index *) pk
{
	(void) pk;
	[self subclassResponsibility: _cmd];
}


- (size_t) size
{
	[self subclassResponsibility: _cmd];
	return 0;
}

- (struct tuple *) min
{
	[self subclassResponsibility: _cmd];
	return NULL;
}

- (struct tuple *) max
{
	[self subclassResponsibility: _cmd];
	return NULL;
}

- (struct tuple *) findByKey: (void *) key :(int) part_count
{
	[self checkKeyParts: key_def: part_count: false];
	return [self findUnsafe: key :part_count];
}

- (struct tuple *) findUnsafe: (void *) key :(int) part_count
{
	(void) key;
	(void) part_count;
	[self subclassResponsibility: _cmd];
	return NULL;
}

- (struct tuple *) findByTuple: (struct tuple *) pattern
{
	(void) pattern;
	[self subclassResponsibility: _cmd];
	return NULL;
}

- (void) remove: (struct tuple *) tuple
{
	(void) tuple;
	[self subclassResponsibility: _cmd];
}

- (void) replace: (struct tuple *) old_tuple
	:(struct tuple *) new_tuple
{
	(void) old_tuple;
	(void) new_tuple;
	[self subclassResponsibility: _cmd];
}

- (struct iterator *) allocIterator
{
	[self subclassResponsibility: _cmd];
	return NULL;
}

- (void) initIterator: (struct iterator *) iterator
	:(enum iteration_strategy) strategy
{
	[self initIterator: iterator: strategy: NULL: 0];
}

- (void) initIterator: (struct iterator *) iterator
	:(enum iteration_strategy) strategy
	:(void *) key :(int) part_count
{
	(void) iterator;
	(void) key;
	(void) strategy;
	(void) part_count;
	[self subclassResponsibility: _cmd];
}

- (void)
checkKeyParts: (struct key_def *)key_def_arg
	: (int) part_count: (bool) partial_key_allowed
{
	if (part_count > key_def_arg->part_count)
		tnt_raise(ClientError, :ER_KEY_PART_COUNT,
			  part_count, key_def_arg->part_count);
	if (!partial_key_allowed && part_count < key_def_arg->part_count)
		tnt_raise(ClientError, :ER_EXACT_MATCH,
			  part_count, key_def_arg->part_count);
}

@end

/* }}} */

/* {{{ HashIndex -- base class for all hashes. ********************/

struct hash_iterator {
	struct iterator base; /* Must be the first member. */
	struct mh_i32ptr_t *hash;
	mh_int_t h_pos;
};

static struct hash_iterator *
hash_iterator(struct iterator *it)
{
	return (struct hash_iterator *) it;
}

void
hash_iterator_free(struct iterator *iterator)
{
	assert(iterator->free == hash_iterator_free);
	free(iterator);
}

struct tuple *
hash_iterator_next(struct iterator *iterator)
{
	assert(iterator->free == hash_iterator_free);
	struct hash_iterator *it = hash_iterator(iterator);

	while (it->h_pos < mh_end(it->hash)) {
		if (mh_exist(it->hash, it->h_pos))
			return mh_value(it->hash, it->h_pos++);
		it->h_pos++;
	}
	return NULL;
}

static struct tuple *
hash_iterator_next_null(struct iterator *it __attribute__((unused)))
{
	return NULL;
}

static struct tuple *
hash_iterator_next_equal(struct iterator *it)
{
	assert(it->next == hash_iterator_next_equal);
	it->next = hash_iterator_next_null;
	return hash_iterator_next(it);
}

@implementation HashIndex

+ (struct index_traits *) traits
{
	return &hash_index_traits;
}

- (void) reserve: (u32) n_tuples
{
	(void) n_tuples;
	[self subclassResponsibility: _cmd];
}

- (void) beginBuild
{
}

- (void) buildNext: (struct tuple *)tuple
{
	[self replace: NULL :tuple];
}

- (void) endBuild
{
}

- (void) build: (Index *) pk
{
	u32 n_tuples = [pk size];

	if (n_tuples == 0)
		return;

	[self reserve: n_tuples];

	say_info("Adding %"PRIu32 " keys to HASH index %"
		 PRIu32 "...", n_tuples, index_n(self));

	struct iterator *it = pk->position;
	struct tuple *tuple;
	[pk initIterator: it :ITER_ALL];

	while ((tuple = it->next(it)))
	      [self replace: NULL :tuple];
}

- (void) free
{
	[super free];
}

- (struct tuple *) min
{
	tnt_raise(ClientError, :ER_UNSUPPORTED, "Hash index", "min()");
	return NULL;
}

- (struct tuple *) max
{
	tnt_raise(ClientError, :ER_UNSUPPORTED, "Hash index", "max()");
	return NULL;
}

- (struct tuple *) findByTuple: (struct tuple *) tuple
{
	/* Hash index currently is always single-part. */
	void *field = tuple_field(tuple, key_def->parts[0].fieldno);
	if (field == NULL)
		tnt_raise(ClientError, :ER_NO_SUCH_FIELD,
			  key_def->parts[0].fieldno);
	return [self findUnsafe :field :1];
}

- (struct iterator *) allocIterator
{
	struct hash_iterator *it = malloc(sizeof(struct hash_iterator));
	if (it) {
		memset(it, 0, sizeof(struct hash_iterator));
		it->base.next = hash_iterator_next;
		it->base.free = hash_iterator_free;
	}
	return (struct iterator *) it;
}

@end

/* }}} */

/* {{{ Hash32Index ************************************************/

static u32
int32_key_to_value(void *key)
{
	u32 key_size = load_varint32(&key);
	if (key_size != 4)
		tnt_raise(ClientError, :ER_KEY_FIELD_TYPE, "u32");
	return *((u32 *) key);
}


@implementation Hash32Index

- (void) reserve: (u32) n_tuples
{
	mh_i32ptr_reserve(int_hash, n_tuples);
}

- (void) free
{
	mh_i32ptr_destroy(int_hash);
	[super free];
}

- (id) init: (struct key_def *) key_def_arg :(struct space *) space_arg
{
	self = [super init: key_def_arg :space_arg];
	if (self) {
		int_hash = mh_i32ptr_init();
	}
	return self;
}

- (size_t) size
{
	return mh_size(int_hash);
}

- (struct tuple *) findUnsafe: (void *) key :(int) part_count
{
	(void) part_count;

	struct tuple *ret = NULL;
	u32 num = int32_key_to_value(key);
	mh_int_t k = mh_i32ptr_get(int_hash, num);
	if (k != mh_end(int_hash))
		ret = mh_value(int_hash, k);
#ifdef DEBUG
	say_debug("Hash32Index find(self:%p, key:%i) = %p", self, num, ret);
#endif
	return ret;
}

- (void) remove: (struct tuple *) tuple
{
	void *field = tuple_field(tuple, key_def->parts[0].fieldno);
	u32 num = int32_key_to_value(field);
	mh_int_t k = mh_i32ptr_get(int_hash, num);
	if (k != mh_end(int_hash))
		mh_i32ptr_del(int_hash, k);
#ifdef DEBUG
	say_debug("Hash32Index remove(self:%p, key:%i)", self, num);
#endif
}

- (void) replace: (struct tuple *) old_tuple
	:(struct tuple *) new_tuple
{
	void *field = tuple_field(new_tuple, key_def->parts[0].fieldno);
	u32 num = int32_key_to_value(field);

	if (old_tuple != NULL) {
		void *old_field = tuple_field(old_tuple,
					      key_def->parts[0].fieldno);
		load_varint32(&old_field);
		u32 old_num = *(u32 *)old_field;
		mh_int_t k = mh_i32ptr_get(int_hash, old_num);
		if (k != mh_end(int_hash))
			mh_i32ptr_del(int_hash, k);
	}

	mh_int_t pos = mh_i32ptr_put(int_hash, num, new_tuple, NULL);

	if (pos == mh_end(int_hash))
		tnt_raise(LoggedError, :ER_MEMORY_ISSUE, (ssize_t) pos,
			  "int hash", "key");

#ifdef DEBUG
	say_debug("Hash32Index replace(self:%p, old_tuple:%p, new_tuple:%p) key:%i",
		  self, old_tuple, new_tuple, num);
#endif
}

- (void) initIterator: (struct iterator *) iterator
	:(enum iteration_strategy) strategy
	:(void *) key :(int) part_count
{
	(void) part_count;
	assert(iterator->free == hash_iterator_free);
	struct hash_iterator *it = hash_iterator(iterator);

	switch (strategy) {
	case ITER_ALL:
		it->base.next = hash_iterator_next;
		it->h_pos = mh_begin(int_hash);
		break;
	case ITER_GE:
		/* TODO(roman): backward compatibility only, remove in future */
		if (key == NULL) {
			it->base.next = hash_iterator_next;
			it->h_pos = mh_begin(int_hash);
		} else {
			[self checkKeyParts: key_def: part_count:
					     traits->allows_partial_key];
			u32 num = int32_key_to_value(key);
			it->h_pos = mh_i32ptr_get(int_hash, num);
			it->base.next = hash_iterator_next;
		}
		break;
	case ITER_EQ:
		[self checkKeyParts: key_def: part_count:
				     traits->allows_partial_key];
		u32 num = int32_key_to_value(key);
		it->h_pos = mh_i32ptr_get(int_hash, num);
		it->base.next = hash_iterator_next_equal;
		break;
	default:
		tnt_raise(IllegalParams, :"unsupported strategy");
	}

	it->hash = int_hash;
}
@end

/* }}} */

/* {{{ Hash64Index ************************************************/

static u64
int64_key_to_value(void *key)
{
	u32 key_size = load_varint32(&key);
	if (key_size != 8)
		tnt_raise(ClientError, :ER_KEY_FIELD_TYPE, "u64");
	return *((u64 *) key);
}

@implementation Hash64Index
- (void) reserve: (u32) n_tuples
{
	mh_i64ptr_reserve(int64_hash, n_tuples);
}

- (void) free
{
	mh_i64ptr_destroy(int64_hash);
	[super free];
}

- (id) init: (struct key_def *) key_def_arg :(struct space *) space_arg
{
	self = [super init: key_def_arg :space_arg];
	if (self) {
		int64_hash = mh_i64ptr_init();
	}
	return self;
}

- (size_t) size
{
	return mh_size(int64_hash);
}

- (struct tuple *) findUnsafe: (void *) key :(int) part_count
{
	(void) part_count;

	struct tuple *ret = NULL;
	u64 num = int64_key_to_value(key);
	mh_int_t k = mh_i64ptr_get(int64_hash, num);
	if (k != mh_end(int64_hash))
		ret = mh_value(int64_hash, k);
#ifdef DEBUG
	say_debug("Hash64Index find(self:%p, key:%"PRIu64") = %p", self, num, ret);
#endif
	return ret;
}

- (void) remove: (struct tuple *) tuple
{
	void *field = tuple_field(tuple, key_def->parts[0].fieldno);
	u64 num = int64_key_to_value(field);

	mh_int_t k = mh_i64ptr_get(int64_hash, num);
	if (k != mh_end(int64_hash))
		mh_i64ptr_del(int64_hash, k);
#ifdef DEBUG
	say_debug("Hash64Index remove(self:%p, key:%"PRIu64")", self, num);
#endif
}

- (void) replace: (struct tuple *) old_tuple
	:(struct tuple *) new_tuple
{
	void *field = tuple_field(new_tuple, key_def->parts[0].fieldno);
	u64 num = int64_key_to_value(field);

	if (old_tuple != NULL) {
		void *old_field = tuple_field(old_tuple,
					      key_def->parts[0].fieldno);
		load_varint32(&old_field);
		u64 old_num = *(u64 *)old_field;
		mh_int_t k = mh_i64ptr_get(int64_hash, old_num);
		if (k != mh_end(int64_hash))
			mh_i64ptr_del(int64_hash, k);
	}

	mh_int_t pos = mh_i64ptr_put(int64_hash, num, new_tuple, NULL);
	if (pos == mh_end(int64_hash))
		tnt_raise(LoggedError, :ER_MEMORY_ISSUE, (ssize_t) pos,
			  "int64 hash", "key");
#ifdef DEBUG
	say_debug("Hash64Index replace(self:%p, old_tuple:%p, tuple:%p) key:%"PRIu64,
		  self, old_tuple, new_tuple, num);
#endif
}

- (void) initIterator: (struct iterator *) iterator
	:(enum iteration_strategy) strategy
	:(void *) key :(int) part_count
{
	assert(iterator->free == hash_iterator_free);
	struct hash_iterator *it = hash_iterator(iterator);

	(void) part_count;

	switch (strategy) {
	case ITER_ALL:
		it->base.next = hash_iterator_next;
		it->h_pos = mh_begin(int64_hash);
		break;
	case ITER_GE:
		/* TODO(roman): backward compatibility only, remove in future */
		if (key == NULL) {
			it->base.next = hash_iterator_next;
			it->h_pos = mh_begin(int64_hash);
		} else {
			[self checkKeyParts: key_def: part_count:
					     traits->allows_partial_key];
			u64 num = int64_key_to_value(key);
			it->h_pos = mh_i64ptr_get(int64_hash, num);
			it->base.next = hash_iterator_next;
		}
		break;
	case ITER_EQ:
		[self checkKeyParts: key_def: part_count:
				     traits->allows_partial_key];
		u64 num = int64_key_to_value(key);
		it->h_pos = mh_i64ptr_get(int64_hash, num);
		it->base.next = hash_iterator_next_equal;
		break;
	default:
		tnt_raise(IllegalParams, :"unsupported strategy");
	}

	it->hash = (struct mh_i32ptr_t *) int64_hash;
}
@end

/* }}} */

/* {{{ HashStrIndex ***********************************************/

@implementation HashStrIndex
- (void) reserve: (u32) n_tuples
{
	mh_lstrptr_reserve(str_hash, n_tuples);
}

- (void) free
{
	mh_lstrptr_destroy(str_hash);
	[super free];
}

- (id) init: (struct key_def *) key_def_arg :(struct space *) space_arg
{
	self = [super init: key_def_arg :space_arg];
	if (self) {
		str_hash = mh_lstrptr_init();
	}
	return self;
}

- (size_t) size
{
	return mh_size(str_hash);
}

- (struct tuple *) findUnsafe: (void *) key :(int) part_count
{
	(void) part_count;
	struct tuple *ret = NULL;
	mh_int_t k = mh_lstrptr_get(str_hash, key);
	if (k != mh_end(str_hash))
		ret = mh_value(str_hash, k);
#ifdef DEBUG
	u32 key_size = load_varint32(&key);
	say_debug("HashStrIndex find(self:%p, key:(%i)'%.*s') = %p",
		  self, key_size, key_size, (u8 *)key, ret);
#endif
	return ret;
}

- (void) remove: (struct tuple *) tuple
{
	void *field = tuple_field(tuple, key_def->parts[0].fieldno);

	mh_int_t k = mh_lstrptr_get(str_hash, field);
	if (k != mh_end(str_hash))
		mh_lstrptr_del(str_hash, k);
#ifdef DEBUG
	u32 field_size = load_varint32(&field);
	say_debug("HashStrIndex remove(self:%p, key:'%.*s')",
		  self, field_size, (u8 *)field);
#endif
}

- (void) replace: (struct tuple *) old_tuple
	:(struct tuple *) new_tuple
{
	void *field = tuple_field(new_tuple, key_def->parts[0].fieldno);

	if (field == NULL)
		tnt_raise(ClientError, :ER_NO_SUCH_FIELD,
			  key_def->parts[0].fieldno);

	if (old_tuple != NULL) {
		void *old_field = tuple_field(old_tuple,
					      key_def->parts[0].fieldno);
		mh_int_t k = mh_lstrptr_get(str_hash, old_field);
		if (k != mh_end(str_hash))
			mh_lstrptr_del(str_hash, k);
	}

	mh_int_t pos = mh_lstrptr_put(str_hash, field, new_tuple, NULL);
	if (pos == mh_end(str_hash))
		tnt_raise(LoggedError, :ER_MEMORY_ISSUE, (ssize_t) pos,
			  "str hash", "key");
#ifdef DEBUG
	u32 field_size = load_varint32(&field);
	say_debug("HashStrIndex replace(self:%p, old_tuple:%p, tuple:%p) key:'%.*s'",
		  self, old_tuple, new_tuple, field_size, (u8 *)field);
#endif
}

- (void) initIterator: (struct iterator *) iterator
	:(enum iteration_strategy) strategy
	:(void *) key :(int) part_count
{
	(void) part_count;

	assert(iterator->free == hash_iterator_free);
	struct hash_iterator *it = hash_iterator(iterator);

	switch (strategy) {
	case ITER_ALL:
		it->base.next = hash_iterator_next;
		it->h_pos = mh_begin(str_hash);
		break;
	case ITER_GE:
		/* TODO(roman): backward compatibility only, remove in future */
		if (key == NULL) {
			it->base.next = hash_iterator_next;
			it->h_pos = mh_begin(str_hash);
		} else {
			[self checkKeyParts: key_def: part_count:
					     traits->allows_partial_key];
			it->h_pos = mh_lstrptr_get(str_hash, key);
			it->base.next = hash_iterator_next;
		}
		break;
	case ITER_EQ:
		[self checkKeyParts: key_def: part_count:
				     traits->allows_partial_key];
		it->h_pos = mh_lstrptr_get(str_hash, key);
		it->base.next = hash_iterator_next_equal;
		break;
	default:
		tnt_raise(IllegalParams, :"unsupported strategy");
	}

	it->hash = (struct mh_i32ptr_t *) str_hash;
}
@end

/* }}} */

