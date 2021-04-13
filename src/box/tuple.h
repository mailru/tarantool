#ifndef TARANTOOL_BOX_TUPLE_H_INCLUDED
#define TARANTOOL_BOX_TUPLE_H_INCLUDED
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
#include "trivia/util.h"
#include "say.h"
#include "diag.h"
#include "error.h"
#include "uuid/tt_uuid.h" /* tuple_field_uuid */
#include "tt_static.h"
#include "tuple_format.h"

#if defined(__cplusplus)
extern "C" {
#endif /* defined(__cplusplus) */

struct slab_arena;
struct quota;
struct key_part;

/**
 * A format for standalone tuples allocated on runtime arena.
 * \sa tuple_new().
 */
extern struct tuple_format *tuple_format_runtime;

/** Initialize tuple library */
int
tuple_init(field_name_hash_f hash);

/** Cleanup tuple library */
void
tuple_free(void);

/**
 * Initialize tuples arena.
 * @param arena[out] Arena to initialize.
 * @param quota Arena's quota.
 * @param arena_max_size Maximal size of @arena.
 * @param arena_name Name of @arena for logs.
 */
void
tuple_arena_create(struct slab_arena *arena, struct quota *quota,
		   uint64_t arena_max_size, uint32_t slab_size,
		   bool dontdump, const char *arena_name);

void
tuple_arena_destroy(struct slab_arena *arena);

/** \cond public */

typedef struct tuple_format box_tuple_format_t;

/**
 * Tuple Format.
 *
 * Each Tuple has associated format (class). Default format is used to
 * create tuples which are not attach to any particular space.
 */
box_tuple_format_t *
box_tuple_format_default(void);

/**
 * Tuple
 */
typedef struct tuple box_tuple_t;

/**
 * Increase the reference counter of tuple.
 *
 * Tuples are reference counted. All functions that return tuples guarantee
 * that the last returned tuple is refcounted internally until the next
 * call to API function that yields or returns another tuple.
 *
 * You should increase the reference counter before taking tuples for long
 * processing in your code. Such tuples will not be garbage collected even
 * if another fiber remove they from space. After processing please
 * decrement the reference counter using box_tuple_unref(), otherwise the
 * tuple will leak.
 *
 * \param tuple a tuple
 * \retval 0 always
 * \sa box_tuple_unref()
 */
int
box_tuple_ref(box_tuple_t *tuple);

/**
 * Decrease the reference counter of tuple.
 *
 * \param tuple a tuple
 * \sa box_tuple_ref()
 */
void
box_tuple_unref(box_tuple_t *tuple);

/**
 * Return the number of fields in tuple (the size of MsgPack Array).
 * \param tuple a tuple
 */
uint32_t
box_tuple_field_count(box_tuple_t *tuple);

/**
 * Return the number of bytes used to store internal tuple data (MsgPack Array).
 * \param tuple a tuple
 */
size_t
box_tuple_bsize(box_tuple_t *tuple);

/**
 * Dump raw MsgPack data to the memory byffer \a buf of size \a size.
 *
 * Store tuple fields in the memory buffer.
 * \retval -1 on error.
 * \retval number of bytes written on success.
 * Upon successful return, the function returns the number of bytes written.
 * If buffer size is not enough then the return value is the number of bytes
 * which would have been written if enough space had been available.
 */
ssize_t
box_tuple_to_buf(box_tuple_t *tuple, char *buf, size_t size);

/**
 * Return the associated format.
 * \param tuple tuple
 * \return tuple_format
 */
box_tuple_format_t *
box_tuple_format(box_tuple_t *tuple);

/**
 * Return the raw tuple field in MsgPack format.
 *
 * The buffer is valid until next call to box_tuple_* functions.
 *
 * \param tuple a tuple
 * \param fieldno zero-based index in MsgPack array.
 * \retval NULL if i >= box_tuple_field_count(tuple)
 * \retval msgpack otherwise
 */
const char *
box_tuple_field(box_tuple_t *tuple, uint32_t fieldno);

/**
 * Tuple iterator
 */
typedef struct tuple_iterator box_tuple_iterator_t;

/**
 * Allocate and initialize a new tuple iterator. The tuple iterator
 * allow to iterate over fields at root level of MsgPack array.
 *
 * Example:
 * \code
 * box_tuple_iterator *it = box_tuple_iterator(tuple);
 * if (it == NULL) {
 *      // error handling using box_error_last()
 * }
 * const char *field;
 * while (field = box_tuple_next(it)) {
 *      // process raw MsgPack data
 * }
 *
 * // rewind iterator to first position
 * box_tuple_rewind(it);
 * assert(box_tuple_position(it) == 0);
 *
 * // rewind iterator to first position
 * field = box_tuple_seek(it, 3);
 * assert(box_tuple_position(it) == 4);
 *
 * box_iterator_free(it);
 * \endcode
 *
 * \post box_tuple_position(it) == 0
 */
box_tuple_iterator_t *
box_tuple_iterator(box_tuple_t *tuple);

/**
 * Destroy and free tuple iterator
 */
void
box_tuple_iterator_free(box_tuple_iterator_t *it);

/**
 * Return zero-based next position in iterator.
 * That is, this function return the field id of field that will be
 * returned by the next call to box_tuple_next(it). Returned value is zero
 * after initialization or rewind and box_tuple_field_count(tuple)
 * after the end of iteration.
 *
 * \param it tuple iterator
 * \returns position.
 */
uint32_t
box_tuple_position(box_tuple_iterator_t *it);

/**
 * Rewind iterator to the initial position.
 *
 * \param it tuple iterator
 * \post box_tuple_position(it) == 0
 */
void
box_tuple_rewind(box_tuple_iterator_t *it);

/**
 * Seek the tuple iterator.
 *
 * The returned buffer is valid until next call to box_tuple_* API.
 * Requested fieldno returned by next call to box_tuple_next(it).
 *
 * \param it tuple iterator
 * \param fieldno - zero-based position in MsgPack array.
 * \post box_tuple_position(it) == fieldno if returned value is not NULL
 * \post box_tuple_position(it) == box_tuple_field_count(tuple) if returned
 * value is NULL.
 */
const char *
box_tuple_seek(box_tuple_iterator_t *it, uint32_t fieldno);

/**
 * Return the next tuple field from tuple iterator.
 * The returned buffer is valid until next call to box_tuple_* API.
 *
 * \param it tuple iterator.
 * \retval NULL if there are no more fields.
 * \retval MsgPack otherwise
 * \pre box_tuple_position(it) is zerod-based id of returned field
 * \post box_tuple_position(it) == box_tuple_field_count(tuple) if returned
 * value is NULL.
 */
const char *
box_tuple_next(box_tuple_iterator_t *it);

/**
 * Allocate and initialize a new tuple from a raw MsgPack Array data.
 *
 * \param format tuple format.
 * Use box_tuple_format_default() to create space-independent tuple.
 * \param data tuple data in MsgPack Array format ([field1, field2, ...]).
 * \param end the end of \a data
 * \retval tuple
 * \pre data, end is valid MsgPack Array
 * \sa \code box.tuple.new(data) \endcode
 */
box_tuple_t *
box_tuple_new(box_tuple_format_t *format, const char *data, const char *end);

box_tuple_t *
box_tuple_update(box_tuple_t *tuple, const char *expr, const char *expr_end);

box_tuple_t *
box_tuple_upsert(box_tuple_t *tuple, const char *expr, const char *expr_end);

/**
 * Check tuple data correspondence to the space format.
 * @param tuple  Tuple to validate.
 * @param format Format to which the tuple must match.
 *
 * @retval  0 The tuple is valid.
 * @retval -1 The tuple is invalid.
 */
int
box_tuple_validate(box_tuple_t *tuple, box_tuple_format_t *format);

/** \endcond public */

#define MAX_TINY_DATA_OFFSET 63

/** Part of struct tuple. */
struct tiny_tuple_props {
	/**
	 * Tuple is tiny in case it's bsize fits in 1 byte,
	 * it's data_offset fits in 6 bits and field map
	 * offsets fit into 1 byte each.
	 */
	bool is_tiny : 1;
	/**
	 * The tuple (if it's found in index for example) could be invisible
	 * for current transactions. The flag means that the tuple must
	 * be clarified by the transaction engine.
	 */
	bool is_dirty : 1;
	/**
	 * Offset to the MessagePack from the beginning of the
	 * tuple. 6 bits in case tuple is tiny.
	 */
	uint8_t data_offset : 6;
	/**
	 * Length of the MessagePack data in raw part of the
	 * tuple. 8 bits in case tuple is tiny.
	 */
	uint8_t bsize;
};

/** Part of struct tuple. */
struct tuple_props {
	/**
	 * Tuple is tiny in case it's bsize fits in 1 byte,
	 * it's data_offset fits in 6 bits and field map
	 * offsets fit into 1 byte each.
	 */
	bool is_tiny : 1;
	/**
	 * Offset to the MessagePack from the beginning of the
	 * tuple. 15 bits in case tuple is not tiny.
	 */
	uint16_t data_offset: 15;
};

/** Part of struct tuple. */
struct PACKED tuple_extra {
	/**
	 * The tuple (if it's found in index for example) could be invisible
	 * for current transactions. The flag means that the tuple must
	 * be clarified by the transaction engine.
	 */
	bool is_dirty : 1;
	/**
	 * Length of the MessagePack data in raw part of the
	 * tuple. 31 bits in case tuple is not tiny.
	 */
	uint32_t bsize : 31;
};

/**
 * An atom of Tarantool storage. Represents MsgPack Array.
 * Tuple has the following structure:
 *                           uint32       uint32     bsize
 *                          +-------------------+-------------+
 * tuple_begin, ..., raw =  | offN | ... | off1 | MessagePack |
 * |                        +-------------------+-------------+
 * |                                            ^
 * +---------------------------------------data_offset
 *
 * Each 'off_i' is the offset to the i-th indexed field.
 */
struct PACKED tuple
{
	union {
		/** Reference counter. */
		uint16_t refs;
		struct {
			/** Index of big reference counter. */
			uint16_t ref_index : 15;
			/** Big reference flag. */
			bool is_bigref : 1;
		};
	};
	/** Format identifier. */
	uint16_t format_id;
	/**
	 * Both structs in the following union contain is_tiny bit
	 * as the first field. It is guaranteed it will be the same
	 * for both of them in any case. Tuple is tiny in case it's
	 * bsize fits in 1 byte, it's data_offset fits in 6 bits and
	 * field map offsets fit into 1 byte each. In case it is tiny
	 * we will obtain data_offset, bsize and is_dirty flag from the
	 * struct tiny_tuple_props. Otherwise we will obtain data_offset
	 * from struct tuple_props, while bsize and is_dirty flag will be
	 * stored in struct tuple_extra (4 bytes at the end of the tuple).
	 */
	union {
		/**
		 * In case the tuple is tiny this struct is used to obtain
		 * data_offset (offset to the MessagePack from the beginning
		 * of the tuple), bsize (the length of the MessagePack data
		 * in the raw part of the tuple) and is_dirty flag (true if
		 * the tuple must be clarified by transaction engine).
		 */
		struct tiny_tuple_props tiny_props;
		/**
		 * In case the tuple is not tiny this struct is used to obtain
		 * data_offset (offset to the MessagePack from the beginning of
		 * the tuple).
		 */
		struct tuple_props props;
	};
	/**
	 * In case the tuple is not tiny this struct contains is_dirty
	 * flag (true if the tuple must be clarified by transaction
	 * engine) and bsize (the length of the MessagePack data
	 * in the raw part of the tuple).
	 * If the tuple is tiny, this fields is 0 bytes.
	 */
	struct tuple_extra extra[];
	/**
	 * Engine specific fields and offsets array concatenated
	 * with MessagePack fields array.
	 * char raw[0];
	 */
};

/**
 * According to C standard sections 6.5.2.3-5 it is guaranteed
 * if a union contains several structures that share a common
 * initial sequence of members (bool is_tiny in this case), it is
 * permitted to inspect the common initial part of any of them
 * anywhere that a declaration of the complete type of the union
 * is visible. Two structures share a common initial sequence if
 * corresponding members have compatible types (and, for
 * bit-fields, the same widths) for a sequence of one or more
 * initial members. Thus we are guaranteed that is_tiny bit is
 * same for both struct tiny_tuple_props and struct tuple_props
 * and we can simply read or write any of them.
 */
static inline void
tuple_set_tiny_bit(struct tuple *tuple, bool is_tiny)
{
	assert(tuple != NULL);
	tuple->props.is_tiny = is_tiny;
}

static inline bool
tuple_is_tiny(struct tuple *tuple)
{
	assert(tuple != NULL);
	return tuple->props.is_tiny;
}

static inline void
tiny_tuple_set_dirty_bit(struct tuple *tuple, bool is_dirty)
{
	tuple->tiny_props.is_dirty = is_dirty;
}

static inline void
basic_tuple_set_dirty_bit(struct tuple *tuple, bool is_dirty)
{
	tuple->extra->is_dirty = is_dirty;
}

static inline void
tuple_set_dirty_bit(struct tuple *tuple, bool is_dirty)
{
	assert(tuple != NULL);
	tuple->props.is_tiny ? tiny_tuple_set_dirty_bit(tuple, is_dirty) :
			       basic_tuple_set_dirty_bit(tuple, is_dirty);
}

static inline bool
tuple_is_dirty(struct tuple *tuple)
{
	assert(tuple != NULL);
	return tuple->props.is_tiny ? tuple->tiny_props.is_dirty :
				      tuple->extra->is_dirty;
}

static inline void
tiny_tuple_set_bsize(struct tuple *tuple, uint32_t bsize)
{
	assert(bsize <= UINT8_MAX); /* bsize has to fit in UINT8_MAX */
	tuple->tiny_props.bsize = bsize;
}

static inline void
basic_tuple_set_bsize(struct tuple *tuple, uint32_t bsize)
{
	assert(bsize <= INT32_MAX); /* bsize has to fit in INT32_MAX */
	tuple->extra->bsize = bsize;
}

static inline void
tuple_set_bsize(struct tuple *tuple, uint32_t bsize)
{
	assert(tuple != NULL);
	tuple->props.is_tiny ? tiny_tuple_set_bsize(tuple, bsize) :
			       basic_tuple_set_bsize(tuple, bsize);
}

static inline uint32_t
tuple_bsize(struct tuple *tuple)
{
	assert(tuple != NULL);
	return tuple->props.is_tiny ? tuple->tiny_props.bsize :
				      tuple->extra->bsize;
}

static inline void
tiny_tuple_set_data_offset(struct tuple *tuple, uint8_t data_offset)
{
	tuple->tiny_props.data_offset = data_offset;
}

static inline void
basic_tuple_set_data_offset(struct tuple *tuple, uint16_t data_offset)
{
	tuple->props.data_offset = data_offset;
}

static inline void
tuple_set_data_offset(struct tuple *tuple, uint16_t data_offset)
{
	assert(tuple != NULL);
	tuple->props.is_tiny ? tiny_tuple_set_data_offset(tuple, data_offset) :
			       basic_tuple_set_data_offset(tuple, data_offset);
}

static inline uint16_t
tuple_data_offset(struct tuple *tuple)
{
	assert(tuple != NULL);
	return tuple->props.is_tiny ? tuple->tiny_props.data_offset :
				      tuple->props.data_offset;
}

/** Size of the tuple including size of struct tuple. */
static inline size_t
tuple_size(struct tuple *tuple)
{
	/* data_offset includes sizeof(struct tuple). */
	return tuple_data_offset(tuple) + tuple_bsize(tuple);
}

/**
 * Get pointer to MessagePack data of the tuple.
 * @param tuple tuple.
 * @return MessagePack array.
 */
static inline const char *
tuple_data(struct tuple *tuple)
{
	return (const char *)tuple + tuple_data_offset(tuple);
}

/**
 * Wrapper around tuple_data() which returns NULL if @tuple == NULL.
 */
static inline const char *
tuple_data_or_null(struct tuple *tuple)
{
	return tuple != NULL ? tuple_data(tuple) : NULL;
}

/**
 * Get pointer to MessagePack data of the tuple.
 * @param tuple tuple.
 * @param[out] size Size in bytes of the MessagePack array.
 * @return MessagePack array.
 */
static inline const char *
tuple_data_range(struct tuple *tuple, uint32_t *p_size)
{
	*p_size = tuple_bsize(tuple);
	return (const char *)tuple + tuple_data_offset(tuple);
}

/**
 * Format a tuple into string.
 * Example: [1, 2, "string"]
 * @param buf buffer to format tuple to
 * @param size buffer size. This function writes at most @a size bytes
 * (including the terminating null byte ('\0')) to @a buffer
 * @param tuple tuple to format
 * @retval the number of characters printed, excluding the null byte used
 * to end output to string. If the output was truncated due to this limit,
 * then the return value is the number of characters (excluding the
 * terminating null byte) which would have been written to the final string
 * if enough space had been available.
 * @see snprintf
 * @see mp_snprint
 */
int
tuple_snprint(char *buf, int size, struct tuple *tuple);

/**
 * Format a tuple into string using a static buffer.
 * Useful for debugger. Example: [1, 2, "string"]
 * @param tuple to format
 * @return formatted null-terminated string
 */
const char *
tuple_str(struct tuple *tuple);

/**
 * Format msgpack into string using a static buffer.
 * Useful for debugger. Example: [1, 2, "string"]
 * @param msgpack to format
 * @return formatted null-terminated string
 */
const char *
mp_str(const char *data);

/**
 * Get the format of the tuple.
 * @param tuple Tuple.
 * @retval Tuple format instance.
 */
static inline struct tuple_format *
tuple_format(struct tuple *tuple)
{
	struct tuple_format *format = tuple_format_by_id(tuple->format_id);
	assert(tuple_format_id(format) == tuple->format_id);
	return format;
}

/**
 * Instantiate a new engine-independent tuple from raw MsgPack Array data
 * using runtime arena. Use this function to create a standalone tuple
 * from Lua or C procedures.
 *
 * \param format tuple format.
 * \param data tuple data in MsgPack Array format ([field1, field2, ...]).
 * \param end the end of \a data
 * \retval tuple on success
 * \retval NULL on out of memory
 */
static inline struct tuple *
tuple_new(struct tuple_format *format, const char *data, const char *end)
{
	return format->vtab.tuple_new(format, data, end);
}

/**
 * Free the tuple of any engine.
 * @pre tuple->refs  == 0
 */
static inline void
tuple_delete(struct tuple *tuple)
{
	say_debug("%s(%p)", __func__, tuple);
	assert(tuple->refs == 0);
	struct tuple_format *format = tuple_format(tuple);
	format->vtab.tuple_delete(format, tuple);
}

/** Tuple chunk memory object. */
struct tuple_chunk {
	/** The payload size. Needed to perform memory release.*/
	uint32_t data_sz;
	/** Metadata object payload. */
	char data[0];
};

/** Calculate the size of tuple_chunk object by given data_sz. */
static inline uint32_t
tuple_chunk_sz(uint32_t data_sz)
{
	return sizeof(struct tuple_chunk) + data_sz;
}

/**
 * Allocate a new tuple_chunk for given tuple and data and
 * return a pointer to it's payload section.
 */
static inline const char *
tuple_chunk_new(struct tuple *tuple, const char *data, uint32_t data_sz)
{
	struct tuple_format *format = tuple_format(tuple);
	return format->vtab.tuple_chunk_new(format, tuple, data, data_sz);
}

/** Free a tuple_chunk allocated for given tuple and data. */
static inline void
tuple_chunk_delete(struct tuple *tuple, const char *data)
{
	struct tuple_format *format = tuple_format(tuple);
	format->vtab.tuple_chunk_delete(format, data);
}

/**
 * Check tuple data correspondence to space format.
 * Actually, checks everything that is checked by
 * tuple_field_map_create.
 *
 * @param format Format to which the tuple must match.
 * @param tuple  MessagePack array.
 *
 * @retval  0 The tuple is valid.
 * @retval -1 The tuple is invalid.
 */
int
tuple_validate_raw(struct tuple_format *format, const char *data);

/**
 * Check tuple data correspondence to the space format.
 * @param format Format to which the tuple must match.
 * @param tuple  Tuple to validate.
 *
 * @retval  0 The tuple is valid.
 * @retval -1 The tuple is invalid.
 */
static inline int
tuple_validate(struct tuple_format *format, struct tuple *tuple)
{
	return tuple_validate_raw(format, tuple_data(tuple));
}

/*
 * Return a field map for the tuple.
 * @param tuple tuple
 * @returns a field map for the tuple.
 * @sa tuple_field_map_create()
 */
static inline const uint8_t *
tuple_field_map(struct tuple *tuple)
{
	return (uint8_t *)tuple + tuple_data_offset(tuple);
}

/**
 * @brief Return the number of fields in tuple
 * @param tuple
 * @return the number of fields in tuple
 */
static inline uint32_t
tuple_field_count(struct tuple *tuple)
{
	const char *data = tuple_data(tuple);
	return mp_decode_array(&data);
}

/**
 * Retrieve msgpack data by JSON path.
 * @param data[in, out] Pointer to msgpack with data.
 *                      If the field cannot be retrieved be the
 *                      specified path @path, it is overwritten
 *                      with NULL.
 * @param path The path to process.
 * @param path_len The length of the @path.
 * @param multikey_idx The multikey index hint - index of
 *                     multikey index key to retrieve when array
 *                     index placeholder "[*]" is met.
 * @retval 0 On success.
 * @retval -1 In case of error in JSON path.
 */
int
tuple_go_to_path(const char **data, const char *path, uint32_t path_len,
		 int multikey_idx);

/**
 * Propagate @a field to MessagePack(field)[index].
 * @param[in][out] field Field to propagate.
 * @param index 0-based index to propagate to.
 *
 * @retval  0 Success, the index was found.
 * @retval -1 Not found.
 */
int
tuple_field_go_to_index(const char **field, uint64_t index);

/**
 * Propagate @a field to MessagePack(field)[key].
 * @param[in][out] field Field to propagate.
 * @param key Key to propagate to.
 * @param len Length of @a key.
 *
 * @retval  0 Success, the index was found.
 * @retval -1 Not found.
 */
int
tuple_field_go_to_key(const char **field, const char *key, int len);

/**
 * Get tuple field by field index, relative JSON path and
 * multikey_idx.
 * @param format Tuple format.
 * @param tuple MessagePack tuple's body.
 * @param field_map Tuple field map.
 * @param path Relative JSON path to field.
 * @param path_len Length of @a path.
 * @param offset_slot_hint The pointer to a variable that contains
 *                         an offset slot. May be NULL.
 *                         If specified AND value by pointer is
 *                         not TUPLE_OFFSET_SLOT_NIL is used to
 *                         access data in a single operation.
 *                         Else it is initialized with offset_slot
 *                         of format field by path.
 * @param multikey_idx The multikey index hint - index of
 *                     multikey item item to retrieve when array
 *                     index placeholder "[*]" is met.
 */
static inline const char *
tuple_field_raw_by_path(struct tuple_format *format, const char *tuple,
			const uint8_t *field_map, uint32_t fieldno,
			const char *path, uint32_t path_len,
			int32_t *offset_slot_hint, int multikey_idx,
			bool is_tiny)
{
	int32_t offset_slot;
	if (offset_slot_hint != NULL &&
	    *offset_slot_hint != TUPLE_OFFSET_SLOT_NIL) {
		offset_slot = *offset_slot_hint;
		goto offset_slot_access;
	}
	if (likely(fieldno < format->index_field_count)) {
		uint32_t offset;
		struct tuple_field *field;
		if (path == NULL && fieldno == 0) {
			mp_decode_array(&tuple);
			return tuple;
		}
		field = tuple_format_field_by_path(format, fieldno, path,
						   path_len);
		assert(field != NULL || path != NULL);
		if (path != NULL && field == NULL)
			goto parse;
		offset_slot = field->offset_slot;
		if (offset_slot == TUPLE_OFFSET_SLOT_NIL)
			goto parse;
		if (offset_slot_hint != NULL) {
			*offset_slot_hint = offset_slot;
			/*
			 * Hint is never requested for a multikey field without
			 * providing a concrete multikey index.
			 */
			assert(!field->is_multikey_part ||
			       multikey_idx != MULTIKEY_NONE);
		} else if (field->is_multikey_part &&
			   multikey_idx == MULTIKEY_NONE) {
			/*
			 * When the field is multikey, the offset slot points
			 * not at the data. It points at 'extra' array of
			 * offsets for this multikey index. That array can only
			 * be accessed if index in that array is known. It is
			 * not known when the field is accessed not in an index.
			 * For example, in an application's Lua code by a JSON
			 * path.
			 */
			goto parse;
		}
offset_slot_access:
		/* Indexed field */
		offset = field_map_get_offset(field_map, offset_slot,
					      multikey_idx, is_tiny);
		if (offset == 0)
			return NULL;
		tuple += offset;
	} else {
		uint32_t field_count;
parse:
		ERROR_INJECT(ERRINJ_TUPLE_FIELD, return NULL);
		field_count = mp_decode_array(&tuple);
		if (unlikely(fieldno >= field_count))
			return NULL;
		for (uint32_t k = 0; k < fieldno; k++)
			mp_next(&tuple);
		if (path != NULL &&
		    unlikely(tuple_go_to_path(&tuple, path, path_len,
					      multikey_idx) != 0))
			return NULL;
	}
	return tuple;
}

/**
 * Get a field at the specific position in this MessagePack array.
 * Returns a pointer to MessagePack data.
 * @param format tuple format
 * @param tuple a pointer to MessagePack array
 * @param field_map a pointer to the LAST element of field map
 * @param field_no the index of field to return
 *
 * @returns field data if field exists or NULL
 * @sa tuple_field_map_create()
 */
static inline const char *
tuple_field_raw(struct tuple_format *format, const char *tuple,
		const uint8_t *field_map, uint32_t field_no, bool is_tiny)
{
	if (likely(field_no < format->index_field_count)) {
		int32_t offset_slot;
		uint32_t offset = 0;
		struct tuple_field *field;
		if (field_no == 0) {
			mp_decode_array(&tuple);
			return tuple;
		}
		struct json_token *token = format->fields.root.children[field_no];
		field = json_tree_entry(token, struct tuple_field, token);
		offset_slot = field->offset_slot;
		if (offset_slot == TUPLE_OFFSET_SLOT_NIL)
			goto parse;
		offset = field_map_get_offset(field_map, offset_slot,
					      MULTIKEY_NONE, is_tiny);
		if (offset == 0)
			return NULL;
		tuple += offset;
	} else {
parse:
		ERROR_INJECT(ERRINJ_TUPLE_FIELD, return NULL);
		uint32_t field_count = mp_decode_array(&tuple);
		if (unlikely(field_no >= field_count))
			return NULL;
		for ( ; field_no > 0; field_no--)
			mp_next(&tuple);
	}
	return tuple;
}

/**
 * Get a field at the specific index in this tuple.
 * @param tuple tuple
 * @param fieldno the index of field to return
 * @param len pointer where the len of the field will be stored
 * @retval pointer to MessagePack data
 * @retval NULL when fieldno is out of range
 */
static inline const char *
tuple_field(struct tuple *tuple, uint32_t fieldno)
{
	return tuple_field_raw(tuple_format(tuple), tuple_data(tuple),
			       tuple_field_map(tuple), fieldno,
			       tuple_is_tiny(tuple));
}

/**
 * Get tuple field by full JSON path.
 * Unlike tuple_field_raw_by_path this function works with full
 * JSON paths, performing root field index resolve on its own.
 * When the first JSON path token has JSON_TOKEN_STR type, routine
 * uses tuple format dictionary to get field index by field name.
 * @param format Tuple format.
 * @param tuple MessagePack tuple's body.
 * @param field_map Tuple field map.
 * @param path Full JSON path to field.
 * @param path_len Length of @a path.
 * @param path_hash Hash of @a path.
 *
 * @retval field data if field exists or NULL
 */
const char *
tuple_field_raw_by_full_path(struct tuple_format *format, const char *tuple,
			     const uint8_t *field_map, const char *path,
			     uint32_t path_len, uint32_t path_hash,
			     bool is_tiny);

/**
 * Get a tuple field pointed to by an index part and multikey
 * index hint.
 * @param format Tuple format.
 * @param data A pointer to MessagePack array.
 * @param field_map A pointer to the LAST element of field map.
 * @param part Index part to use.
 * @param multikey_idx A multikey index hint.
 * @retval Field data if the field exists or NULL.
 */
static inline const char *
tuple_field_raw_by_part(struct tuple_format *format, const char *data,
			const uint8_t *field_map,
			struct key_part *part, int multikey_idx, bool is_tiny)
{
	if (unlikely(part->format_epoch != format->epoch)) {
		assert(format->epoch != 0);
		part->format_epoch = format->epoch;
		/*
		 * Clear the offset slot cache, since it's stale.
		 * The cache will be reset by the lookup.
		 */
		part->offset_slot_cache = TUPLE_OFFSET_SLOT_NIL;
	}
	return tuple_field_raw_by_path(format, data, field_map, part->fieldno,
				       part->path, part->path_len,
				       &part->offset_slot_cache, multikey_idx,
				       is_tiny);
}

/**
 * Get a field refereed by index @part in tuple.
 * @param tuple Tuple to get the field from.
 * @param part Index part to use.
 * @param multikey_idx A multikey index hint.
 * @retval Field data if the field exists or NULL.
 */
static inline const char *
tuple_field_by_part(struct tuple *tuple, struct key_part *part,
		    int multikey_idx)
{
	return tuple_field_raw_by_part(tuple_format(tuple), tuple_data(tuple),
				       tuple_field_map(tuple), part,
				       multikey_idx, tuple_is_tiny(tuple));
}

/**
 * Get count of multikey index keys in tuple by given multikey
 * index definition.
 * @param format Tuple format.
 * @param data A pointer to MessagePack array.
 * @param field_map A pointer to the LAST element of field map.
 * @param key_def Index key_definition.
 * @retval Count of multikey index keys in the given tuple.
 */
uint32_t
tuple_raw_multikey_count(struct tuple_format *format, const char *data,
			 const uint8_t *field_map, struct key_def *key_def,
			 bool is_tiny);

/**
 * Get count of multikey index keys in tuple by given multikey
 * index definition.
 * @param tuple Tuple to get the count of multikey keys from.
 * @param key_def Index key_definition.
 * @retval Count of multikey index keys in the given tuple.
 */
static inline uint32_t
tuple_multikey_count(struct tuple *tuple, struct key_def *key_def)
{
	return tuple_raw_multikey_count(tuple_format(tuple), tuple_data(tuple),
					tuple_field_map(tuple), key_def,
					tuple_is_tiny(tuple));
}

/**
 * @brief Tuple Interator
 */
struct tuple_iterator {
	/** @cond false **/
	/* State */
	struct tuple *tuple;
	/** Always points to the beginning of the next field. */
	const char *pos;
	/** End of the tuple. */
	const char *end;
	/** @endcond **/
	/** field no of the next field. */
	int fieldno;
};

/**
 * @brief Initialize an iterator over tuple fields
 *
 * A workflow example:
 * @code
 * struct tuple_iterator it;
 * tuple_rewind(&it, tuple);
 * const char *field;
 * uint32_t len;
 * while ((field = tuple_next(&it, &len)))
 *	lua_pushlstring(L, field, len);
 *
 * @endcode
 *
 * @param[out] it tuple iterator
 * @param[in]  tuple tuple
 */
static inline void
tuple_rewind(struct tuple_iterator *it, struct tuple *tuple)
{
	it->tuple = tuple;
	uint32_t bsize;
	const char *data = tuple_data_range(tuple, &bsize);
	it->pos = data;
	(void) mp_decode_array(&it->pos); /* Skip array header */
	it->fieldno = 0;
	it->end = data + bsize;
}

/**
 * @brief Position the iterator at a given field no.
 *
 * @retval field  if the iterator has the requested field
 * @retval NULL   otherwise (iteration is out of range)
 */
const char *
tuple_seek(struct tuple_iterator *it, uint32_t fieldno);

/**
 * @brief Iterate to the next field
 * @param it tuple iterator
 * @return next field or NULL if the iteration is out of range
 */
const char *
tuple_next(struct tuple_iterator *it);

/** Return a tuple field and check its type. */
static inline const char *
tuple_next_with_type(struct tuple_iterator *it, enum mp_type type)
{
	uint32_t fieldno = it->fieldno;
	const char *field = tuple_next(it);
	if (field == NULL) {
		diag_set(ClientError, ER_NO_SUCH_FIELD_NO, it->fieldno);
		return NULL;
	}
	enum mp_type actual_type = mp_typeof(*field);
	if (actual_type != type) {
		diag_set(ClientError, ER_FIELD_TYPE,
			 int2str(fieldno + TUPLE_INDEX_BASE),
			 mp_type_strs[type], mp_type_strs[actual_type]);
		return NULL;
	}
	return field;
}

/** Get next field from iterator as uint32_t. */
static inline int
tuple_next_u32(struct tuple_iterator *it, uint32_t *out)
{
	uint32_t fieldno = it->fieldno;
	const char *field = tuple_next_with_type(it, MP_UINT);
	if (field == NULL)
		return -1;
	uint64_t val = mp_decode_uint(&field);
	*out = val;
	if (val > UINT32_MAX) {
		diag_set(ClientError, ER_FIELD_TYPE,
			 int2str(fieldno + TUPLE_INDEX_BASE),
			 "uint32_t",
			 "uint64_t");
		return -1;
	}
	return 0;
}

/** Get next field from iterator as uint64_t. */
static inline int
tuple_next_u64(struct tuple_iterator *it, uint64_t *out)
{
	const char *field = tuple_next_with_type(it, MP_UINT);
	if (field == NULL)
		return -1;
	*out = mp_decode_uint(&field);
	return 0;
}

/**
 * Assert that buffer is valid MessagePack array
 * @param tuple buffer
 * @param the end of the buffer
 */
static inline void
mp_tuple_assert(const char *tuple, const char *tuple_end)
{
	assert(mp_typeof(*tuple) == MP_ARRAY);
#ifndef NDEBUG
	mp_next(&tuple);
#endif
	assert(tuple == tuple_end);
	(void) tuple;
	(void) tuple_end;
}

static inline const char *
tuple_field_with_type(struct tuple *tuple, uint32_t fieldno, enum mp_type type)
{
	const char *field = tuple_field(tuple, fieldno);
	if (field == NULL) {
		diag_set(ClientError, ER_NO_SUCH_FIELD_NO,
			 fieldno + TUPLE_INDEX_BASE);
		return NULL;
	}
	enum mp_type actual_type = mp_typeof(*field);
	if (actual_type != type) {
		diag_set(ClientError, ER_FIELD_TYPE,
			 int2str(fieldno + TUPLE_INDEX_BASE),
			 mp_type_strs[type], mp_type_strs[actual_type]);
		return NULL;
	}
	return field;
}

/**
 * A convenience shortcut for data dictionary - get a tuple field
 * as bool.
 */
static inline int
tuple_field_bool(struct tuple *tuple, uint32_t fieldno, bool *out)
{
	const char *field = tuple_field_with_type(tuple, fieldno, MP_BOOL);
	if (field == NULL)
		return -1;
	*out = mp_decode_bool(&field);
	return 0;
}

/**
 * A convenience shortcut for data dictionary - get a tuple field
 * as int64_t.
 */
static inline int
tuple_field_i64(struct tuple *tuple, uint32_t fieldno, int64_t *out)
{
	const char *field = tuple_field(tuple, fieldno);
	if (field == NULL) {
		diag_set(ClientError, ER_NO_SUCH_FIELD_NO, fieldno);
		return -1;
	}
	uint64_t val;
	enum mp_type actual_type = mp_typeof(*field);
	switch (actual_type) {
	case MP_INT:
		*out = mp_decode_int(&field);
		break;
	case MP_UINT:
		val = mp_decode_uint(&field);
		if (val <= INT64_MAX) {
			*out = val;
			break;
		}
		FALLTHROUGH;
	default:
		diag_set(ClientError, ER_FIELD_TYPE,
			 int2str(fieldno + TUPLE_INDEX_BASE),
			 field_type_strs[FIELD_TYPE_INTEGER],
			 mp_type_strs[actual_type]);
		return -1;
	}
	return 0;
}

/**
 * A convenience shortcut for data dictionary - get a tuple field
 * as uint64_t.
 */
static inline int
tuple_field_u64(struct tuple *tuple, uint32_t fieldno, uint64_t *out)
{
	const char *field = tuple_field_with_type(tuple, fieldno, MP_UINT);
	if (field == NULL)
		return -1;
	*out = mp_decode_uint(&field);
	return 0;
}

/**
 * A convenience shortcut for data dictionary - get a tuple field
 * as uint32_t.
 */
static inline int
tuple_field_u32(struct tuple *tuple, uint32_t fieldno, uint32_t *out)
{
	const char *field = tuple_field_with_type(tuple, fieldno, MP_UINT);
	if (field == NULL)
		return -1;
	uint64_t val = mp_decode_uint(&field);
	*out = val;
	if (val > UINT32_MAX) {
		diag_set(ClientError, ER_FIELD_TYPE,
			 int2str(fieldno + TUPLE_INDEX_BASE),
			 "uint32_t", "uint64_t");
		return -1;
	}
	return 0;
}

/**
 * A convenience shortcut for data dictionary - get a tuple field
 * as a string.
 */
static inline const char *
tuple_field_str(struct tuple *tuple, uint32_t fieldno, uint32_t *len)
{
	const char *field = tuple_field_with_type(tuple, fieldno, MP_STR);
	if (field == NULL)
		return NULL;
	return mp_decode_str(&field, len);
}

/**
 * A convenience shortcut for data dictionary - get a tuple field
 * as a NUL-terminated string - returns a string of up to 256 bytes.
 */
static inline const char *
tuple_field_cstr(struct tuple *tuple, uint32_t fieldno)
{
	uint32_t len;
	const char *str = tuple_field_str(tuple, fieldno, &len);
	if (str == NULL)
		return NULL;
	return tt_cstr(str, len);
}

/**
 * Parse a tuple field which is expected to contain a string
 * representation of UUID, and return a 16-byte representation.
 */
static inline int
tuple_field_uuid(struct tuple *tuple, int fieldno, struct tt_uuid *out)
{
	const char *value = tuple_field_cstr(tuple, fieldno);
	if (tt_uuid_from_string(value, out) != 0) {
		diag_set(ClientError, ER_INVALID_UUID, value);
		return -1;
	}
	return 0;
}

enum { TUPLE_REF_MAX = UINT16_MAX >> 1 };

/**
 * Increase tuple big reference counter.
 * @param tuple Tuple to reference.
 */
void
tuple_ref_slow(struct tuple *tuple);

/**
 * Increment tuple reference counter.
 * @param tuple Tuple to reference.
 */
static inline void
tuple_ref(struct tuple *tuple)
{
	if (unlikely(tuple->refs >= TUPLE_REF_MAX))
		tuple_ref_slow(tuple);
	else
		tuple->refs++;
}

/**
 * Decrease tuple big reference counter.
 * @param tuple Tuple to reference.
 */
void
tuple_unref_slow(struct tuple *tuple);

/**
 * Decrement tuple reference counter. If it has reached zero, free the tuple.
 *
 * @pre tuple->refs + count >= 0
 */
static inline void
tuple_unref(struct tuple *tuple)
{
	assert(tuple->refs - 1 >= 0);
	if (unlikely(tuple->is_bigref))
		tuple_unref_slow(tuple);
	else if (--tuple->refs == 0) {
		assert(!tuple_is_dirty(tuple));
		tuple_delete(tuple);
	}
}

extern struct tuple *box_tuple_last;

/**
 * Convert internal `struct tuple` to public `box_tuple_t`.
 * \retval tuple
 * \post \a tuple ref counted until the next call.
 * \sa tuple_ref
 */
static inline box_tuple_t *
tuple_bless(struct tuple *tuple)
{
	assert(tuple != NULL);
	tuple_ref(tuple);
	/* Remove previous tuple */
	if (likely(box_tuple_last != NULL))
		tuple_unref(box_tuple_last);
	/* Remember current tuple */
	box_tuple_last = tuple;
	return tuple;
}

/**
 * \copydoc box_tuple_to_buf()
 */
ssize_t
tuple_to_buf(struct tuple *tuple, char *buf, size_t size);

#if defined(__cplusplus)
} /* extern "C" */

#include "xrow_update.h"
#include "errinj.h"

/* @copydoc tuple_field_u32() */
static inline uint32_t
tuple_field_u32_xc(struct tuple *tuple, uint32_t fieldno)
{
	uint32_t out;
	if (tuple_field_u32(tuple, fieldno, &out) != 0)
		diag_raise();
	return out;
}

#endif /* defined(__cplusplus) */

#endif /* TARANTOOL_BOX_TUPLE_H_INCLUDED */

