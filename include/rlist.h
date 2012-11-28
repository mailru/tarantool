#ifndef TARANTOOL_RLIST_H_INCLUDED
#define TARANTOOL_RLIST_H_INCLUDED
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

/**
 * list entry and head structure
 */

struct rlist {
	struct rlist *prev;
	struct rlist *next;
};


/**
 * init list head (or list entry as ins't included in list)
 */

inline static void
rlist_init(struct rlist *list)
{
	list->next = list;
	list->prev = list;
}

/**
 * add item to list
 */
inline static void
rlist_add(struct rlist *head, struct rlist *item)
{
	item->prev = head;
	item->next = head->next;
	item->prev->next = item;
	item->next->prev = item;
}

/**
 * add item to list tail
 */
inline static void
rlist_add_tail(struct rlist *head, struct rlist *item)
{
	item->next = head;
	item->prev = head->prev;
	item->prev->next = item;
	item->next->prev = item;
}

/**
 * delete element
 */
inline static void
rlist_del(struct rlist *item)
{
	item->prev->next = item->next;
	item->next->prev = item->prev;
	rlist_init(item);
}

inline static struct rlist *
rlist_shift(struct rlist *head)
{
	if (head->next == head->prev)
                return 0;
        struct rlist *shift = head->next;
        head->next = shift->next;
        shift->next->prev = head;
        shift->next = shift->prev = shift;
        return shift;
}

/**
 * return first element
 */
inline static struct rlist *
rlist_first(struct rlist *head)
{
	return head->next;
}

/**
 * return last element
 */
inline static struct rlist *
rlist_last(struct rlist *head)
{
	return head->prev;
}

/**
 * return next element by element
 */
inline static struct rlist *
rlist_next(struct rlist *item)
{
	return item->next;
}

/**
 * return previous element
 */
inline static struct rlist *
rlist_prev(struct rlist *item)
{
	return item->prev;
}

/**
 * return TRUE if list is empty
 */
inline static int
rlist_empty(struct rlist *item)
{
	return item->next == item->prev && item->next == item;
}

/**
@brief delete from one list and add as another's head
@param to the head that will precede our entry
@param item the entry to move
*/
static inline void
rlist_move(struct rlist *to, struct rlist *item)
{
	rlist_del(item);
	rlist_add(to, item);
}

/**
@brief delete from one list and add_tail as another's head
@param to the head that will precede our entry
@param item the entry to move
*/
static inline void
rlist_move_tail(struct rlist *to, struct rlist *item)
{
	rlist_del(item);
	rlist_add_tail(to, item);
}

/**
 * allocate and init head of list
 */
#define RLIST_HEAD(name)	\
	struct rlist name = { &(name), &(name) }

/**
 * return entry by list item
 */
#define rlist_entry(item, type, member) ({				\
	const typeof( ((type *)0)->member ) *__mptr = (item);		\
	(type *)( (char *)__mptr - ((size_t) &((type *)0)->member) ); })

/**
 * return first entry
 */
#define rlist_first_entry(head, type, member)				\
	rlist_entry(rlist_first(head), type, member)

#define rlist_shift_entry(head, type, member) ({			\
        struct rlist *_shift = rlist_shift(head);			\
        _shift ? rlist_entry(_shift, type, member) : 0; })

/**
 * return last entry
 */
#define rlist_last_entry(head, type, member)				\
	rlist_entry(rlist_last(head), type, member)

/**
 * return next entry
 */
#define rlist_next_entry(item, member)					\
	rlist_entry(rlist_next(&(item)->member), typeof(*item), member)

/**
 * return previous entry
 */
#define rlist_prev_entry(item, member)					\
	rlist_entry(rlist_prev(&(item)->member), typeof(*item), member)

/**
 * add entry to list
 */
#define rlist_add_entry(head, item, member)				\
	rlist_add((head), &(item)->member)

/**
 * add entry to list tail
 */
#define rlist_add_tail_entry(head, item, member)			\
	rlist_add_tail((head), &(item)->member)

/**
delete from one list and add as another's head
*/
#define rlist_move_entry(to, item, member) \
	rlist_move((to), &((item)->member))

/**
delete from one list and add_tail as another's head
*/
#define rlist_move_tail_entry(to, item, member) \
	rlist_move_tail((to), &((item)->member))

/**
 * delete entry from list
 */
#define rlist_del_entry(item, member)					\
	rlist_del(&((item)->member))

/**
 * foreach through list
 */
#define rlist_foreach(item, head)					\
	for(item = rlist_first(head); item != (head); item = rlist_next(item))

/**
 * foreach backward through list
 */
#define rlist_foreach_reverse(item, head)				\
	for(item = rlist_last(head); item != (head); item = rlist_prev(item))

/**
 * foreach through all list entries
 */
#define rlist_foreach_entry(item, head, member)				\
	for(item = rlist_first_entry((head), typeof(*item), member); \
		&item->member != (head); \
		item = rlist_next_entry((item), member))

/**
 * foreach backward through all list entries
 */
#define rlist_foreach_entry_reverse(item, head, member)			\
	for(item = rlist_last_entry((head), typeof(*item), member); \
		&item->member != (head); \
		item = rlist_prev_entry((item), member))


#endif /* TARANTOOL_RLIST_H_INCLUDED */
