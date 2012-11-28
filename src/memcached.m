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
#include "memcached.h"
#include "tarantool.h"

#include <limits.h>

#include "box/box.h"
#include "box/request.h"
#include "box/space.h"
#include "box/port.h"
#include "box/tuple.h"
#include "fiber.h"
#include "cfg/warning.h"
#include  TARANTOOL_CONFIG
#include "say.h"
#include "stat.h"
#include "salloc.h"
#include "pickle.h"
#include "coio_buf.h"

#define STAT(_)					\
        _(MEMC_GET, 1)				\
        _(MEMC_GET_MISS, 2)			\
	_(MEMC_GET_HIT, 3)			\
	_(MEMC_EXPIRED_KEYS, 4)

ENUM(memcached_stat, STAT);
STRS(memcached_stat, STAT);

static int stat_base;
static struct fiber *memcached_expire = NULL;

static Index *memcached_index;
static struct iterator *memcached_it;

/* memcached tuple format:
   <key, meta, data> */

struct meta {
	u32 exptime;
	u32 flags;
	u64 cas;
} __packed__;

static u64
natoq(const char *start, const char *end)
{
	u64 num = 0;
	while (start < end) {
		u8 code = *start++;
		num = num * 10 + (code - '0');
	}
	return num;
}

static void
store(void *key, u32 exptime, u32 flags, u32 bytes, const char *data)
{
	u32 box_flags = 0;
	u32 field_count = 4;
	static u64 cas = 42;
	struct meta m;

	struct tbuf *req = tbuf_alloc(fiber->gc_pool);

	tbuf_append(req, &cfg.memcached_space, sizeof(u32));
	tbuf_append(req, &box_flags, sizeof(box_flags));
	tbuf_append(req, &field_count, sizeof(field_count));

	tbuf_append_field(req, key);

	m.exptime = exptime;
	m.flags = flags;
	m.cas = cas++;
	write_varint32(req, sizeof(m));
	tbuf_append(req, &m, sizeof(m));

	char b[43];
	sprintf(b, " %"PRIu32" %"PRIu32"\r\n", flags, bytes);
	write_varint32(req, strlen(b));
	tbuf_append(req, b, strlen(b));

	write_varint32(req, bytes);
	tbuf_append(req, data, bytes);

	int key_len = load_varint32(&key);
	say_debug("memcached/store key:(%i)'%.*s' exptime:%"PRIu32" flags:%"PRIu32" cas:%"PRIu64,
		  key_len, key_len, (char*) key, exptime, flags, cas);
	/*
	 * Use a box dispatch wrapper which handles correctly
	 * read-only/read-write modes.
	 */
	mod_process(&port_null, REPLACE, req);
}

static void
delete(void *key)
{
	u32 key_len = 1;
	u32 box_flags = 0;
	struct tbuf *req = tbuf_alloc(fiber->gc_pool);

	tbuf_append(req, &cfg.memcached_space, sizeof(u32));
	tbuf_append(req, &box_flags, sizeof(box_flags));
	tbuf_append(req, &key_len, sizeof(key_len));
	tbuf_append_field(req, key);

	mod_process(&port_null, DELETE, req);
}

static struct tuple *
find(void *key)
{
	return [memcached_index findByKey :key :1];
}

static struct meta *
meta(struct tuple *tuple)
{
	void *field = tuple_field(tuple, 1);
	return field + 1;
}

static bool
expired(struct tuple *tuple)
{
	struct meta *m = meta(tuple);
	return m->exptime == 0 ? 0 : m->exptime < ev_now();
}

static bool
is_numeric(void *field, u32 value_len)
{
	for (int i = 0; i < value_len; i++)
		if (*((u8 *)field + i) < '0' || '9' < *((u8 *)field + i))
			return false;
	return true;
}

static struct stats {
	u64 total_items;
	u32 curr_connections;
	u32 total_connections;
	u64 cmd_get;
	u64 cmd_set;
	u64 get_hits;
	u64 get_misses;
	u64 evictions;
	u64 bytes_read;
	u64 bytes_written;
} stats;

struct salloc_stat_memcached_cb_ctx {
	i64 bytes_used;
	i64 items;
};

static int
salloc_stat_memcached_cb(const struct slab_class_stats *cstat, void *cb_ctx)
{
	struct salloc_stat_memcached_cb_ctx *ctx = cb_ctx;
	ctx->bytes_used	+= cstat->bytes_used;
	ctx->items	+= cstat->items;
	return 0;
}

static void
print_stats(struct obuf *out)
{
	struct tbuf *buf = tbuf_alloc(fiber->gc_pool);

	struct salloc_stat_memcached_cb_ctx memstats;
	memstats.bytes_used = memstats.items = 0;
	salloc_stat(salloc_stat_memcached_cb, NULL, &memstats);

	tbuf_printf(buf, "STAT pid %"PRIu32"\r\n", (u32)getpid());
	tbuf_printf(buf, "STAT uptime %"PRIu32"\r\n", (u32)tarantool_uptime());
	tbuf_printf(buf, "STAT time %"PRIu32"\r\n", (u32)ev_now());
	tbuf_printf(buf, "STAT version 1.2.5 (tarantool/box)\r\n");
	tbuf_printf(buf, "STAT pointer_size %"PRI_SZ"\r\n", sizeof(void *)*8);
	tbuf_printf(buf, "STAT curr_items %"PRIu64"\r\n", memstats.items);
	tbuf_printf(buf, "STAT total_items %"PRIu64"\r\n", stats.total_items);
	tbuf_printf(buf, "STAT bytes %"PRIu64"\r\n", memstats.bytes_used);
	tbuf_printf(buf, "STAT curr_connections %"PRIu32"\r\n", stats.curr_connections);
	tbuf_printf(buf, "STAT total_connections %"PRIu32"\r\n", stats.total_connections);
	tbuf_printf(buf, "STAT connection_structures %"PRIu32"\r\n", stats.curr_connections); /* lie a bit */
	tbuf_printf(buf, "STAT cmd_get %"PRIu64"\r\n", stats.cmd_get);
	tbuf_printf(buf, "STAT cmd_set %"PRIu64"\r\n", stats.cmd_set);
	tbuf_printf(buf, "STAT get_hits %"PRIu64"\r\n", stats.get_hits);
	tbuf_printf(buf, "STAT get_misses %"PRIu64"\r\n", stats.get_misses);
	tbuf_printf(buf, "STAT evictions %"PRIu64"\r\n", stats.evictions);
	tbuf_printf(buf, "STAT bytes_read %"PRIu64"\r\n", stats.bytes_read);
	tbuf_printf(buf, "STAT bytes_written %"PRIu64"\r\n", stats.bytes_written);
	tbuf_printf(buf, "STAT limit_maxbytes %"PRIu64"\r\n", (u64)(cfg.slab_alloc_arena * (1 << 30)));
	tbuf_printf(buf, "STAT threads 1\r\n");
	tbuf_printf(buf, "END\r\n");
	obuf_dup(out, buf->data, buf->size);
}

void memcached_get(struct obuf *out, size_t keys_count, struct tbuf *keys,
		   bool show_cas)
{
	stat_collect(stat_base, MEMC_GET, 1);
	stats.cmd_get++;
	say_debug("ensuring space for %"PRI_SZ" keys", keys_count);
	while (keys_count-- > 0) {
		struct tuple *tuple;
		struct meta *m;
		void *field;
		void *value;
		void *suffix;
		u32 key_len;
		u32 value_len;
		u32 suffix_len;
		u32 _l;

		void *key = read_field(keys);
		tuple = find(key);
		key_len = load_varint32(&key);

		if (tuple == NULL) {
			stat_collect(stat_base, MEMC_GET_MISS, 1);
			stats.get_misses++;
			continue;
		}

		field = tuple->data;

		/* skip key */
		_l = load_varint32(&field);
		field += _l;

		/* metainfo */
		_l = load_varint32(&field);
		m = field;
		field += _l;

		/* suffix */
		suffix_len = load_varint32(&field);
		suffix = field;
		field += suffix_len;

		/* value */
		value_len = load_varint32(&field);
		value = field;

		if (m->exptime > 0 && m->exptime < ev_now()) {
			stats.get_misses++;
			stat_collect(stat_base, MEMC_GET_MISS, 1);
			continue;
		}
		stats.get_hits++;
		stat_collect(stat_base, MEMC_GET_HIT, 1);

		if (show_cas) {
			struct tbuf *b = tbuf_alloc(fiber->gc_pool);
			tbuf_printf(b, "VALUE %.*s %"PRIu32" %"PRIu32" %"PRIu64"\r\n", key_len, (char*) key, m->flags, value_len, m->cas);
			obuf_dup(out, b->data, b->size);
			stats.bytes_written += b->size;
		} else {
			obuf_dup(out, "VALUE ", 6);
			obuf_dup(out, key, key_len);
			obuf_dup(out, suffix, suffix_len);
		}
		obuf_dup(out, value, value_len);
		obuf_dup(out, "\r\n", 2);
		stats.bytes_written += value_len + 2;
	}
	obuf_dup(out, "END\r\n", 5);
	stats.bytes_written += 5;
}

static void
flush_all(va_list ap)
{
	uintptr_t delay = va_arg(ap, uintptr_t);
	fiber_sleep(delay - ev_now());
	struct tuple *tuple;
	struct iterator *it = [memcached_index allocIterator];
	[memcached_index initIterator: it :ITER_ALL :NULL :0];
	while ((tuple = it->next(it))) {
	       meta(tuple)->exptime = 1;
	}
	it->free(it);
}

#define STORE									\
do {										\
	stats.cmd_set++;							\
	if (bytes > (1<<20)) {							\
		obuf_dup(out, "SERVER_ERROR object too large for cache\r\n", 41);\
	} else {								\
		@try {								\
			store(key, exptime, flags, bytes, data);		\
			stats.total_items++;					\
			obuf_dup(out, "STORED\r\n", 8);				\
		}								\
		@catch (ClientError *e) {					\
			obuf_dup(out, "SERVER_ERROR ", 13);			\
			obuf_dup(out, e->errmsg, strlen(e->errmsg));		\
			obuf_dup(out, "\r\n", 2);				\
		}								\
	}									\
} while (0)

#include "memcached-grammar.m"

void
memcached_loop(struct ev_io *coio, struct iobuf *iobuf)
{
	int rc;
	int bytes_written;
	int batch_count;
	struct ibuf *in = &iobuf->in;

	for (;;) {
		batch_count = 0;
		if (coio_bread(coio, in, 1) <= 0)
			return;

	dispatch:
		rc = memcached_dispatch(coio, iobuf);
		if (rc < 0) {
			say_debug("negative dispatch, closing connection");
			return;
		}

		if (rc == 0 && batch_count == 0) /* we haven't successfully parsed any requests */
			continue;

		if (rc == 1) {
			batch_count++;
			/* some unparsed commands remain and batch count less than 20 */
			if (ibuf_size(in) > 0 && batch_count < 20)
				goto dispatch;
		}

		bytes_written = iobuf_flush(iobuf, coio);
		fiber_gc();
		stats.bytes_written += bytes_written;

		if (rc == 1 && ibuf_size(in) > 0) {
			batch_count = 0;
			goto dispatch;
		}
	}
}

static void
memcached_handler(va_list ap)
{
	struct ev_io coio = va_arg(ap, struct ev_io);
	struct iobuf *iobuf = va_arg(ap, struct iobuf *);
	stats.total_connections++;
	stats.curr_connections++;

	@try {
		memcached_loop(&coio, iobuf);
		iobuf_flush(iobuf, &coio);
	} @catch (FiberCancelException *e) {
		@throw;
	} @catch (tnt_Exception *e) {
		[e log];
	} @finally {
		fiber_sleep(0.01);
		stats.curr_connections--;
		evio_close(&coio);
		iobuf_destroy(iobuf);
	}
}

int
memcached_check_config(struct tarantool_cfg *conf)
{
	if (conf->memcached_port == 0) {
		return 0;
	}

	if (conf->memcached_port <= 0 || conf->memcached_port >= USHRT_MAX) {
		/* invalid space number */
		out_warning(0, "invalid memcached port value: %i",
			    conf->memcached_port);
		return -1;
	}

	/* check memcached space number: it shoud be in segment [0, max_space] */

	if (conf->memcached_expire_per_loop <= 0) {
		/* invalid expire per loop value */
		out_warning(0, "invalid expire per loop value: %i",
			    conf->memcached_expire_per_loop);
		return -1;
	}

	if (conf->memcached_expire_full_sweep <= 0) {
		/* invalid expire full sweep value */
		out_warning(0, "invalid expire full sweep value: %i",
			    conf->memcached_expire_full_sweep);
		return -1;
	}

	return 0;
}

static void
memcached_free(void)
{
	if (memcached_it)
		memcached_it->free(memcached_it);
}


void
memcached_init(const char *bind_ipaddr, int memcached_port)
{
	if (memcached_port == 0)
		return;

	atexit(memcached_free);

	stat_base = stat_register(memcached_stat_strs, memcached_stat_MAX);

	struct space *sp = space_by_n(cfg.memcached_space);
	memcached_index = space_index(sp, 0);

	/* run memcached server */
	static struct coio_service memcached;
	coio_service_init(&memcached, "memcached",
			  bind_ipaddr, memcached_port,
			  memcached_handler, NULL);
	evio_service_start(&memcached.evio_service);
}

void
memcached_space_init()
{
        if (cfg.memcached_port == 0)
                return;


	/* Configure memcached index key. */
	struct key_def *key_def = malloc(sizeof(struct key_def));
	key_def->part_count = 1;
	key_def->is_unique = true;

	key_def->parts = malloc(sizeof(struct key_part));
	key_def->cmp_order = malloc(sizeof(u32));

	if (key_def->parts == NULL || key_def->cmp_order == NULL)
		panic("out of memory when configuring memcached_space");

	key_def->parts[0].fieldno = 0;
	key_def->parts[0].type = STRING;

	key_def->max_fieldno = 1;
	key_def->cmp_order[0] = 0;


	struct space *memc_s =
		space_create(cfg.memcached_space, key_def, 1, 4);

	Index *memc_index = [Index alloc: HASH :key_def :memc_s];
	space_set_index(memc_s, 0, memc_index);

	[memc_index init: key_def :memc_s];
}

/** Delete a bunch of expired keys. */

void
memcached_delete_expired_keys(struct tbuf *keys_to_delete)
{
	int expired_keys = 0;

	while (keys_to_delete->size > 0) {
		@try {
			delete(read_field(keys_to_delete));
			expired_keys++;
		}
		@catch (ClientError *e) {
			/* expire is off when replication is on */
			assert(e->errcode != ER_NONMASTER);
			/* The error is already logged. */
		}
	}
	stat_collect(stat_base, MEMC_EXPIRED_KEYS, expired_keys);

	double delay = ((double) cfg.memcached_expire_per_loop *
			cfg.memcached_expire_full_sweep /
			([memcached_index size] + 1));
	if (delay > 1)
		delay = 1;
	fiber_setcancellable(true);
	fiber_sleep(delay);
	fiber_setcancellable(false);
}

void
memcached_expire_loop(va_list ap __attribute__((unused)))
{
	struct tuple *tuple = NULL;

	say_info("memcached expire fiber started");
	memcached_it = [memcached_index allocIterator];
	@try {
restart:
		if (tuple == NULL)
			[memcached_index initIterator: memcached_it :ITER_ALL :NULL :0];

		struct tbuf *keys_to_delete = tbuf_alloc(fiber->gc_pool);

		for (int j = 0; j < cfg.memcached_expire_per_loop; j++) {

			tuple = memcached_it->next(memcached_it);

			if (tuple == NULL)
				break;

			if (!expired(tuple))
				continue;

			say_debug("expire tuple %p", tuple);
			tbuf_append_field(keys_to_delete, tuple->data);
		}
		memcached_delete_expired_keys(keys_to_delete);
		fiber_gc();
		goto restart;
	} @finally {
		memcached_it->free(memcached_it);
		memcached_it = NULL;
	}
}

void memcached_start_expire()
{
	if (cfg.memcached_port == 0 || cfg.memcached_expire == 0)
		return;

	assert(memcached_expire == NULL);
	@try {
		memcached_expire = fiber_create("memcached_expire",
						memcached_expire_loop);
	} @catch (tnt_Exception *e) {
		say_error("can't start the expire fiber");
		return;
	}
	fiber_call(memcached_expire);
}

void memcached_stop_expire()
{
	if (cfg.memcached_port == 0 || cfg.memcached_expire == 0)
		return;
	assert(memcached_expire != NULL);
	fiber_cancel(memcached_expire);
	memcached_expire = NULL;
}
