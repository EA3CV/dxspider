/*
 * cmsg.c
 * 
 * create and free message buffers
 * 
 * Copyright 1996 (c) D-J Koopman
 * 
 * $Header$
 */


static char rcsid[] = "$Id$";

#include <time.h>
#include <stdlib.h>

#include "chain.h"
#include "cmsg.h"
#include "fatal.h"

long cmsg_count = 0;

#ifdef DB_CMSG
#include <malloc.h>
#include <stdio.h>


#define MAXSORT 20
#define INTERVAL 10
#define FN "msg_stats"

static struct {
	long new;
	long free;
} stats[MAXSORT+1];

static void store()
{
	static time_t t;
	time_t systime;
	
	time(&systime);
	if (systime - t > INTERVAL) {
		FILE *f = fopen(FN, "w");
		if (f) {
			int i;
			struct mallinfo m;			
			fprintf(f, "\nMSG STATISTICS\n");
			fprintf(f,   "==============\n\n");
			fprintf(f, "cmsg_count = %ld\n\n", cmsg_count);
			for (i = 0; i < MAXSORT+1; ++i) {
				if (stats[i].new == 0 && stats[i].free == 0)
					continue;
				fprintf(f, "%d new: %ld free: %ld outstanding: %ld\n", i, stats[i].new, stats[i].free, stats[i].new-stats[i].free);
			}
			m = mallinfo();
			fprintf(f, "\nmalloc total arena used: %ld used: %ld free: %ld\n\n", m.arena, m.uordblks, m.fordblks);
			fclose(f);
		}
		t = systime;
	}
}

void cmsg_clear_stats()
{
	memset(stats, 0, sizeof stats);
	store();
}

#endif

cmsg_t *cmsg_new(int size, int sort, void *pp)
{
	cmsg_t *mp;
	
	mp = malloc(sizeof(cmsg_t) + size);
	if (!mp)
		die("no room in cmsg_new");
	mp->size = 0;
	mp->sort = sort & CMSG_SORTMASK;
	mp->portp = pp;
	mp->state = mp->reply = 0;
	mp->hex_high = 0;
	mp->inp = mp->data;
	mp->callback = 0;
	++cmsg_count;
#ifdef DB_CMSG
 	if (sort > MAXSORT)
		sort = MAXSORT;
	++stats[sort].new;	
	store();
#endif
	return mp;
}


void cmsg_send(reft *base, cmsg_t *mp, void (*callback)())
{
	time(&mp->t);
	mp->size = mp->inp - mp->data;	   /* calc the real size */
	mp->callback = callback;		   /* store the reply address */
	chain_insert(base, mp);
#ifdef DB_CMSG
	store();
#endif
}

void cmsg_priority_send(reft *base, cmsg_t *mp, void (*callback)())
{
	time(&mp->t);
	mp->size = mp->inp - mp->data;	   /* calc the real size */
	mp->callback = callback;		   /* store the reply address */
	chain_add(base, mp);
#ifdef DB_CMSG
	store();
#endif
}

/*
 * get the next cmsg (from the front), this removes the message from the chain
 */

cmsg_t *cmsg_next(reft *base)
{
	cmsg_t *mp = chain_get_next(base, 0);
	if (mp)
		chain_delete(mp);
#ifdef DB_CMSG
	store();
#endif
	return mp;
}

/*
 * get the prev cmsg (from the back), this removes the message from the chain
 */

cmsg_t *cmsg_prev(reft *base)
{
	cmsg_t *mp = chain_get_prev(base, 0);
	if (mp)
		chain_delete(mp);
#ifdef DB_CMSG
	store();
#endif
	return mp;
}

void cmsg_callback(cmsg_t *m, int reply)
{
	if (m->callback)
		(m->callback)(m, reply);
	cmsg_free(m);
}

void cmsg_free(cmsg_t *m)
{
	--cmsg_count;
#ifdef DB_CMSG
 	if (m->sort > MAXSORT)
		m->sort = MAXSORT;
	++stats[m->sort].free;	
	store();
#endif
	free(m);
}

void cmsg_flush(reft *base, int reply)
{
	cmsg_t *m;
	
	while (m = cmsg_next(base)) {
		cmsg_callback(m, reply);
	}
#ifdef DB_CMSG
	store();
#endif
}		

/*
 * 
 * $Log$
 * Revision 1.3  2000-10-29 11:00:07  minima
 * added echo cancelling
 * started new filter code, objectifyed old filter code
 *
 * Revision 1.2  2000/07/20 14:16:00  minima
 * can use Sourceforge now!
 * added user->qra cleaning
 * added 4 digit qra to user broadcast dxspots if available
 *
 * Revision 1.1  2000/03/26 00:03:30  djk
 * first cut of client
 *
 * Revision 1.12  1998/05/05 14:01:27  djk
 * Tidied up various global variables in the hope that there is likely
 * to be less undefined interaction between modules.
 * Added some extra LINUX debugging to check for possible cmsg memory leaks.
 *
 * Revision 1.11  1998/01/02 19:39:58  djk
 * made various changes to cope with glibc
 * fixed problem with extended status in etsi_router
 *
 * Revision 1.10  1997/06/13 16:51:17  djk
 * fixed various library problems
 * got the taipstack and hayes to the point of half duplex reliability
 * hayes now successfully communicates with taiptest and has part of the
 * command level taip stuff in.
 *
 * Revision 1.9  1997/05/20 20:45:14  djk
 * The 1.22 version more or less unchanged
 *
 * Revision 1.8  1997/03/25 18:12:55  djk
 * dunno
 *
 * Revision 1.7  1997/03/19 09:57:28  djk
 * added a count to check for leaks
 *
 * Revision 1.6  1997/02/13 17:02:04  djk
 * forgotten?
 *
 * Revision 1.5  1997/02/04 17:47:04  djk
 * brought into line with public2
 *
 * Revision 1.4  1997/02/04 01:27:37  djk
 * altered size semantics on create (size now = 0 not creation size)
 *
 * Revision 1.3  1997/01/20 22:29:27  djk
 * added status back
 *
 * Revision 1.2  1997/01/13 23:34:29  djk
 * The first working test version of smsd
 *
 * Revision 1.1  1997/01/03 23:42:21  djk
 * added a general message handling module (still developing)
 * added parity handling to ser.c
 *
 */
