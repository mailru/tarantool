#ifndef TARANTOOL_BOX_REQUEST_H_INCLUDED
#define TARANTOOL_BOX_REQUEST_H_INCLUDED
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
#include <stdbool.h>
#include <stdint.h>

#include "trivia/util.h"

#include "diag.h"

#if defined(__cplusplus)
extern "C" {
#endif /* defined(__cplusplus) */

struct txn;
struct port;
struct tuple;
struct iovec;

/** box statistics */
extern struct rmean *rmean_box;

struct request
{
	/*
	 * Either log row, or network header, or NULL, depending
	 * on where this packet originated from: the write ahead
	 * log/snapshot, client request, or a Lua request.
	 */
	struct xrow_header *header;
	/**
	 * Request type - IPROTO type code
	 */
	uint32_t type;
	uint32_t space_id;
	uint32_t index_id;
	uint32_t offset;
	uint32_t limit;
	uint32_t iterator;
	/** Search key or proc name. */
	const char *key;
	const char *key_end;
	/** Insert/replace/upsert tuple or proc argument or update operations. */
	const char *tuple;
	const char *tuple_end;
	/** Upsert operations. */
	const char *ops;
	const char *ops_end;
	/** Base field offset for UPDATE/UPSERT, e.g. 0 for C and 1 for Lua. */
	int index_base;
};

/**
 * Initialize a request for @a code
 * @param request request
 * @param code see `enum iproto_type`
 */
void
request_create(struct request *request, uint32_t code);

/**
 * Decode @a data buffer
 * @param request request to fill up
 * @param data a buffer
 * @param len a buffer size
 * @retval 0 on success
 * @retval -1 on error, see diag
 */
int
request_decode(struct request *request, const char *data, uint32_t len);

/**
 * Encode the request fields to iovec using region_alloc().
 * @param request request to encode
 * @param iov[out] iovec to fill
 * @retval -1 on error, see diag
 * @retval > 0 the number of iovecs used
 */
int
request_encode(struct request *request, struct iovec *iov);

#if defined(__cplusplus)
} /* extern "C" */

/** The snapshot row metadata repeats the structure of REPLACE request. */
struct PACKED request_replace_body {
	uint8_t m_body;
	uint8_t k_space_id;
	uint8_t m_space_id;
	uint32_t v_space_id;
	uint8_t k_tuple;
};

static inline void
request_decode_xc(struct request *request, const char *data, uint32_t len)
{
	if (request_decode(request, data, len) < 0)
		diag_raise();
}

static inline int
request_encode_xc(struct request *request, struct iovec *iov)
{
	int iovcnt = request_encode(request, iov);
	if (iovcnt < 0)
		diag_raise();
	return iovcnt;
}

/**
 * Convert secondary key of request to primary key by given tuple.
 * Flush iproto header of the request to be reconstructed in the future.
 * @param request - request to fix
 * @param space - space corresponding to request
 * @param found_tuple - tuple found by secondary key
 */
void
request_rebind_to_primary_key(struct request *request, struct space *space,
			      struct tuple *found_tuple);

/**
 * Convert one-based upsert/update operations to zero-based
 *
 * @param request a request to convert
 * @pre request->type == IPROTO_UPDATE || request->type == IPROTO_UPSERT
 * @pre request->index_base != 0
 * @pre request->ops are valid (see tuple_update_check_ops())
 * @post request->index_base = 0
 */
void
request_normalize_ops(struct request *request);


#endif /* defined(__cplusplus) */

#endif /* TARANTOOL_BOX_REQUEST_H_INCLUDED */
