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
#include "engine.h"

#include "tuple.h"
#include "txn.h"
#include "port.h"
#include "request.h"
#include "space.h"
#include "exception.h"
#include "schema.h"
#include "small/rlist.h"
#include "scoped_guard.h"
#include <stdlib.h>
#include <string.h>
#include <errinj.h>

RLIST_HEAD(engines);

Engine::Engine(const char *engine_name)
	:name(engine_name),
	 link(RLIST_HEAD_INITIALIZER(link))
{}

void Engine::init()
{}

void Engine::begin(struct txn *)
{}

void Engine::beginStatement(struct txn *)
{}

void Engine::prepare(struct txn *)
{}

void Engine::commit(struct txn *, int64_t)
{}

void Engine::rollback(struct txn *)
{}

void Engine::rollbackStatement(struct txn *, struct txn_stmt *)
{}

void Engine::bootstrap()
{}

void Engine::beginInitialRecovery(struct vclock *vclock)
{
	(void) vclock;
}

void Engine::beginFinalRecovery()
{}

void Engine::endRecovery()
{}

void Engine::initSystemSpace(struct space * /* space */)
{
	panic("not implemented");
}

void
Engine::addPrimaryKey(struct space * /* space */)
{
}

void
Engine::dropPrimaryKey(struct space * /* space */)
{
}

void
Engine::buildSecondaryKey(struct space *old_space, struct space *new_space,
			  Index *new_index)
{
	Index *pk = index_find(old_space, 0);

	/* Now deal with any kind of add index during normal operation. */
	struct iterator *it = pk->allocIterator();
	IteratorGuard guard(it);
	pk->initIterator(it, ITER_ALL, NULL, 0);

	/*
	 * The index has to be built tuple by tuple, since
	 * there is no guarantee that all tuples satisfy
	 * new index' constraints. If any tuple can not be
	 * added to the index (insufficient number of fields,
	 * etc., the build is aborted.
	 */
	/* Build the new index. */
	struct tuple *tuple;
	struct tuple_format *format = new_space->format;
	while ((tuple = it->next(it))) {
		/*
		 * Check that the tuple is OK according to the
		 * new format.
		 */
		if (tuple_validate(format, tuple))
			diag_raise();
		/*
		 * @todo: better message if there is a duplicate.
		 */
		struct tuple *old_tuple =
			new_index->replace(NULL, tuple, DUP_INSERT);
		assert(old_tuple == NULL); /* Guaranteed by DUP_INSERT. */
		(void) old_tuple;
	}
}

int
Engine::beginCheckpoint()
{
	return 0;
}

int
Engine::waitCheckpoint(struct vclock *vclock)
{
	(void) vclock;
	return 0;
}

void
Engine::commitCheckpoint(struct vclock *vclock)
{
	(void) vclock;
}

void
Engine::abortCheckpoint()
{
}

void
Engine::join(struct xstream *stream)
{
	(void) stream;
}

void
Engine::keydefCheck(struct space *space, struct key_def *key_def)
{
	(void) space;
	(void) key_def;
	/*
	 * Don't bother checking key_def to match the view requirements.
	 * Index::initIterator() must check key on each call.
	 */
}

Handler::Handler(Engine *f)
	:engine(f)
{
}

void
Handler::applySnapshotRow(struct space *, struct request *)
{
	tnt_raise(ClientError, ER_UNSUPPORTED, engine->name,
		  "applySnapshotRow");
}

struct tuple *
Handler::executeReplace(struct txn *, struct space *,
                        struct request *)
{
	tnt_raise(ClientError, ER_UNSUPPORTED, engine->name, "replace");
}

struct tuple *
Handler::executeDelete(struct txn*, struct space *, struct request *)
{
	tnt_raise(ClientError, ER_UNSUPPORTED, engine->name, "delete");
}

struct tuple *
Handler::executeUpdate(struct txn*, struct space *, struct request *)
{
	tnt_raise(ClientError, ER_UNSUPPORTED, engine->name, "update");
}

void
Handler::executeUpsert(struct txn *, struct space *, struct request *)
{
	tnt_raise(ClientError, ER_UNSUPPORTED, engine->name, "upsert");
}

void
Handler::prepareAlterSpace(struct space *, struct space *)
{
}

void
Handler::commitAlterSpace(struct space *, struct space *)
{
}

void
Handler::executeSelect(struct txn *, struct space *space,
		       uint32_t index_id, uint32_t iterator,
		       uint32_t offset, uint32_t limit,
		       const char *key, const char * /* key_end */,
		       struct port *port)
{
	Index *index = index_find(space, index_id);

	uint32_t found = 0;
	if (iterator >= iterator_type_MAX)
		tnt_raise(IllegalParams, "Invalid iterator type");
	enum iterator_type type = (enum iterator_type) iterator;

	uint32_t part_count = key ? mp_decode_array(&key) : 0;
	if (key_validate(index->key_def, type, key, part_count))
		diag_raise();

	struct iterator *it = index->allocIterator();
	IteratorGuard guard(it);
	index->initIterator(it, type, key, part_count);

	struct tuple *tuple;
	while ((tuple = it->next(it)) != NULL) {
		/*
		 * This is for Vinyl, which returns a tuple
		 * with zero refs from the iterator, expecting
		 * the caller to GC it after use.
		 */
		TupleRef tuple_gc(tuple);
		if (offset > 0) {
			offset--;
			continue;
		}
		if (limit == found++)
			break;
		port_add_tuple(port, tuple);
	}
}

/** Register engine instance. */
void engine_register(Engine *engine)
{
	static int n_engines;
	rlist_add_tail_entry(&engines, engine, link);
	engine->id = n_engines++;
}

/** Find engine by name. */
Engine *
engine_find(const char *name)
{
	Engine *e;
	engine_foreach(e) {
		if (strcmp(e->name, name) == 0)
			return e;
	}
	tnt_raise(LoggedError, ER_NO_SUCH_ENGINE, name);
}

/** Shutdown all engine factories. */
void engine_shutdown()
{
	Engine *e, *tmp;
	rlist_foreach_entry_safe(e, &engines, link, tmp) {
		delete e;
	}
}

void
engine_bootstrap()
{
	Engine *engine;
	engine_foreach(engine) {
		engine->bootstrap();
	}
}

void
engine_begin_initial_recovery(struct vclock *vclock)
{
	/* recover engine snapshot */
	Engine *engine;
	engine_foreach(engine) {
		engine->beginInitialRecovery(vclock);
	}
}

void
engine_begin_final_recovery()
{
	Engine *engine;
	engine_foreach(engine)
		engine->beginFinalRecovery();
}

void
engine_end_recovery()
{
	/*
	 * For all new spaces created after recovery is complete,
	 * when the primary key is added, enable all keys.
	 */
	Engine *engine;
	engine_foreach(engine)
		engine->endRecovery();
}

int
engine_begin_checkpoint()
{
	/* create engine snapshot */
	Engine *engine;
	engine_foreach(engine) {
		if (engine->beginCheckpoint() < 0)
			return -1;
	}
	return 0;
}

int
engine_commit_checkpoint(struct vclock *vclock)
{
	Engine *engine;
	/* wait for engine snapshot completion */
	engine_foreach(engine) {
		if (engine->waitCheckpoint(vclock) < 0)
			return -1;
	}
	/* remove previous snapshot reference */
	engine_foreach(engine) {
		engine->commitCheckpoint(vclock);
	}
	return 0;
}

void
engine_abort_checkpoint()
{
	Engine *engine;
	/* rollback snapshot creation */
	engine_foreach(engine)
		engine->abortCheckpoint();
}

void
engine_join(struct xstream *stream)
{
	Engine *engine;
	engine_foreach(engine) {
		engine->join(stream);
	}
}
