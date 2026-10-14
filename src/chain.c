/*
 * routines to operate on double linked circular chains
 *
 * In memoriam ICL George 3
 *
 * Copyright (c) 1989 Dirk Koopman
 *
 * chain_init() - initialise a chain
 * chain_add() - add an item after the ref provided
 * chain_delete() - delete the item
 * chainins() - insert an item before the ref
 * chainnext() - get the next item on chain returning NULL if eof
 * chainprev() - get the previous item on chain returning NULL if eof
 * chain_empty_test() - is the chain empty?
 * chain_movebase() - move a chain of things onto (the end of) another base
 *
 * $Header$
 *
 */

#include <stdlib.h>
#include "fatal.h"

/* chain definitions */
typedef struct _reft {
	struct _reft *next, *prev;
} reft;

static char erm[] = "chain broken in %s";
#define check(p, ss) if (p == (struct _reft *) 0 || p->prev->next != p || p->next->prev != p) die(erm, ss);

/*
 * chain_init()
 */

void chain_init(p)
struct _reft *p;
{
	p->next = p->prev = p;
}

/*
 * chain_insert() - insert an item before the ref provided
 */

void chain_insert(p, q)
struct _reft *p, *q;
{
	check(p, "ins");
	q->prev = p->prev;
	q->next = p;
	p->prev->next = q;
	p->prev = q;
}
/*
 * chain_movebase() - insert an chain of items from one base to another
 */

void chain_movebase(p, q)
struct _reft *p, *q;
{
	check(p, "movebase");
	q->prev->prev = p->prev;
	q->next->next = p;
	p->prev->next = q->next;
	p->prev = q->prev;
	q->next = q->prev = q;
}

/*
 * chain_add() - add an item after the ref
 */

void chain_add(p, q)
struct _reft *p, *q;
{
	check(p, "add");
	p = p->next;
	chain_insert(p, q);
}

/*
 * chain_delete() - delete an item in a chain
 */

struct _reft *chain_delete(p)
struct _reft *p;
{
	check(p, "del");
	p->prev->next = p->next;
	p->next->prev = p->prev;
	return p->prev;
}

/*
 * chain_empty_test() - test to see if the chain is empty
 */

int chain_empty_test(base)
struct _reft *base;
{
	check(base, "chain_empty_test")
		return base->next == base;
}

/*
 * chainnext() - get next item in chain
 */

struct _reft *chain_get_next(base, p)
struct _reft *base, *p;
{

	check(base, "next base");
	
	if (!p)
		return (chain_empty_test(base)) ? 0 : base->next;

	check(p, "next last ref");
	if (p->next != base)
		return p->next;
	else
		return (struct _reft *) 0;
}

/*
 * chainprev() - get previous item in chain
 */

struct _reft *chain_get_prev(base, p)
struct _reft *base, *p;
{
	check(base, "prev base");
	if (!p)
		return (chain_empty_test(base)) ? 0 : base->prev;

	check(p, "prev last ref");
	if (p->prev != base)
		return p->prev;
	else
		return (struct _reft *) 0;
}

/*
 * rechain() - re-chain an item at this point (usually after the chain base)
 */

void chain_rechain(base, p)
struct _reft *base, *p;
{
	check(base, "rechain base");
	check(p, "rechain last ref");
	chain_delete(p);
	chain_add(base, p);
}

/*
 * emptychain() - remove all the elements in a chain, this frees all elements
 *                in a chain leaving just the base.
 */

void chain_flush(base)
struct _reft *base;
{
	struct _reft *p;

	while (!chain_empty_test(base)) {
		p = base->next;
		chain_delete(p);
		free(p);
	}
}

/*
 * newchain() - create a new chain base in the heap
 */

reft *chain_new()
{
	reft *p = malloc(sizeof(reft));
	if (!p)
		die("out of room in chain_new");
	chain_init(p);
	return p;
}

/*
 * $Log$
 * Revision 1.4  2000-07-20 14:16:00  minima
 * can use Sourceforge now!
 * added user->qra cleaning
 * added 4 digit qra to user broadcast dxspots if available
 *
 * Revision 1.3  2000/03/30 22:51:14  djk
 * fixed connect code in client.pl so it doesn't falsely recognise /spider
 * /src/client as a 'client' directive.
 * Tidied up the C client a bit
 *
 * Revision 1.2  2000/03/26 14:22:59  djk
 * removed some irrelevant log info
 *
 * Revision 1.1  2000/03/26 00:03:30  djk
 * first cut of client
 *
 * Revision 1.4  1998/01/02 19:39:58  djk
 * made various changes to cope with glibc
 * fixed problem with extended status in etsi_router
 *
 * Revision 1.3  1997/01/02 18:46:46  djk
 * Added conv.c from ETSI router
 * Changed qerror.c to use syslog rather than qerror.log
 * removed all the map27 stuff into a separate directory
 * added dump.c (a debugging tool for dumping frames of data)
 *
 * Revision 1.1  1996/08/08 11:33:44  djk
 * Initial revision
 *
 * Revision 1.2  1995/04/21  16:02:51  djk
 * remove rcs id
 *
 * Revision 1.1  1995/03/04  11:46:26  djk
 * Initial revision
 *
 * Revision 1.2  1995/01/24  15:09:39  djk
 * Changed Indent to Id in rcsid
 *
 * Revision 1.1  1995/01/24  15:06:28  djk
 * Initial revision
 *
 * Revision 1.3  91/03/08  13:21:56  dlp
 * changed the chain broken checks to dlpabort for dlperror
 * 
 * Revision 1.2  90/09/15  22:37:39  dlp
 * checked in with -k by dirk at 91.02.20.15.53.51.
 * 
 * Revision 1.2  90/09/15  22:37:39  dlp
 * *** empty log message ***
 * 
 * Revision 1.1  90/09/15  22:18:23  dlp
 * Initial revision
 * 
 */
