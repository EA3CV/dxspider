/*
 * cmsg.h
 * 
 * general purpose message format
 * 
 * Copyright 1996 (c) D-J Koopman
 * 
 * $Header$
 * 
 * $Log$
 * Revision 1.2  2000-07-20 14:16:00  minima
 * can use Sourceforge now!
 * added user->qra cleaning
 * added 4 digit qra to user broadcast dxspots if available
 *
 * Revision 1.1  2000/03/26 00:03:30  djk
 * first cut of client
 *
 * Revision 1.7  1998/01/02 19:39:57  djk
 * made various changes to cope with glibc
 * fixed problem with extended status in etsi_router
 *
 * Revision 1.6  1997/03/25 18:12:45  djk
 * dunno
 *
 * Revision 1.5  1997/03/19 09:57:54  djk
 * added a count to check for leaks
 *
 * Revision 1.4  1997/02/13 17:01:55  djk
 * forgotten?
 *
 * Revision 1.3  1997/01/20 22:29:23  djk
 * added status back
 *
 * Revision 1.2  1997/01/13 23:34:22  djk
 * The first working test version of smsd
 *
 * Revision 1.1  1997/01/03 23:41:27  djk
 * added a general message handling module (still developing)
 * added dump (a general debugging routine)
 *
 *
 */

#ifndef _CMSG_H
#define _CMSG_H
static char _cmsg_h_rcsid[] = "$Id$";

#include <time.h>

typedef struct {
	reft  head;					/* the chain on which this message is going */
	short size;					/* the length of the data part of the message */
	short sort;					/* the type of message (ie text, rmip, etsi) (may have reply bit set) */
	short state;				/* the current state of this message */
	unsigned char hex_high;		/* first hex nibble between reads */
	short reply;				/* the (standard) reply field */
	time_t t;					/* the time of arrival */
	void (*callback)();			/* the callback address if any */
	void *portp;				/* the pointer to the port it came from */
	unsigned char *inp;			/* the current character pointer for input */
    unsigned char data[1];		/* the actual data of the message */
} cmsg_t;

#define CMSG_REPLY 0x8000
#define CMSG_SORTMASK (~CMSG_REPLY)

extern long cmsg_count;

cmsg_t *cmsg_new(int, int, void *);
void cmsg_send(reft *, cmsg_t *, void (*)());
void cmsg_priority_send(reft *, cmsg_t *, void (*)());
void cmsg_callback(cmsg_t *, int);
void cmsg_flush(reft *, int);
void cmsg_free(cmsg_t *);
cmsg_t *cmsg_next(reft *);
cmsg_t *cmsg_prev(reft *);
#endif
