/*
 * debug routines
 *
 * Copyright (c) 1998 Dirk Koopman G1TLH
 *
 * $Id$
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <errno.h>
#include <time.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "debug.h"
#include "fatal.h"

#define LOGDIR "./dbg"

static char opened = 0;
unsigned long dbglevel = 0;
static int pid;
static char *prog;
static FILE *f;
static int thisday;
static time_t systime;

void (*dbgproc)();
char dbgbuf[1500];

static int getdayno(time_t t)
{
	struct tm *tm;
	
	tm = gmtime(&t);
	return tm->tm_mday;
}

static char *genlogname(char *dir, char *fn, int day, int readonly)
{
	static char buf[256];
	struct stat s;
	
	sprintf(buf, "%s/%s_%d", dir, fn, day);
	
	/* look to see if this is out of date, if it is remove it */
	if (!readonly && stat(buf, &s) >= 0) {
		if (systime - s.st_mtime > (7*24*60*60)) 
			unlink(buf);
	}
	return buf;
}

static void rotate_log()
{
	int i;
	char *fn;
	
	i = getdayno(systime);
	if (i != thisday) {
		thisday = i;
		dbghup();
	}
}

void dbghup()
{
	char *fn;
	
	if (f) {
		fclose(f);
		f = 0;
	}
	if (!f) {
		if (!thisday)
			thisday = getdayno(systime);
        fn = genlogname(LOGDIR, "log", thisday, 0);
		f = fopen(fn, "a");
    }
	
	if (!f)
		die("can't open %s (%d) for debug", fn, errno);
}

char *dbgtime()
{
	time_t t;
	char *ap;
	static char buf[30];
	
	ap = ctime(&systime);
	sprintf(buf, "%2.2s%3.3s%4.4s %8.8s", &ap[8], &ap[4], &ap[20], &ap[11]);
	return buf;
}

void dbginit(char *ident)
{
	pid = getpid();
	prog = strdup(ident);
	time(&systime);
	mkdir(LOGDIR, 01777);
	dbghup();
}

void dbgadd(unsigned long level)
{
    dbglevel |= level;
}

void dbgsub(unsigned long level)
{
    dbglevel &= ~level;
}

void dbgset(unsigned long level)
{
    dbglevel = level;
}

unsigned long dbgget()
{
	return dbglevel;
}

void dbgread(char *s)
{
    unsigned long level = strtoul(s, 0, 0);
    dbgset(level);
}

void dbg(unsigned long level, char *format, ...)
{
    if (f && DBGLEVEL(level)) {
		char dbuf[100];
        char buf[1500-100];
		int i;
        va_list ap;
		
		time(&systime);
		
		rotate_log();
		
        sprintf(dbuf, "%s %s[%d,%04lx] ", dbgtime(), prog, pid, level);
        va_start(ap, format);
        vsprintf(buf, format, ap);
		i = strlen(buf);
		if (i>1 && buf[i-1] == '\n')
			buf[i-1] = 0;
		fprintf(f, "%s", dbuf);
		fprintf(f, "%s", buf);
		fputc('\n', f);
        va_end(ap);
		fflush(f);

		/* save for later */
		if (dbgproc) {
			sprintf(dbgbuf, "%s%s", dbuf, buf);
			(dbgproc)(dbgbuf);
		}
    }
}

void dbgdump(unsigned long level, char *dir, unsigned char *s, int lth)
{
    if (f && DBGLEVEL(level)) {
        int c, l;
        unsigned char *p2, *p1;
        char *p, buf[120];
		
		time(&systime);

		rotate_log();
		
        sprintf(buf, "%s %s[%d,%04lx] %s Lth: %d", dbgtime(), prog, pid, level, dir, lth);
        fprintf(f, "%s\n", buf);
		if (dbgproc) {
			(dbgproc)(buf);
		}

        /* calc how many blocks of 8 I can do */
        c = 80 / 8;
        c /= 3;

        for (p = buf, p2 = s; p2 < s + lth; p2 += c * 8, p = buf) {
            int i, l = c * 8;
            sprintf(p, "%4td: ", p2 - s);
            p += strlen(p);
            for (p1 = p2; p1 < s + lth && p1 < p2 + l; ++p1) {
                sprintf(p, "%02X", *p1);
                p += strlen(p);
            }
            for ( ;p1 < p2 + l; ++p1) {
                sprintf(p, "  ");
                p += strlen(p);
            }
            sprintf(p, " ");
            p += strlen(p);
            for (p1 = p2; p1 < s + lth && p1 < p2 + l; ++p1) {
                sprintf(p, "%c", (*p1 >= ' ' && *p1 <= 0x7e) ? *p1 : '.'); 
                p += strlen(p);
            }
            fprintf(f, "%s\n", buf);
			if (dbgproc) {
				(dbgproc)(buf);
			}
        }
    }
	fflush(f);
}

void dbgclose()
{
    if (f) {
        fclose(f);
        opened = 0;
    }
}
