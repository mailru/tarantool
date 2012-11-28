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
#include "fiber.h"
#include "config.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <say.h>
#include <tarantool.h>
#include TARANTOOL_CONFIG
#include <tbuf.h>
#include <stat.h>
#include <pickle.h>
#include <assoc.h>
#include "iobuf.h"
#include <rlist.h>

@implementation FiberCancelException
@end


enum { FIBER_CALL_STACK = 16 };

static struct fiber sched;
__thread struct fiber *fiber = &sched;
static __thread struct fiber *call_stack[FIBER_CALL_STACK];
static __thread struct fiber **sp;
static __thread uint32_t last_used_fid;
static __thread struct mh_i32ptr_t *fibers_registry;
static __thread struct rlist fibers, zombie_fibers, ready_fibers;
static __thread ev_async ready_async;

static void
update_last_stack_frame(struct fiber *fiber)
{
#ifdef ENABLE_BACKTRACE
	fiber->last_stack_frame = __builtin_frame_address(0);
#else
	(void)fiber;
#endif /* ENABLE_BACKTRACE */
}

void
fiber_call(struct fiber *callee, ...)
{
	struct fiber *caller = fiber;

	assert(sp - call_stack < FIBER_CALL_STACK);
	assert(caller);

	fiber = callee;
	*sp++ = caller;

	update_last_stack_frame(caller);

	callee->csw++;

	fiber->flags &= ~FIBER_READY;

	va_start(fiber->f_data, callee);
	coro_transfer(&caller->coro.ctx, &callee->coro.ctx);
	va_end(fiber->f_data);
}


/** Interrupt a synchronous wait of a fiber inside the event loop.
 * We do so by keeping an "async" event in every fiber, solely
 * for this purpose, and raising this event here.
 */

void
fiber_wakeup(struct fiber *f)
{
	if (f->flags & FIBER_READY)
		return;
	f->flags |= FIBER_READY;
	if (rlist_empty(&ready_fibers))
		ev_async_send(&ready_async);
	rlist_move_tail_entry(&ready_fibers, f, state);
}

/** Cancel the subject fiber.
 *
 * Note: this is not guaranteed to succeed, and requires a level
 * of cooperation on behalf of the fiber. A fiber may opt to set
 * FIBER_CANCELLABLE to false, and never test that it was
 * cancelled.  Such fiber can not ever be cancelled, and
 * for such fiber this call will lead to an infinite wait.
 * However, fiber_testcancel() is embedded to the rest of fiber_*
 * API (@sa fiber_yield()), which makes most of the fibers that opt in,
 * cancellable.
 *
 * Currently cancellation can only be synchronous: this call
 * returns only when the subject fiber has terminated.
 *
 * The fiber which is cancelled, has FiberCancelException raised
 * in it. For cancellation to work, this exception type should be
 * re-raised whenever (if) it is caught.
 */

void
fiber_cancel(struct fiber *f)
{
	assert(f->fid != 0);
	assert(!(f->flags & FIBER_CANCEL));

	f->flags |= FIBER_CANCEL;

	if (f == fiber) {
		fiber_testcancel();
		return;
	}
	/*
	 * The subject fiber is passing through a wait
	 * point and can be kicked out of it right away.
	 */
	if (f->flags & FIBER_CANCELLABLE)
		fiber_call(f);

	if (f->fid) {
		/*
		 * The fiber is not dead. We have no other
		 * choice but wait for it to discover that
		 * it has been cancelled, and die.
		 */
		assert(f->waiter == NULL);
		f->waiter = fiber;
		fiber_yield();
	}
	/*
	 * Here we can't even check f->fid is 0 since
	 * f could have already been reused. Knowing
	 * at least that we can't get scheduled ourselves
	 * unless asynchronously woken up is somewhat a relief.
	 */
	fiber_testcancel(); /* Check if we're ourselves cancelled. */
}

bool
fiber_is_cancelled()
{
	return fiber->flags & FIBER_CANCEL;
}

/** Test if this fiber is in a cancellable state and was indeed
 * cancelled, and raise an exception (FiberCancelException) if
 * that's the case.
 */
void
fiber_testcancel(void)
{
	if (fiber_is_cancelled())
		tnt_raise(FiberCancelException);
}



/** Change the current cancellation state of a fiber. This is not
 * a cancellation point.
 */
bool
fiber_setcancellable(bool enable)
{
	bool prev = fiber->flags & FIBER_CANCELLABLE;
	if (enable == true)
		fiber->flags |= FIBER_CANCELLABLE;
	else
		fiber->flags &= ~FIBER_CANCELLABLE;
	return prev;
}

/**
 * @note: this is not a cancellation point (@sa fiber_testcancel())
 * but it is considered good practice to call testcancel()
 * after each yield.
 */
void
fiber_yield(void)
{
	struct fiber *callee = *(--sp);
	struct fiber *caller = fiber;

	fiber = callee;
	update_last_stack_frame(caller);

	callee->csw++;
	coro_transfer(&caller->coro.ctx, &callee->coro.ctx);
}


static void
fiber_schedule_timeout(ev_watcher *watcher)
{
	assert(fiber == &sched);
	struct { struct fiber *f; bool timed_out; } *state = watcher->data;
	state->timed_out = true;
	fiber_call(state->f);
}

/**
 * @brief yield & check timeout
 * @return true if timeout exceeded
 */
bool
fiber_yield_timeout(ev_tstamp delay)
{
	struct ev_timer timer;
	ev_timer_init(&timer, (void *)fiber_schedule_timeout, delay, 0);
	struct { struct fiber *f; bool timed_out; } state = { fiber, false };
	timer.data = &state;
	ev_timer_start(&timer);
	fiber_yield();
	ev_timer_stop(&timer);
	return state.timed_out;
}

void
fiber_yield_to(struct fiber *f)
{
	fiber_wakeup(f);
	fiber_yield();
	fiber_testcancel();
}

/**
 * @note: this is a cancellation point (@sa fiber_testcancel())
 */

void
fiber_sleep(ev_tstamp delay)
{
	fiber_yield_timeout(delay);
	fiber_testcancel();
}

/** Wait for a forked child to complete.
 * @note: this is a cancellation point (@sa fiber_testcancel()).
 * @return process return status
*/
int
wait_for_child(pid_t pid)
{
	ev_child cw;
	ev_init(&cw, (void *)fiber_schedule);
	ev_child_set(&cw, pid, 0);
	cw.data = fiber;
	ev_child_start(&cw);
	fiber_yield();
	ev_child_stop(&cw);
	int status = cw.rstatus;
	fiber_testcancel();
	return status;
}

void
fiber_schedule(ev_watcher *watcher, int event __attribute__((unused)))
{
	assert(fiber == &sched);
	fiber_call(watcher->data);
}

static void
fiber_ready_async(void)
{
	while(!rlist_empty(&ready_fibers)) {
		struct fiber *f =
			rlist_first_entry(&ready_fibers, struct fiber, state);
		rlist_del_entry(f, state);
		fiber_call(f);
	}
}

struct fiber *
fiber_find(int fid)
{
	struct mh_i32ptr_node_t node = { .key = fid };
	mh_int_t k = mh_i32ptr_get(fibers_registry, &node, NULL, NULL);

	if (k == mh_end(fibers_registry))
		return NULL;
	if (!mh_exist(fibers_registry, k))
		return NULL;
	return mh_i32ptr_node(fibers_registry, k)->val;
}

static void
register_fid(struct fiber *fiber)
{
	int ret;
	struct mh_i32ptr_node_t node = { .key = fiber -> fid, .val = fiber };
	mh_i32ptr_put(fibers_registry, &node, NULL, NULL, &ret);
}

static void
unregister_fid(struct fiber *fiber)
{
	struct mh_i32ptr_node_t node = { .key = fiber->fid };
	mh_int_t k = mh_i32ptr_get(fibers_registry, &node, NULL, NULL);
	mh_i32ptr_del(fibers_registry, k, NULL, NULL);
}

void
fiber_gc(void)
{
	if (palloc_allocated(fiber->gc_pool) < 128 * 1024) {
		palloc_reset(fiber->gc_pool);
		return;
	}

	prelease(fiber->gc_pool);
}


/** Destroy the currently active fiber and prepare it for reuse.
 */

static void
fiber_zombificate()
{
	if (fiber->waiter)
		fiber_wakeup(fiber->waiter);
	rlist_del(&fiber->state);
	fiber->waiter = NULL;
	fiber_set_name(fiber, "zombie");
	fiber->f = NULL;
	unregister_fid(fiber);
	fiber->fid = 0;
	fiber->flags = 0;
	prelease(fiber->gc_pool);
	rlist_move_entry(&zombie_fibers, fiber, link);
}

static void
fiber_loop(void *data __attribute__((unused)))
{
	for (;;) {
		assert(fiber != NULL && fiber->f != NULL && fiber->fid != 0);
		@try {
			fiber->f(fiber->f_data);
		} @catch (FiberCancelException *e) {
			say_info("fiber `%s' has been cancelled", fiber->name);
			say_info("fiber `%s': exiting", fiber->name);
		} @catch (tnt_Exception *e) {
			[e log];
		} @catch (id e) {
			say_error("fiber `%s': exception `%s'",
				fiber->name, object_getClassName(e));
			panic("fiber `%s': exiting", fiber->name);
		}
		fiber_zombificate();
		fiber_yield();	/* give control back to scheduler */
	}
}

/** Set fiber name.
 *
 * @param[in] name the new name of the fiber. Truncated to
 * FIBER_NAME_MAXLEN.
*/

void
fiber_set_name(struct fiber *fiber, const char *name)
{
	assert(name != NULL);
	snprintf(fiber->name, sizeof(fiber->name), "%s", name);
	palloc_set_name(fiber->gc_pool, fiber->name);
}

/**
 * Create a new fiber.
 *
 * Takes a fiber from fiber cache, if it's not empty.
 * Can fail only if there is not enough memory for
 * the fiber structure or fiber stack.
 *
 * The created fiber automatically returns itself
 * to the fiber cache when its "main" function
 * completes.
 */
struct fiber *
fiber_create(const char *name, void (*f) (va_list))
{
	struct fiber *fiber = NULL;

	if (!rlist_empty(&zombie_fibers)) {
		fiber = rlist_first_entry(&zombie_fibers, struct fiber, link);
		rlist_move_entry(&fibers, fiber, link);
	} else {
		fiber = palloc(eter_pool, sizeof(*fiber));

		memset(fiber, 0, sizeof(*fiber));
		tarantool_coro_init(&fiber->coro, fiber_loop, NULL);

		fiber->gc_pool = palloc_create_pool("");

		rlist_add_entry(&fibers, fiber, link);
		rlist_init(&fiber->state);
	}


	fiber->f = f;

	/* fids from 0 to 100 are reserved */
	if (++last_used_fid < 100)
		last_used_fid = 100;
	fiber->fid = last_used_fid;
	fiber->flags = 0;
	fiber->waiter = NULL;
	fiber_set_name(fiber, name);
	register_fid(fiber);

	return fiber;
}

/**
 * Free as much memory as possible taken by the fiber.
 *
 * @note we can't release memory allocated via palloc(eter_pool, ...)
 * so, struct fiber and some of its members are leaked forever.
 */
void
fiber_destroy(struct fiber *f)
{
	if (f == fiber) /* do not destroy running fiber */
		return;
	if (strcmp(f->name, "sched") == 0)
		return;

	rlist_del(&f->state);
	palloc_destroy_pool(f->gc_pool);
	tarantool_coro_destroy(&f->coro);
}

void
fiber_destroy_all()
{
	struct fiber *f;
	rlist_foreach_entry(f, &fibers, link)
		fiber_destroy(f);
	rlist_foreach_entry(f, &zombie_fibers, link)
		fiber_destroy(f);
}


static void
fiber_info_print(struct tbuf *out, struct fiber *fiber)
{
	void *stack_top = fiber->coro.stack + fiber->coro.stack_size;

	tbuf_printf(out, "  - fid: %4i" CRLF, fiber->fid);
	tbuf_printf(out, "    csw: %i" CRLF, fiber->csw);
	tbuf_printf(out, "    name: %s" CRLF, fiber->name);
	tbuf_printf(out, "    stack: %p" CRLF, stack_top);
#ifdef ENABLE_BACKTRACE
	tbuf_printf(out, "    backtrace:" CRLF "%s",
		    backtrace(fiber->last_stack_frame,
			      fiber->coro.stack, fiber->coro.stack_size));
#endif /* ENABLE_BACKTRACE */
}

void
fiber_info(struct tbuf *out)
{
	struct fiber *fiber;

	tbuf_printf(out, "fibers:" CRLF);

	rlist_foreach_entry(fiber, &fibers, link)
		fiber_info_print(out, fiber);
	rlist_foreach_entry(fiber, &zombie_fibers, link)
		fiber_info_print(out, fiber);
}

void
fiber_init(void)
{
	rlist_init(&fibers);
	rlist_init(&ready_fibers);
	rlist_init(&zombie_fibers);
	fibers_registry = mh_i32ptr_init();

	memset(&sched, 0, sizeof(sched));
	sched.fid = 1;
	sched.gc_pool = palloc_create_pool("");
	fiber_set_name(&sched, "sched");

	sp = call_stack;
	fiber = &sched;
	last_used_fid = 100;

	iobuf_init_readahead(cfg.readahead);

	ev_async_init(&ready_async, (void *)fiber_ready_async);
	ev_async_start(&ready_async);
}

void
fiber_free(void)
{
	ev_async_stop(&ready_async);
	/* Only clean up if initialized. */
	if (fibers_registry) {
		fiber_destroy_all();
		mh_i32ptr_destroy(fibers_registry);
	}
}
