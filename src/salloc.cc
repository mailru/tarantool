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
#include "salloc.h"

#include "tarantool/config.h"
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

#include "third_party/valgrind/memcheck.h"
#include <third_party/queue.h>
#include "tarantool/util.h"
#include <tbuf.h>
#include <say.h>
#include "exception.h"

#define SLAB_ALIGN_PTR(ptr) (void *)((uintptr_t)(ptr) & ~(SLAB_SIZE - 1))

#ifdef SLAB_DEBUG
#undef NDEBUG
uint8_t red_zone[4] = { 0xfa, 0xfa, 0xfa, 0xfa };
#else
uint8_t red_zone[0] = { };
#endif

static const uint32_t SLAB_MAGIC = 0x51abface;
static const size_t SLAB_SIZE = 1 << 22;
static const size_t MAX_SLAB_ITEM = 1 << 20;

/* maximum number of items in one slab */
/* updated in slab_classes_init, depends on salloc_init params */
size_t MAX_SLAB_ITEM_COUNT;

struct slab_item {
    SLIST_ENTRY(slab_item) next;
};

SLIST_HEAD(item_slist_head, slab_item);

struct slab {
	uint32_t magic;
	size_t used;
	size_t items;
	struct item_slist_head free;
	struct slab_cache *cache;
	void *brk;
	SLIST_ENTRY(slab) link;
	SLIST_ENTRY(slab) free_link;
	TAILQ_ENTRY(slab) cache_free_link;
	TAILQ_ENTRY(slab) cache_link;
};

SLIST_HEAD(slab_slist_head, slab);
TAILQ_HEAD(slab_tailq_head, slab);

struct slab_cache {
	size_t item_size;
	struct slab_tailq_head slabs, free_slabs;
};

struct arena {
	void *mmap_base;
	size_t mmap_size;
	/** How items tuples do we have stacked for delayed free. */
	int64_t delayed_free_count;
	/** How many items in the delayed free list to free at once. */
	size_t delayed_free_batch;
	void *base;
	size_t size;
	size_t used;
	struct slab_slist_head slabs, free_slabs;
};

static uint32_t slab_active_caches;
/**
 * Delayed garbage collection for items which are used
 * in a forked process.
 */
static struct item_slist_head free_delayed;
static struct slab_cache slab_caches[256];
static struct arena arena;

static struct slab *
slab_header(void *ptr)
{
	struct slab *slab = (struct slab *) SLAB_ALIGN_PTR(ptr);
	assert(slab->magic == SLAB_MAGIC);
	return slab;
}

static void
slab_caches_init(size_t minimal, double factor)
{
	uint32_t i;
	size_t size;
	const size_t ptr_size = sizeof(void *);

	for (i = 0, size = minimal; i < nelem(slab_caches) && size <= MAX_SLAB_ITEM; i++) {
		slab_caches[i].item_size = size - sizeof(red_zone);
		TAILQ_INIT(&slab_caches[i].free_slabs);

		size = MAX((size_t)(size * factor) & ~(ptr_size - 1),
			   (size + ptr_size) & ~(ptr_size - 1));
	}

	slab_active_caches = i;

	MAX_SLAB_ITEM_COUNT = (size_t) (SLAB_SIZE - sizeof(struct slab)) /
			slab_caches[0].item_size;

	SLIST_INIT(&free_delayed);
}

static bool
arena_init(struct arena *arena, size_t size)
{
	arena->delayed_free_batch = 100;
	arena->delayed_free_count = 0;

	arena->used = 0;
	arena->size = size - size % SLAB_SIZE;
	arena->mmap_size = size - size % SLAB_SIZE + SLAB_SIZE;	/* spend SLAB_SIZE bytes on align :-( */

	arena->mmap_base = mmap(NULL, arena->mmap_size,
				PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
	if (arena->mmap_base == MAP_FAILED) {
		say_syserror("mmap");
		return false;
	}

	arena->base = (char *)SLAB_ALIGN_PTR(arena->mmap_base) + SLAB_SIZE;
	SLIST_INIT(&arena->slabs);
	SLIST_INIT(&arena->free_slabs);

	return true;
}

/**
 * Protect slab arena from changes. A safeguard used in a forked
 * process to prevent changes to the master process arena.
 */
void
salloc_protect(void)
{
	mprotect(arena.mmap_base, arena.mmap_size, PROT_READ);
}

static void *
arena_alloc(struct arena *arena)
{
	void *ptr;
	const size_t size = SLAB_SIZE;

	if (arena->size - arena->used < size)
		return NULL;

	ptr = (char *)arena->base + arena->used;
	arena->used += size;

	return ptr;
}

bool
salloc_init(size_t size, size_t minimal, double factor)
{
	if (size < SLAB_SIZE * 2)
		return false;

	if (!arena_init(&arena, size))
		return false;

	slab_caches_init(MAX(sizeof(void *), minimal), factor);
	return true;
}

void
salloc_free(void)
{
	if (arena.mmap_base != NULL)
		munmap(arena.mmap_base, arena.mmap_size);
	memset(&arena, 0, sizeof(struct arena));
}

static void
format_slab(struct slab_cache *cache, struct slab *slab)
{
	assert(cache->item_size <= MAX_SLAB_ITEM);

	slab->magic = SLAB_MAGIC;
	SLIST_INIT(&slab->free);
	slab->cache = cache;
	slab->items = 0;
	slab->used = 0;
	slab->brk = (char *)CACHEALIGN((char *)slab + sizeof(struct slab));

	TAILQ_INSERT_HEAD(&cache->slabs, slab, cache_link);
	TAILQ_INSERT_HEAD(&cache->free_slabs, slab, cache_free_link);
}

static bool
fully_formatted(struct slab *slab)
{
	return (char *) slab->brk + slab->cache->item_size >= (char *)slab + SLAB_SIZE;
}

void
slab_validate(void)
{
	struct slab *slab;

	SLIST_FOREACH(slab, &arena.slabs, link) {
		for (char *p = (char *)slab + sizeof(struct slab);
		     p + slab->cache->item_size < (char *)slab + SLAB_SIZE;
		     p += slab->cache->item_size + sizeof(red_zone)) {
			assert(memcmp(p + slab->cache->item_size, red_zone, sizeof(red_zone)) == 0);
		}
	}
}

static struct slab_cache *
cache_for(size_t size)
{
	for (uint32_t i = 0; i < slab_active_caches; i++)
		if (slab_caches[i].item_size >= size)
			return &slab_caches[i];

	return NULL;
}

static struct slab *
slab_of(struct slab_cache *cache)
{
	struct slab *slab;

	if (!TAILQ_EMPTY(&cache->free_slabs)) {
		slab = TAILQ_FIRST(&cache->free_slabs);
		assert(slab->magic == SLAB_MAGIC);
		return slab;
	}

	if (!SLIST_EMPTY(&arena.free_slabs)) {
		slab = SLIST_FIRST(&arena.free_slabs);
		assert(slab->magic == SLAB_MAGIC);
		SLIST_REMOVE_HEAD(&arena.free_slabs, free_link);
		format_slab(cache, slab);
		return slab;
	}

	if ((slab = (struct slab *) arena_alloc(&arena)) != NULL) {
		format_slab(cache, slab);
		SLIST_INSERT_HEAD(&arena.slabs, slab, link);
		return slab;
	}

	return NULL;
}

#ifndef NDEBUG
static bool
valid_item(struct slab *slab, void *item)
{
	return (char *)item >= (char *)(slab) + sizeof(struct slab) &&
	    (char *)item < (char *)(slab) + sizeof(struct slab) + SLAB_SIZE;
}
#endif

void
sfree(void *ptr)
{
	struct slab *slab = slab_header(ptr);
	struct slab_cache *cache = slab->cache;
	struct slab_item *item = (struct slab_item *) ptr;

	if (fully_formatted(slab) && SLIST_EMPTY(&slab->free))
		TAILQ_INSERT_TAIL(&cache->free_slabs, slab, cache_free_link);

	assert(valid_item(slab, item));
	assert(SLIST_EMPTY(&slab->free) || valid_item(slab, SLIST_FIRST(&slab->free)));

	SLIST_INSERT_HEAD(&slab->free, item, next);
	slab->used -= cache->item_size + sizeof(red_zone);
	slab->items -= 1;

	if (slab->items == 0) {
		TAILQ_REMOVE(&cache->free_slabs, slab, cache_free_link);
		TAILQ_REMOVE(&cache->slabs, slab, cache_link);
		SLIST_INSERT_HEAD(&arena.free_slabs, slab, free_link);
	}

	VALGRIND_FREELIKE_BLOCK(item, sizeof(red_zone));
}

static void
sfree_batch(void)
{
	ssize_t batch = arena.delayed_free_batch;

	while (--batch >= 0 && !SLIST_EMPTY(&free_delayed)) {
		assert(arena.delayed_free_count > 0);
		struct slab_item *item = SLIST_FIRST(&free_delayed);
		SLIST_REMOVE_HEAD(&free_delayed, next);
		arena.delayed_free_count--;
		sfree(item);
	}
}

void
sfree_delayed(void *ptr)
{
	if (ptr == NULL)
		return;
	struct slab_item *item = (struct slab_item *)ptr;
	struct slab *slab = slab_header(item);
	assert(valid_item(slab, item));
	SLIST_INSERT_HEAD(&free_delayed, item, next);
	arena.delayed_free_count++;
}

void *
salloc(size_t size, const char *what)
{
	struct slab_cache *cache;
	struct slab *slab;
	struct slab_item *item;

	sfree_batch();

	if ((cache = cache_for(size)) == NULL ||
	    (slab = slab_of(cache)) == NULL) {

		tnt_raise(LoggedError, ER_MEMORY_ISSUE, size,
			  "slab allocator", what);
	}

	if (SLIST_EMPTY(&slab->free)) {
		assert(valid_item(slab, slab->brk));
		item = (struct slab_item *) slab->brk;
		memcpy((char *)item + cache->item_size, red_zone, sizeof(red_zone));
		slab->brk = (char *) slab->brk + cache->item_size + sizeof(red_zone);
	} else {
		item = SLIST_FIRST(&slab->free);
		assert(valid_item(slab, item));
		(void) VALGRIND_MAKE_MEM_DEFINED(item, sizeof(void *));
		SLIST_REMOVE_HEAD(&slab->free, next);
		(void) VALGRIND_MAKE_MEM_UNDEFINED(item, sizeof(void *));
	}

	if (fully_formatted(slab) && SLIST_EMPTY(&slab->free))
		TAILQ_REMOVE(&cache->free_slabs, slab, cache_free_link);

	slab->used += cache->item_size + sizeof(red_zone);
	slab->items += 1;

	VALGRIND_MALLOCLIKE_BLOCK(item, cache->item_size, sizeof(red_zone), 0);
	return (void *)item;
}

size_t
salloc_ptr_to_index(void *ptr)
{
	struct slab *slab = slab_header(ptr);
	struct slab_item *item = (struct slab_item *) ptr;
	struct slab_cache *clazz = slab->cache;

	(void) item;
	assert(valid_item(slab, item));

	void *brk_start = (char *)CACHEALIGN((char *)slab+sizeof(struct slab));
	ptrdiff_t item_no = ((const char *) ptr - (const char *) brk_start) / clazz->item_size;
	assert(item_no >= 0);

	ptrdiff_t slab_no = ((const char *) slab - (const char *) arena.base) / SLAB_SIZE;
	assert(slab_no >= 0);

	size_t index = (size_t)slab_no * MAX_SLAB_ITEM_COUNT + (size_t) item_no;

	assert(salloc_ptr_from_index(index) == ptr);

	return index;
}

void *
salloc_ptr_from_index(size_t index)
{
	size_t slab_no = index / MAX_SLAB_ITEM_COUNT;
	size_t item_no = index % MAX_SLAB_ITEM_COUNT;

	struct slab *slab = slab_header(
		(void *) ((size_t) arena.base + SLAB_SIZE * slab_no));
	struct slab_cache *clazz = slab->cache;

	void *brk_start = (char *)CACHEALIGN((char *)slab+sizeof(struct slab));
	struct slab_item *item = (struct slab_item *)((char *) brk_start + item_no * clazz->item_size);
	assert(valid_item(slab, item));

	return (void *) item;
}

/**
 * Collect slab allocator statistics.
 *
 * @param cb - a callback to receive statistic item
 * @param astat - a structure to fill with of arena
 * @user_data - user's data that will be sent to cb
 *
 */
int
salloc_stat(salloc_stat_cb cb, struct slab_arena_stats *astat, void *cb_ctx)
{
	if (astat) {
		astat->used = arena.used;
		astat->size = arena.size;
	}

	if (cb) {
		struct slab *slab;
		struct slab_cache_stats st;

		for (int i = 0; i < slab_active_caches; i++) {
			memset(&st, 0, sizeof(st));
			TAILQ_FOREACH(slab, &slab_caches[i].slabs, cache_link)
			{
				st.slabs++;
				st.items += slab->items;
				st.bytes_free += SLAB_SIZE;
				st.bytes_free -= slab->used;
				st.bytes_free -= sizeof(struct slab);
				st.bytes_used += sizeof(struct slab);
				st.bytes_used += slab->used;
			}
			st.item_size = slab_caches[i].item_size;

			if (st.slabs == 0)
				continue;
			int res = cb(&st, cb_ctx);
			if (res != 0)
				return res;
		}
	}
	return 0;
}
