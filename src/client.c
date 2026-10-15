/*
 * C Client for the DX Spider cluster program
 *
 * Eventually this program will be a complete replacement
 * for the perl version.
 *
 * This program provides the glue necessary to talk between
 * an input (eg from telnet or ax25) and the perl DXSpider
 * node.
 *
 * Currently, this program connects STDIN/STDOUT to the
 * message system used by cluster.pl
 *
 * Copyright (c) 2000 Dirk Koopman G1TLH
 *
 * $Id$
 */

#include <sys/types.h>
#include <stdio.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>
#include <ctype.h>
#include <stdlib.h>
#include <stdarg.h>
#include <netdb.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <errno.h>
#include <signal.h>
#include <string.h>
#include <termios.h>
#include <regex.h>

#include "sel.h"
#include "cmsg.h"
#include "chain.h"
#include "debug.h"
#include "fatal.h"

#define TEXT 1
#define MSG 2
#define MAXBUFL 1024

#ifndef MAXPATHLEN 
#define MAXPATHLEN 256
#endif

#define DEFPACLEN 236
#define MAXPACLEN 236
#define MAXCALLSIGN 9

#define DBUF 1
#define DMSG 2
#define DSTS 4

#define UC unsigned char

typedef struct 
{
	int cnum;					/* the connection number */
	int sort;					/* the type of connection either text or msg */
	cmsg_t *in;					/* current input message being built up */
	cmsg_t *out;				/* current output message being sent */
	cmsg_t *obuf;				/* current output being buffered */
	reft *inq;					/* input queue */
	reft *outq;					/* output queue */
	sel_t *sp;					/* my select fcb address */
	struct termios t;			/* any termios associated with this cnum */
	char echo;					/* echo characters back to this cnum */
	char t_set;					/* the termios structure is valid */
	char buffer_it;				/* buffer outgoing packets for paclen */
} fcb_t;

typedef struct 
{
	char *in;
	regex_t *regex;
} myregex_t;


char *node_addr = "127.0.0.1";	/* the node tcp address, can be overridden by DXSPIDER_HOST */
int node_port = 27754;			/* the tcp port of the node at the above address can be overidden by DXSPIDER_PORT*/
char *call;						/* the caller's callsign */
char *connsort;					/* the type of connection */
fcb_t *in;						/* the fcb of 'stdin' that I shall use */
fcb_t *node;					/* the fcb of the msg system */
char nl = '\n';					/* line end character */
char mode = 1;                  /* 0 - ax25, 1 - normal telnet, 2 - nlonly telnet */
char ending = 0;				/* set this to end the program */
char echo = 1;					/* echo characters on stdout from stdin */
char int_tabs = 0;				/* interpret tabs -> spaces */
char *root = "/spider";         /* root of data tree, can be overridden by DXSPIDER_ROOT  */
int timeout = 60;				/* default timeout for logins and things */
int paclen = DEFPACLEN;			/* default buffer size for outgoing packets */
int tabsize = 8;				/* default tabsize for text messages */
char *connsort = "local";		/* the connection variety */
int state = 0;					/* the current state of the connection */
int laststate = 0;				/* the last state we were in */
char echocancel = 1;			/* echo cancelling */
reft echobase;					/* the anti echo queue */
int maxecho = 5;				/* the depth of the anti echo queue */
int echon;						/* no of entries in the anti echo queue */

#define CONNECTED 100
#define WAITLOGIN 1
#define WAITPASSWD 2
#define WAITINPUT 10
#define DOCHAT 20

myregex_t iscallreg[] = {		/* regexes to determine whether this is a reasonable callsign */
	{
		"^[A-Z]+[0-9]+[A-Z]+[1-9]?$", 0	               /* G1TLH G1TLH1 */
	},
	{
		"^[0-9]+[A-Z]+[0-9]+[A-Z]+[1-9]?$", 0          /* 2E0AAA 2E0AAA1 */
	},
	{
		"^[A-Z]+[0-9]+[A-Z]+-[0-9]$", 0                /* G1TLH-2 */
	},
	{
		"^[0-9]+[A-Z]+[0-9]+[A-Z]+-[0-9]$", 0          /* 2E0AAA-2 */
	},
	{
		"^[A-Z]+[0-9]+[A-Z]+-1[0-5]$", 0               /* G1TLH-11 */
	},
	{
		"^[0-9]+[A-Z]+[0-9]+[A-Z]+-1[0-5]$", 0         /* 2E0AAA-11 */
	},
	{
		0, 0
	}
};

void terminate(int);

/*
 * utility routines - various
 */

void chgstate(int new)
{
	laststate = state;
	state = new;
	dbg(DSTS, "chg state %d->%d", laststate, state);
}

void die(char *s, ...)
{
	char buf[2000];
	
	va_list ap;
	va_start(ap, s);
	vsnprintf(buf, sizeof(buf)-1, s, ap);
	va_end(ap);
	fprintf(stderr,"%s\n", buf);
	terminate(-1);
}

char *strupper(char *s)
{
	char *d = malloc(strlen(s)+1);
	char *p = d;
	
	if (!d)
		die("out of room in strupper");
	while (*p++ = toupper(*s++)) ;
	return d;
}

char *strlower(char *s)
{
	char *d = malloc(strlen(s)+1);
	char *p = d;
	
	if (!d)
		die("out of room in strlower");
	while (*p++ = tolower(*s++)) ;
	return d;
}

int eq(char *a, char *b)
{
	return (strcmp(a, b) == 0);
}

FILE *xopen(char *dir, char *name, char *mode)
{
	char fn[MAXPATHLEN+1];
	snprintf(fn, MAXPATHLEN, "%s/%s/%s", root, dir, name);
	return fopen(fn, mode);
}

int iscallsign(char *s)
{
	myregex_t *rp;

	if (strlen(s) > MAXCALLSIGN)
		return 0;
	
	for (rp = iscallreg; rp->in; ++rp) {
		if (regexec(rp->regex, s, 0, 0, 0) == 0)
			return 1;
	}
	return 0;
}

void reaper(int i)
{
	pid_t mypid;
	while ((mypid = waitpid(-1, 0, WNOHANG)) > 0) {
		;
	}
}

/*
 * higher level send and receive routines
 */

fcb_t *fcb_new(int cnum, int sort)
{
	fcb_t *f = malloc(sizeof(fcb_t));
	if (!f)
		die("no room in fcb_new");
	memset (f, 0, sizeof(fcb_t));
	f->cnum = cnum;
	f->sort = sort;
	f->inq = chain_new();
	f->outq = chain_new();
	return f;
}

void flush_text(fcb_t *f)
{
	if (f->obuf) {
		/* save this onto the front of the echo chain */
		cmsg_t *imp = f->obuf;
		int size = imp->inp - imp->data;
		cmsg_t *emp = cmsg_new(size, imp->sort, imp->portp);

		emp->size = size;
		memcpy(emp->data, imp->data, size);
		emp->inp = emp->data + size; /* just in case */
		if (echocancel) {
			chain_add(&echobase, emp);
			if (++echon > maxecho) {
				emp = cmsg_prev(&echobase);
				cmsg_free(emp);
			}
		}
		
		/* queue it for sending */
		cmsg_send(f->outq, imp, 0);
		f->sp->flags |= SEL_OUTPUT;
		f->obuf = 0;
	}
}

void send_text(fcb_t *f, char *s, int l, int nlreq)
{
	cmsg_t *mp;
	char *p;
	
	if (f->buffer_it && f->obuf) {
		mp = f->obuf;
	} else {
		f->obuf = mp = cmsg_new(paclen+1, f->sort, f);
	}

	/* remove trailing spaces  */
	while (l > 0 &&isspace(s[l-1]))
		--l;

	for (p = s; p < s+l; ) {
		if (mp->inp >= mp->data + paclen) {
			flush_text(f);
			f->obuf = mp = cmsg_new(paclen+1, f->sort, f);
		}
		*mp->inp++ = *p++;
	}
	if (mp->inp >= mp->data + paclen) {
		flush_text(f);
		f->obuf = mp = cmsg_new(paclen+1, f->sort, f);
	}
	if (nlreq) {
		if (nl == '\r')
			*mp->inp++ = nl;
		else {
			if (mode != 2)
				*mp->inp++ = '\r';
			*mp->inp++ = '\n';
		}
	}
	if (!f->buffer_it)
		flush_text(f);
}

void send_msg(fcb_t *f, char let, UC *s, int l)
{
	cmsg_t *mp;
	int ln;
	int myl = strlen(call)+2+l;

	mp = cmsg_new(myl+4+1, f->sort, f);
	*mp->inp++ = let;
	strcpy(mp->inp, call);
	mp->inp += strlen(call);
	*mp->inp++ = '|';
	if (l > 0) {
		UC *p;
		for (p = s; p < s+l; ++p) {
			if (mp->inp >= mp->data + (myl - 4)) {
				int off = mp->inp - mp->data;
				myl += 256;
				mp = realloc(mp, myl);
				mp->inp = mp->data + off;
			}
			
			if (*p < 0x20 || *p > 0x7e || *p == '%') {
				sprintf(mp->inp, "%%%02X", *p & 0xff);
				mp->inp += strlen(mp->inp);
			} else 
				*mp->inp++ = *p;
		}
	} 
	*mp->inp++ = '\n';
	*mp->inp = 0;
	cmsg_send(f->outq, mp, 0);
	f->sp->flags |= SEL_OUTPUT;
}

/* 
 * send a file out to the user
 */
void send_file(char *name)
{
	int i;
	char buf[MAXPACLEN+1];
	
	FILE *f = xopen("data", name, "r");
	if (f) {
		while (fgets(buf, paclen, f)) {
			i = strlen(buf);
			if (i && buf[i-1] == '\n') 
				buf[--i] = 0;
			send_text(in, buf, i, 1);
		}
		fclose(f);
	}
}

/*
 * the callback (called by sel_run) that handles all the inputs and outputs
 */

int fcb_handler(sel_t *sp, int in, int out, int err)
{
	fcb_t *f = sp->fcb;
	cmsg_t *mp, *omp;
	
	/* input modes */
	if (ending == 0 && in) {
		char *p, buf[MAXBUFL];
		int r;

		/* read what we have into a buffer */
		r = read(f->cnum, buf, MAXBUFL);
		if (r < 0) {
			switch (errno) {
			case EINTR:
			case EINPROGRESS:
			case EAGAIN:
				goto lout;
			default:
				dbg(DBUF,"got errno %d in input", errno);
				ending++;
				return 1;
			}
		} else if (r == 0) {
			dbg(DBUF, "ending normally");
			ending++;
			return 1;
		}

		dbgdump(DBUF, "in ->", buf, r);
		
		/* create a new message buffer if required */
		if (!f->in)
			f->in = cmsg_new(MAXBUFL+1, f->sort, f);
		mp = f->in;

		switch (f->sort) {
		case TEXT:
			p = buf;
			if (f->echo)
				omp = cmsg_new(3*r+1, f->sort, f);
			while (r > 0 && p < &buf[r]) {

				/* echo processing */
				if (f->echo) {
					switch (*p) {
					case '\b':
					case 0x7f:
						strcpy(omp->inp, "\b \b");
						omp->inp += strlen(omp->inp);
						break;
					case '\r':
						break;
					case '\n':
						strcpy(omp->inp, "\r\n");
						omp->inp += 2;
						break;
					default:
						*omp->inp++ = *p;
					}
				}
				
				/* character processing */
				switch (*p) {
				case '\t':
					if (int_tabs) {
						memset(mp->inp, ' ', tabsize);
						mp->inp += tabsize;
						++p;
					} else {
						*mp->inp++ = *p++;
					}
					break;
				case 0x08:
				case 0x7f:
					if (mp->inp > mp->data)
						mp->inp--;
					++p;
					break;
				default:
					if (nl == '\n' && *p == '\r') {   /* ignore \r in telnet mode (ugh) */
						p++;
					} else if (nl == '\r' && *p == '\n') {  /* and ignore \n in ax25 mode (double ugh) */
						p++;
					} else if (*p == nl) {
						if (mp->inp == mp->data)
							*mp->inp++ = ' ';
						*mp->inp = 0;              /* zero terminate it, but don't include it in the length */
						dbgdump(DMSG, "QUEUE TEXT", mp->data, mp->inp-mp->data);
						cmsg_send(f->inq, mp, 0);
						f->in = mp = cmsg_new(MAXBUFL+1, f->sort, f);
						++p;
					} else {
						if (mp->inp < &mp->data[MAXBUFL-8])
							*mp->inp++ = *p++;
						else {
							mp->inp = mp->data;
						}
					}
				}
			}
			
			/* queue any echo text */
			if (f->echo) {
				dbgdump(DMSG, "QUEUE ECHO TEXT", omp->data, omp->inp - omp->data);
				cmsg_send(f->outq, omp, 0);
				f->sp->flags |= SEL_OUTPUT;
			}
			
			break;

		case MSG:
			p = buf;
			while (r > 0 && p < &buf[r]) {
				UC ch = *p++;
				
				if (mp->inp >= mp->data + (MAXBUFL-1)) {
					mp->state = 0;
					mp->inp = mp->data;
					dbg(DMSG, "Message longer than %d received", MAXBUFL);
				}

				switch (mp->state) {
				case 0: 
					if (ch == '%') {
						mp->hex_high = 0;
						mp->state = 1;
					} else if (ch == '\n') {
						/* kick it upstairs */
						*mp->inp = 0;
						dbgdump(DMSG, "QUEUE MSG", mp->data, mp->inp - mp->data);
						cmsg_send(f->inq, mp, 0);
						mp = f->in = cmsg_new(MAXBUFL+1, f->sort, f);
					} else if (ch < 0x20 || ch > 0x7e) {
						dbg(DMSG, "Illegal character (0x%02X) received", *p);
						mp->inp = mp->data;
					} else {
						*mp->inp++ = ch;
					}
					break;

				case 1:
					mp->state = 2;
					if (ch >= '0' && ch <= '9') 
						mp->hex_high = (ch - '0') << 4;
					else if (ch >= 'A' && ch <= 'F')
						mp->hex_high = (ch - 'A' + 10) << 4;
					else {
						dbg(DMSG, "Illegal hex char (%c) received in state 1", ch);
						mp->inp = mp->data;
						mp->state = 0;
					}
					break;
					
				case 2:
					if (ch >= '0' && ch <= '9') 
						*mp->inp++ = mp->hex_high | (ch - '0');
					else if (ch >= 'A' && ch <= 'F')
						*mp->inp++ = mp->hex_high | (ch - 'A' + 10);
					else {
						dbg(DMSG, "Illegal hex char (%c) received in state 2", ch);
						mp->inp = mp->data;
					}
					mp->state = 0;
				}
			}
			break;
			
		default:
			die("invalid sort (%d) in input handler", f->sort);
		}
	}
	
	/* output modes */
lout:;
	if (out) {
		int l, r;
		
		if (!f->out) {
			mp = f->out = cmsg_next(f->outq);
			if (!mp) {
				sp->flags &= ~SEL_OUTPUT;
				return 0;
			}
			mp->inp = mp->data;
		} else {
			mp = f->out;
		}
		l = mp->size - (mp->inp - mp->data);
		if (l > 0) {
			
			dbgdump(DBUF, "<-out", mp->inp, l);
			
			r = write(f->cnum, mp->inp, l);
			if (r < 0) {
				switch (errno) {
				case EINTR:
				case EINPROGRESS:
				case EAGAIN:
					goto lend;
				default:
					dbg(DBUF,"got errno %d in output", errno);
					ending++;
					return 1;
				}
			} else if (r > 0) {
				mp->inp += r;
			}
		} else if (l < 0) 
			die("got negative length in handler on node");
		if (mp->inp - mp->data >= mp->size) {
			cmsg_callback(mp, 0);
			f->out = 0;
		}
	}
lend:;
	return 0;
}

/* 
 * set up the various mode flags, NL endings and things
 */
void setconntype(char *m)
{
	connsort = strlower(m);
	if (eq(connsort, "telnet") || eq(connsort, "local") || eq(connsort, "nlonly")) {
		nl = '\n';
		echo = 1;
		mode = eq(connsort, "nlonly") ? 2 : 1;
	} else if (eq(connsort, "ax25")) {
		nl = '\r';
		echo = 0;
		mode = 0;
	} else if (eq(connsort, "connect")) {
		nl = '\n';
		echo = 0;
		mode = 3;
	} else {
		die("Connection type must be \"telnet\", \"nlonly\", \"ax25\", \"login\" or \"local\"");
	}
}


/*
 * things to do with ongoing processing of inputs
 */

void process_stdin()
{
	cmsg_t *wmp, *mp = cmsg_next(in->inq);
	char *p;
	int i, hasa = 0, hasn = 0;
	char callsign[MAXCALLSIGN+1];
	
	if (mp) {
		dbg(DMSG, "MSG size: %d", mp->size);
		
		/* check for echos */
		if (echocancel) {
			for (wmp = 0; wmp = chain_get_next(&echobase, wmp); ) {
				if (!memcmp(wmp->data, mp->data, wmp->size)) {
					cmsg_callback(mp, 0);
					return;
				}
			}
		}

		switch (state) {
		case CONNECTED:
			if (mp->size > 0) {
				send_msg(node, 'I', mp->data, mp->size);
			}
			break;
		case WAITLOGIN:
			for (i = 0; i < mp->size; ++i) {
				UC ch = mp->data[i];
				if (i < MAXCALLSIGN) {
					if (isalpha(ch))
						++hasa;
					if (isdigit(ch))
						++hasn;
				    if (isalnum(ch) || ch == '-')
						callsign[i] = ch;
					else
						die("invalid callsign");
				} else 
					die("invalid callsign");
			}
			callsign[i]= 0;
			if (strlen(callsign) < 3)
				die("invalid callsign");
			if (hasa && hasn)
				;
			else
				die("invalid callsign");
			call = strupper(callsign);
			
			/* check the callsign against the regexes */
			if (!iscallsign(call)) {
				die("Sorry, %s isn't a valid callsign", call);
			}
			
			/* strip off a '-0' at the end */
			i = strlen(call);
			if (call[i-1] == '0' && call[i-2] == '-')
				call[i-2] = 0;

			alarm(0);
			signal(SIGALRM, SIG_IGN);
			
			/* tell the cluster who I am */
			send_msg(node, 'A', connsort, strlen(connsort));
			
			chgstate(CONNECTED);
			send_file("connected");
			break;
			
		case DOCHAT:

			break;
		}

		cmsg_callback(mp, 0);

	}
}

void process_node()
{
	cmsg_t *mp = cmsg_next(node->inq);
	if (mp) {
		dbg(DMSG, "MSG size: %d", mp->size);
	
		if (mp->size > 0 && mp->inp > mp->data) {
			char *p = strchr(mp->data, '|');
			if (p)
				p++;
			switch (mp->data[0]) {
			case 'Z':
				ending++;
				return;
			case 'E':
				if (isdigit(*p))
					in->echo = *p - '0';
				break;
			case 'B':
				if (isdigit(*p))
					in->buffer_it = *p - '0';
				break;
			case 'D':
				if (p) {
					int l = mp->inp - (UC *) p;
					send_text(in, p, l, 1);
				}
				break;
			default:
				break;
			}
		}
		cmsg_callback(mp, 0);
	} else {
		flush_text(in);
	}
}

/*
 * things to do with going away
 */

void term_timeout(int i)
{
	/* none of this is going to be reused so don't bother cleaning up properly */
	if (isatty(0))
		tcflush(0, TCIOFLUSH);
	kill(getpid(), 9);			/* commit suicide */
}

void terminate(int i)
{
	signal(SIGALRM, term_timeout);
	alarm(10);
	
	if (node && node->sp->sort) {
		sel_close(node->sp);
	}
	while (in && in->sp->sort && !is_chain_empty(in->outq)) {
		sel_run();
	}
	sel_run();
	sel_run();
	sel_run();
	sel_run();
	sel_run();
	sel_run();
	sel_run();
	sel_run();
	if (in && in->t_set)
		tcsetattr(0, TCSADRAIN, &in->t);
	exit(i);
}

void login_timeout(int i)
{
	write(0, "Timed Out", 10);
	write(0, &nl, 1);
	terminate(0);
}

/*
 * things to do with initialisation
 */

void initargs(int argc, char *argv[])
{
	int i, c, err = 0;

	while ((c = getopt(argc, argv, "eh:l:p:x:")) > 0) {
		switch (c) {
		case 'e':
			echocancel ^= 1;
			break;
		case 'h':
			node_addr = optarg;
			break;
		case 'l':
			paclen = atoi(optarg);
			if (paclen < 80)
				paclen = 80;
			if (paclen > MAXPACLEN)
				paclen = MAXPACLEN;
			break;
		case 'p':
			node_port = atoi(optarg);
			break;
		case 'x':
			dbginit("client");
			dbgset(atoi(optarg));
			break;
		default:
			++err;
			goto lerr;
		}
	}

lerr:
	if (err) {
		die("usage: client [-e|-x n|-h<host>|-p<port>|-l<paclen>] <call>|login [local|telnet|ax25]");
	}
	
	if (optind < argc) {
		call = strupper(argv[optind]);
		++optind;
	}
	if (!call)
		die("Must have at least a callsign (for now)");

	if (optind < argc) {
		setconntype(argv[optind]);		
	} else {
		setconntype("local");
	}

	/* this is kludgy, but hey so is the rest of this! */
	if (mode != 0 && paclen == DEFPACLEN) {
		paclen = MAXPACLEN;
	}
}

void connect_to_node()
{
	struct hostent *hp, *gethostbyname();
	struct sockaddr_in server;
	int nodef;
	int one = 1;
	sel_t *sp;
	struct linger lg;
					
	if ((hp = gethostbyname(node_addr)) == 0) 
		die("Unknown host tcp host %s for printer", node_addr);

	memset(&server, 0, sizeof server);
	server.sin_family = AF_INET;
	memcpy(&server.sin_addr, hp->h_addr, hp->h_length);
	server.sin_port = htons(node_port);
						
	nodef = socket(AF_INET, SOCK_STREAM, 0);
	if (nodef < 0) 
		die("Can't open socket to %s port %d (%d)", node_addr, node_port, errno);

	if (connect(nodef, (struct sockaddr *) &server, sizeof server) < 0) {
		die("Error on connect to %s port %d (%d)", node_addr, node_port, errno);
	}

	memset(&lg, 0, sizeof lg);
	if (setsockopt(nodef, SOL_SOCKET, SO_LINGER, &lg, sizeof lg) < 0) {
		die("Error on SO_LINGER to %s port %d (%d)", node_addr, node_port, errno);
	}
	if (setsockopt(nodef, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof one) < 0) {
		die("Error on SO_KEEPALIVE to %s port %d (%d)", node_addr, node_port, errno);
	}
	
	node = fcb_new(nodef, MSG);
	node->sp = sel_open(nodef, node, "Msg System", fcb_handler, MSG, SEL_INPUT);
	
}

/*
 * the program itself....
 */

int main(int argc, char *argv[])
{
	/* compile regexes for iscallsign */
	{
		myregex_t *rp;
		for (rp = iscallreg; rp->in; ++rp) {
			regex_t reg;
			int r = regcomp(&reg, rp->in, REG_EXTENDED|REG_ICASE|REG_NOSUB);
			if (r)
				die("regcomp returned %d for '%s'", r, rp->in);
			rp->regex = malloc(sizeof(regex_t));
			if (!rp->regex)
				die("out of room - compiling regexes");
			*rp->regex = reg;
		}
	}
	
	/* set up environment */
	{
		char *p = getenv("DXSPIDER_ROOT");
		if (p)
			root = p;
		p = getenv("DXSPIDER_HOST");
		if (p)
			node_addr = p;
		p = getenv("DXSPIDER_PORT");
		if (p)
			node_port = atoi(p);
		p = getenv("DXSPIDER_PACLEN");
		if (p) {
			paclen = atoi(p);
			if (paclen < 80)
				paclen = 80;
			if (paclen > MAXPACLEN)
				paclen = MAXPACLEN;
		}
	}
	
	/* get program arguments, initialise stuff */
	initargs(argc, argv);
	sel_init(10, 0, 10000);

	/* trap signals */
	signal(SIGHUP, SIG_IGN);
	signal(SIGINT, terminate);
	signal(SIGQUIT, terminate);
	signal(SIGTERM, terminate);
#ifdef SIGPWR
	signal(SIGPWR, terminate);
#endif
	
	/* init a few things */
	chain_init(&echobase);

	/* connect up stdin */
	in = fcb_new(0, TEXT);
	in->sp = sel_open(0, in, "STDIN", fcb_handler, TEXT, SEL_INPUT);
	if (!isatty(0) || tcgetattr(0, &in->t) < 0) {
		in->echo = echo;
		in->t_set = 0;
	} else {
		struct termios t = in->t;
		t.c_lflag &= ~(ECHO|ECHONL|ICANON);
		t.c_oflag = 0;
		if (tcsetattr(0, TCSANOW, &t) < 0) 
			die("tcsetattr (%d)", errno);
		in->echo = echo;
		in->t_set = 1;
	}
	in->buffer_it = 1;

	/* connect up node */
	connect_to_node();

	/* is this a login? */
	if (eq(call, "LOGIN") || eq(call, "login")) {
		send_file("issue");
		signal(SIGALRM, login_timeout);
		alarm(timeout);
		send_text(in, "login: ", 7, 0);
		chgstate(WAITLOGIN);
	} else {
		int i;
		
		/* check the callsign against the regexes */
		if (!iscallsign(call)) {
			die("Sorry, %s isn't a valid callsign", call);
		}

		/* strip off a '-0' at the end */
		i = strlen(call);
		if (call[i-1] == '0' && call[i-2] == '-')
			call[i-2] = 0;
		
		/* tell the cluster who I am */
		send_msg(node, 'A', connsort, strlen(connsort));
	
		chgstate(CONNECTED);
		send_file("connected");
	}
	

	/* main processing loop */
	while (ending == 0) {
		sel_run();
		if (ending == 0) {
			process_stdin();
			process_node();
		}
	}
	terminate(0);
}






