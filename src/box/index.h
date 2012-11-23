#ifndef TARANTOOL_BOX_INDEX_H_INCLUDED
#define TARANTOOL_BOX_INDEX_H_INCLUDED
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
#import "object.h"
#include <stdbool.h>
#include <util.h>

struct tuple;
struct space;
struct index;

/*
 * Possible field data types. Can't use STRS/ENUM macros for them,
 * since there is a mismatch between enum name (STRING) and type
 * name literal ("STR"). STR is already used as Objective C type.
 */
enum field_data_type { UNKNOWN = -1, NUM = 0, NUM64, STRING, field_data_type_MAX };
extern const char *field_data_type_strs[];

enum index_type { HASH, TREE, index_type_MAX };
extern const char *index_type_strs[];

/**
 * @abstract Iterator type
 * Controls how to iterate over tuples in the index.
 * Various indexes may support different iteration strategies.
 * For example, you can start iteration from one particaluar value (request key)
 * and then retrive all tuples where keys are great or equal (= GE) to this key.
 * There is no more special flags for iteration direction, since this direction
 * only depends on in chosen iterator type.
 *
 * If type is not supported in the implementation, iterator constructor
 * must fail with IllegalParams. Primary keys should support at least ITER_EQ
 * and ITER_GE strategies. By default, box.select uses ITER_EQ type.
 *
 * NULL request keys note. NULL value of request key usually correspond to
 * first or last key in the index, depending on the iteration direction
 * (first of GE GT and last for LE LT). So if you want to iterate over all
 * tuples in the index, just use ITER_GE or ITER_LE with key = NULL.
 * For ITER_EQ key must not be NULL.
 *
 * ITER_EQ order note. ITER_EQ must return all tuples that have same key
 * (make sense for non-unique indexes). The return order of equal
 * tuples is implementation-defined.
 *
 * ITER_ALL note. ITER_ALL must be supported by every index, because it is used
 * in various parts of our code (snapshotting, building secondary keys, etc.).
 */
#define ITERATOR_TYPE(_)                                                  \
	_(ITER_ALL, 0)                 /* all tuples                      */   \
	_(ITER_EQ,  1)                 /* key == x ASC order              */   \
	_(ITER_REQ, 2)                 /* key == x DESC order             */   \
	_(ITER_LT,  3)                 /* key <  x                        */   \
	_(ITER_LE,  4)                 /* key <= x                        */   \
	_(ITER_GE,  5)                 /* key >= x                        */   \
	_(ITER_GT,  6)                 /* key >  x                        */   \

ENUM(iterator_type, ITERATOR_TYPE);
extern const char *iterator_type_strs[];
extern const enum iterator_type iterator_type_vals[];

/** Descriptor of a single part in a multipart key. */
struct key_part {
	int fieldno;
	enum field_data_type type;
};

/* Descriptor of a multipart key. */
struct key_def {
	/* Description of parts of a multipart index. */
	struct key_part *parts;
	/*
	 * An array holding field positions in 'parts' array.
	 * Imagine there is index[1] = { key_field[0].fieldno=5,
	 * key_field[1].fieldno=3 }.
	 * 'parts' array for such index contains data from
	 * key_field[0] and key_field[1] respectively.
	 * max_fieldno is 5, and cmp_order array holds offsets of
	 * field 3 and 5 in 'parts' array: -1, -1, 0, -1, 1.
	 */
	u32 *cmp_order;
	/* The size of the 'parts' array. */
	int part_count;
	/*
	 * The size of 'cmp_order' array (= max fieldno in 'parts'
	 * array).
	 */
	int max_fieldno;
	bool is_unique;
};

/** Descriptor of index features. */
struct index_traits
{
	bool allows_partial_key;
};

@interface Index: tnt_Object {
	/* Index features. */
	struct index_traits *traits;
 @public
	/* Index owner space */
	struct space *space;
	/* Description of a possibly multipart key. */
	struct key_def *key_def;
	/*
	 * Pre-allocated iterator to speed up the main case of
	 * box_process(). Should not be used elsewhere.
	 */
	struct iterator *position;
};

/**
 * Get index traits.
 */
+ (struct index_traits *) traits;
/**
 * Allocate index instance.
 *
 * @param type     index type
 * @param key_def  key part description
 * @param space    space the index belongs to
 */
+ (Index *) alloc: (enum index_type) type :(struct key_def *) key_def
	:(struct space *) space;
/**
 * Initialize index instance.
 *
 * @param key_def  key part description
 * @param space    space the index belongs to
 */
- (id) init: (struct key_def *) key_def_arg :(struct space *) space_arg;
/** Destroy and free index instance. */
- (void) free;
/**
 * Two-phase index creation: begin building, add tuples, finish.
 */
- (void) beginBuild;
- (void) buildNext: (struct tuple *)tuple;
- (void) endBuild;
/** Build this index based on the contents of another index. */
- (void) build: (Index *) pk;
- (size_t) size;
- (struct tuple *) min;
- (struct tuple *) max;
- (struct tuple *) findByKey: (void *) key :(int) part_count;
- (struct tuple *) findByTuple: (struct tuple *) tuple;
- (void) remove: (struct tuple *) tuple;
- (void) replace: (struct tuple *) old_tuple :(struct tuple *) new_tuple;
/**
 * Create a structure to represent an iterator. Must be
 * initialized separately.
 */
- (struct iterator *) allocIterator;
- (void) initIterator: (struct iterator *) iterator
		     :(enum iterator_type) type;
- (void) initIterator: (struct iterator *) iterator
		     :(enum iterator_type) type
		     :(void *) key :(int) part_count;

/**
 * Unsafe search methods that do not check key part count.
 */
- (struct tuple *) findUnsafe: (void *) key :(int) part_count;
- (void) checkKeyParts: (struct key_def *)key_def
	: (int) part_count: (bool) partial_key_allowed;

@end

struct iterator {
	struct tuple *(*next)(struct iterator *);
	void (*free)(struct iterator *);
};

#endif /* TARANTOOL_BOX_INDEX_H_INCLUDED */
