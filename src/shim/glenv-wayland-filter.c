/*
 * glenv — Wayland explicit-sync advertisement filter.
 *
 * The problem
 * -----------
 * A glibc GL stack that cannot export native fence file descriptors (glenv's
 * Mesa on nouveau: pipe_screen.caps.native_fence_fd is never set, there is no
 * kernel dma_fence behind nouveau_fence) has no EGL_ANDROID_native_fence_sync.
 * Chromium still selects explicit sync whenever the compositor advertises
 * wp_linux_drm_syncobj_manager_v1, then waits for an acquire fence it can
 * never obtain: buffers are attached without a release point, wl_buffer.release
 * never arrives, the frame scheduler stalls and the window stays black.
 *
 * What this library does
 * ----------------------
 * It hides that single global announcement from glibc Wayland clients.
 * libwayland receives the event through recvmsg() on the display socket, so
 * the library interposes recvmsg(), walks the Wayland message framing
 * (sender_id + size<<16|opcode, size always includes the 8 byte header and is
 * a multiple of 4) and rewrites the interface name inside complete messages
 * with a decoy of identical length. Nothing is dropped, so message sizes,
 * framing and the stream position stay exactly as the compositor sent them;
 * the client simply compares against a name it does not know and never binds
 * the manager. It then falls back to implicit sync, where release is signalled
 * by wl_buffer.release, and renders normally.
 *
 * Incomplete trailing messages are buffered until the rest arrives. That is
 * safe: the client could not use a partial message anyway, so no event is ever
 * delayed by the filter. If framing ever fails to validate, the connection is
 * switched to pass-through mode instead of risking corruption.
 *
 * Only libc calls are interposed, which is what a statically linked libwayland
 * (Chromium) still performs dynamically. Nothing here is specific to any
 * application.
 *
 * Build:  gcc -shared -fPIC -O2 -nostdlib -o glenv-wayland-filter.so \
 *             glenv-wayland-filter.c
 *         (-nostdlib keeps the object libc-agnostic: the few undefined symbols
 *          are resolved from whichever libc loaded it, and only glibc reads
 *          /etc/ld.so.preload, so musl processes never see this library.)
 */

#include <stddef.h>

extern void *dlsym(void *, const char *);
extern char *getenv(const char *);
extern int getpid(void);
extern long write(int, const void *, unsigned long);
extern void *malloc(unsigned long);
extern void *realloc(void *, unsigned long);
extern void free(void *);

/* glibc RTLD_NEXT: resolve the next definition after this preloaded object. */
#define RTLD_NEXT ((void *)-1)

/* Linux ABI values, spelled out so the file needs no libc headers. */
#define WL_AF_UNIX 1
#define WL_MSG_DONTWAIT 0x40
#define WL_SOL_SOCKET 1
#define WL_SCM_RIGHTS 1
#define WL_CMSG_HDR 16 /* CMSG_ALIGN(sizeof(struct cmsghdr)) on 64 bit */

#define kHiddenGlobal "wp_linux_drm_syncobj_manager_v1"
#define kDecoyGlobal "wp_linux_drm_syncoff_manager_v1"
#define kGlobalLen 31

#define kMaxFd 8192
#define kMaxConns 4
#define kMaxFds 16
#define kMaxBuf (4u * 1024u * 1024u)

/* Same layout as the Linux/glibc x86_64 definitions. */
struct wl_iovec {
	void *base;
	unsigned long len;
};

struct wl_msghdr {
	void *name;
	int namelen;
	struct wl_iovec *iov;
	unsigned long iovlen;
	void *control;
	unsigned long controllen;
	int flags;
};

struct wl_cmsghdr {
	unsigned long len;
	int level;
	int type;
};

struct wl_addr {
	unsigned short family;
	char path[108];
};

typedef long (*recvmsg_fn)(int, void *, int);
typedef int (*connect_fn)(int, const void *, unsigned);
typedef int (*close_fn)(int);
typedef int (*dup2_fn)(int, int);
typedef int (*dup3_fn)(int, int, int);

static recvmsg_fn g_recvmsg;
static connect_fn g_connect;
static close_fn g_close;
static dup2_fn g_dup2;
static dup3_fn g_dup3;

struct conn {
	int fd;
	int used;
	int broken; /* framing failed or out of memory: pass everything through */
	int eof;
	unsigned char *buf;
	unsigned long len;
	unsigned long cap;
	int fds[kMaxFds];
	int nfds;
};

static struct conn g_conns[kMaxConns];
static unsigned char g_iswl[kMaxFd];
static char g_wld[512]; /* $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY */
static int g_wlsock = -1; /* inherited fd from WAYLAND_SOCKET */
static volatile int g_lock;
static int g_debug;

static void wl_lock(void)
{
	int zero;

	do {
		zero = 0;
	} while (!__atomic_compare_exchange_n(&g_lock, &zero, 1, 1,
					      __ATOMIC_ACQUIRE,
					      __ATOMIC_RELAXED));
}

static void wl_unlock(void)
{
	__atomic_store_n(&g_lock, 0, __ATOMIC_RELEASE);
}

static void put_str(char *dst, unsigned long *n, unsigned long max,
		    const char *s)
{
	while (*s && *n + 1 < max)
		dst[(*n)++] = *s++;
}

static void put_num(char *dst, unsigned long *n, unsigned long max, int v)
{
	char tmp[12];
	int i = 0, neg = 0;

	if (v < 0) {
		neg = 1;
		v = -v;
	}
	if (v == 0)
		tmp[i++] = '0';
	while (v > 0 && i < 12) {
		tmp[i++] = (char)('0' + v % 10);
		v /= 10;
	}
	if (neg && i < 12)
		tmp[i++] = '-';
	while (i > 0 && *n + 1 < max)
		dst[(*n)++] = tmp[--i];
}

static void log_msg(const char *a, const char *b, int num, int show_num)
{
	char buf[192];
	unsigned long n = 0;

	if (!g_debug)
		return;
	buf[n++] = '[';
	put_num(buf, &n, sizeof buf, getpid());
	buf[n++] = ']';
	buf[n++] = ' ';
	put_str(buf, &n, sizeof buf, a);
	if (b)
		put_str(buf, &n, sizeof buf, b);
	if (show_num) {
		buf[n++] = ' ';
		put_num(buf, &n, sizeof buf, num);
	}
	buf[n] = 0;
	write(2, buf, n);
	write(2, "\n", 1);
}

static void replace_bytes(unsigned char *h, unsigned long n, const char *from,
			  const char *to, unsigned long sl)
{
	unsigned long i, j;

	if (sl > n)
		return;
	for (i = 0; i + sl <= n; i++) {
		for (j = 0; j < sl && h[i + j] == (unsigned char)from[j]; j++)
			;
		if (j != sl)
			continue;
		for (j = 0; j < sl; j++)
			h[i + j] = (unsigned char)to[j];
		i += sl - 1;
	}
}

/*
 * Walk the buffered stream, mask the hidden interface name inside every
 * complete message and return how many bytes are ready for the client.
 */
static unsigned long scan_ready(struct conn *c)
{
	unsigned long off = 0;

	if (c->broken)
		return c->len; /* pass-through mode: framing is untrusted */

	while (c->len - off >= 8) {
		unsigned char *p = c->buf + off;
		unsigned long size;

		size = ((unsigned long)p[4] | ((unsigned long)p[5] << 8) |
			((unsigned long)p[6] << 16) |
			((unsigned long)p[7] << 24)) >>
		       16;
		if (size < 8 || (size & 3) != 0) {
			c->broken = 1;
			log_msg("glenv: wayland framing rejected, filter off",
				NULL, 0, 0);
			break;
		}
		if (c->len - off < size)
			break; /* incomplete tail: wait for the rest */
		replace_bytes(p, size, kHiddenGlobal, kDecoyGlobal,
			      kGlobalLen);
		off += size;
	}
	return off;
}

static int conn_grow(struct conn *c, unsigned long need)
{
	unsigned long ncap;
	unsigned char *nb;

	if (c->cap >= need)
		return 1;
	ncap = c->cap ? c->cap : 4096;
	while (ncap < need)
		ncap *= 2;
	if (ncap > kMaxBuf)
		return 0;
	nb = realloc(c->buf, ncap);
	if (!nb)
		return 0;
	c->buf = nb;
	c->cap = ncap;
	return 1;
}

static struct conn *conn_for(int fd)
{
	int i, free_slot = -1;

	for (i = 0; i < kMaxConns; i++) {
		if (g_conns[i].used && g_conns[i].fd == fd)
			return &g_conns[i];
		if (!g_conns[i].used && free_slot < 0)
			free_slot = i;
	}
	if (free_slot < 0)
		return NULL;
	g_conns[free_slot].fd = fd;
	g_conns[free_slot].used = 1;
	g_conns[free_slot].broken = 0;
	g_conns[free_slot].eof = 0;
	g_conns[free_slot].buf = NULL;
	g_conns[free_slot].len = 0;
	g_conns[free_slot].cap = 0;
	g_conns[free_slot].nfds = 0;
	return &g_conns[free_slot];
}

static void conn_drop(int fd)
{
	int i;

	for (i = 0; i < kMaxConns; i++) {
		if (!g_conns[i].used || g_conns[i].fd != fd)
			continue;
		free(g_conns[i].buf);
		if (g_close) {
			int j;

			for (j = 0; j < g_conns[i].nfds; j++)
				g_close(g_conns[i].fds[j]);
		}
		g_conns[i].used = 0;
		g_conns[i].buf = NULL;
		g_conns[i].len = 0;
		g_conns[i].cap = 0;
		g_conns[i].nfds = 0;
	}
}

static unsigned long iov_room(struct wl_msghdr *m)
{
	unsigned long total = 0, i;

	for (i = 0; i < m->iovlen; i++)
		total += m->iov[i].len;
	return total;
}

static unsigned long iov_put(struct wl_msghdr *m, const unsigned char *src,
			     unsigned long n)
{
	unsigned long done = 0, i;

	for (i = 0; i < m->iovlen && done < n; i++) {
		unsigned long room = m->iov[i].len;

		if (room > n - done)
			room = n - done;
		if (room) {
			unsigned char *dst = m->iov[i].base;
			unsigned long k;

			for (k = 0; k < room; k++)
				dst[k] = src[done + k];
			done += room;
		}
	}
	return done;
}

/* Collect SCM_RIGHTS descriptors that arrived with a datagram we consumed. */
static void stash_fds(struct conn *c, struct wl_msghdr *m)
{
	unsigned long off = 0;

	if (!m->control || !m->controllen)
		return;
	while (off + sizeof(struct wl_cmsghdr) <= m->controllen) {
		struct wl_cmsghdr *ch =
		    (struct wl_cmsghdr *)((char *)m->control + off);
		unsigned long align;

		if (ch->len < sizeof(*ch) || off + ch->len > m->controllen)
			break;
		if (ch->level == WL_SOL_SOCKET && ch->type == WL_SCM_RIGHTS) {
			unsigned long data = ch->len - WL_CMSG_HDR;
			int *f = (int *)((char *)ch + WL_CMSG_HDR);
			unsigned long k, n = data / 4;

			for (k = 0; k < n; k++) {
				if (c->nfds < kMaxFds)
					c->fds[c->nfds++] = f[k];
				else if (g_close)
					g_close(f[k]);
			}
		}
		align = (ch->len + 7UL) & ~7UL;
		if (align < sizeof(*ch))
			break;
		off += align;
	}
}

/* Hand stashed descriptors back to the caller, as many as fit. */
static void deliver_fds(struct conn *c, struct wl_msghdr *m)
{
	unsigned long space = (m->control && m->controllen) ? m->controllen
							    : 0;
	unsigned long room, n, k, i;
	struct wl_cmsghdr *ch;
	int *dst;

	m->controllen = 0;
	if (c->nfds == 0 || space < WL_CMSG_HDR + 4)
		return;

	room = (space - WL_CMSG_HDR) & ~7UL;
	n = room / 4;
	if (n > (unsigned long)c->nfds)
		n = (unsigned long)c->nfds;
	if (n == 0)
		return;

	ch = (struct wl_cmsghdr *)m->control;
	ch->len = WL_CMSG_HDR + n * 4;
	ch->level = WL_SOL_SOCKET;
	ch->type = WL_SCM_RIGHTS;
	dst = (int *)((char *)ch + WL_CMSG_HDR);
	for (k = 0; k < n; k++)
		dst[k] = c->fds[k];
	for (k = n * 4; k < ((n * 4 + 7) & ~7UL); k++)
		((char *)ch + WL_CMSG_HDR)[k] = 0;
	m->controllen = WL_CMSG_HDR + ((n * 4 + 7) & ~7UL);

	for (i = n; i < (unsigned long)c->nfds; i++)
		c->fds[i - n] = c->fds[i];
	c->nfds -= (int)n;
}

static int g_resolving;

static void resolve(void)
{
	/* dlsym may close descriptors behind our back while it works, which
	 * would re-enter close() and resolve() again. Never nest. */
	if (g_resolving)
		return;
	g_resolving = 1;
	if (!g_close) /* first: it is the one our own code may need */
		g_close = (close_fn)dlsym(RTLD_NEXT, "close");
	if (!g_recvmsg)
		g_recvmsg = (recvmsg_fn)dlsym(RTLD_NEXT, "recvmsg");
	if (!g_connect)
		g_connect = (connect_fn)dlsym(RTLD_NEXT, "connect");
	if (!g_dup2)
		g_dup2 = (dup2_fn)dlsym(RTLD_NEXT, "dup2");
	if (!g_dup3)
		g_dup3 = (dup3_fn)dlsym(RTLD_NEXT, "dup3");
	g_resolving = 0;
}

/* Is this a Wayland display socket? Either the well-known "wayland*"
 * basename, or exactly $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY (which may carry a
 * custom name without "wayland" in it). */
static int path_is_wayland(const char *p)
{
	unsigned long i;

	if (!p || !*p)
		return 0;
	for (i = 0; p[i]; i++) {
		const char *needle = "wayland";
		unsigned long k = 0;

		while (needle[k] && p[i + k] && p[i + k] == needle[k])
			k++;
		if (!needle[k])
			return 1;
	}
	if (g_wld[0]) {
		for (i = 0; g_wld[i] && p[i] == g_wld[i]; i++)
			;
		if (!g_wld[i] && !p[i])
			return 1;
	}
	return 0;
}

__attribute__((constructor)) static void init(void)
{
	const char *v, *d;
	unsigned long i, j;

	resolve();

	v = getenv("GLENV_WAYLAND_FILTER_DEBUG");
	g_debug = (v && *v && *v != '0') ? 1 : 0;

	d = getenv("WAYLAND_DISPLAY");
	if (!d || !*d)
		d = "wayland-0";
	i = 0;
	v = getenv("XDG_RUNTIME_DIR");
	if (v) {
		for (j = 0; v[j] && i + 1 < sizeof g_wld; j++)
			g_wld[i++] = v[j];
		if (i + 1 < sizeof g_wld)
			g_wld[i++] = '/';
	}
	for (j = 0; d[j] && i + 1 < sizeof g_wld; j++)
		g_wld[i++] = d[j];
	g_wld[i] = 0;
	/* WAYLAND_DISPLAY may itself be an absolute path */
	if (d[0] == '/') {
		i = 0;
		for (j = 0; d[j] && i + 1 < sizeof g_wld; j++)
			g_wld[i++] = d[j];
		g_wld[i] = 0;
	}

	v = getenv("WAYLAND_SOCKET");
	if (v && *v >= '0' && *v <= '9') {
		int fd = 0;

		while (*v >= '0' && *v <= '9')
			fd = fd * 10 + (*v++ - '0');
		if (fd >= 0 && fd < kMaxFd) {
			g_wlsock = fd;
			g_iswl[fd] = 1;
		}
	}

	log_msg("glenv: wayland sync advertisement filter active: ",
		g_wld, 0, 0);
}

int connect(int fd, const void *addr, unsigned len)
{
	const struct wl_addr *a = addr;
	char path[109];
	unsigned long i, limit;
	int wayland = 0, r;

	if (!g_connect)
		resolve();
	if (!g_connect)
		return -1;
	if (!a || a->family != WL_AF_UNIX)
		return g_connect(fd, addr, len);

	/* sun_path is only guaranteed to hold `len - 2` bytes. */
	limit = (len > 2 && len < 110) ? (unsigned long)len - 2 : 108UL;
	if (limit > 108)
		limit = 108;
	if (a->path[0] == 0) {
		/* abstract namespace: name without trailing NUL */
		unsigned long k = 0;

		for (i = 1; i <= limit && k + 1 < sizeof path; i++)
			path[k++] = a->path[i];
		path[k] = 0;
	} else {
		for (i = 0; i < limit && i + 1 < sizeof path && a->path[i]; i++)
			path[i] = a->path[i];
		path[i] = 0;
	}
	wayland = path_is_wayland(path);

	r = g_connect(fd, addr, len);
	if (r == 0 && wayland && fd >= 0 && fd < kMaxFd) {
		wl_lock();
		g_iswl[fd] = 1;
		conn_drop(fd);
		wl_unlock();
		log_msg("glenv: watching wayland socket ", path, fd, 1);
	}
	return r;
}

int close(int fd)
{
	if (!g_close)
		resolve();
	if (fd >= 0 && fd < kMaxFd && g_iswl[fd]) {
		wl_lock();
		g_iswl[fd] = 0;
		conn_drop(fd);
		wl_unlock();
	}
	return g_close ? g_close(fd) : -1;
}

/* Both replace a descriptor, so any buffered state for it must go. */
int dup2(int oldfd, int newfd)
{
	if (!g_dup2)
		resolve();
	if (newfd >= 0 && newfd < kMaxFd) {
		wl_lock();
		g_iswl[newfd] = 0;
		conn_drop(newfd);
		wl_unlock();
	}
	return g_dup2 ? g_dup2(oldfd, newfd) : -1;
}

int dup3(int oldfd, int newfd, int flags)
{
	if (!g_dup3)
		resolve();
	if (newfd >= 0 && newfd < kMaxFd) {
		wl_lock();
		g_iswl[newfd] = 0;
		conn_drop(newfd);
		wl_unlock();
	}
	return g_dup3 ? g_dup3(oldfd, newfd, flags) : -1;
}

long recvmsg(int fd, void *vmsg, int flags)
{
	struct wl_msghdr *msg = vmsg;
	struct conn *c;

	if (!g_recvmsg)
		resolve();
	if (!g_recvmsg || !msg || fd < 0 || fd >= kMaxFd || !g_iswl[fd] ||
	    !msg->iov || msg->iovlen == 0)
		return g_recvmsg ? g_recvmsg(fd, vmsg, flags) : -1;

	wl_lock();
	c = conn_for(fd);
	if (!c) {
		wl_unlock();
		return g_recvmsg(fd, vmsg, flags);
	}

	for (;;) {
		unsigned long avail, room, n;
		long r;

		if (c->eof && c->len == 0) {
			int j;

			for (j = 0; j < c->nfds; j++)
				if (g_close)
					g_close(c->fds[j]);
			c->nfds = 0;
			wl_unlock();
			return 0;
		}
		if (c->broken && c->len == 0) {
			wl_unlock();
			return g_recvmsg(fd, vmsg, flags);
		}

		/* Masking happens inside scan_ready(); if framing failed the
		 * connection switches to pass-through and everything left in
		 * the buffer is handed over untouched, in order. */
		avail = scan_ready(c);
		if (c->broken)
			avail = c->len;

		if (avail > 0) {
			room = iov_room(msg);
			n = avail < room ? avail : room;
			if (n == 0) {
				/* caller has no space: fall back to native */
				wl_unlock();
				return g_recvmsg(fd, vmsg, flags);
			}
			iov_put(msg, c->buf, n);
			if (n < c->len) {
				unsigned long k;

				for (k = 0; k + n < c->len; k++)
					c->buf[k] = c->buf[k + n];
			}
			c->len -= n;
			deliver_fds(c, msg);
			msg->flags = 0;
			msg->namelen = 0;
			wl_unlock();
			return (long)n;
		}

		/* nothing complete yet: pull more bytes from the socket */
		if (!conn_grow(c, c->len + 8192)) {
			c->broken = 1;
			log_msg("glenv: wayland filter out of memory, "
				"pass-through",
				NULL, 0, 0);
			continue;
		}
		{
			struct wl_msghdr m;
			struct wl_iovec one;
			char ctrl[512];
			char *p = (char *)&m;
			unsigned long z;

			for (z = 0; z < sizeof m; z++)
				p[z] = 0;
			one.base = c->buf + c->len;
			one.len = c->cap - c->len;
			m.iov = &one;
			m.iovlen = 1;
			m.control = ctrl;
			m.controllen = sizeof ctrl;
			for (z = 0; z < sizeof ctrl; z++)
				ctrl[z] = 0;

			r = g_recvmsg(fd, &m, flags);
			if (r > 0) {
				c->len += (unsigned long)r;
				stash_fds(c, &m);
				log_msg("glenv: wayland bytes ", NULL,
					(int)r, 1);
				continue;
			}
			if (r == 0) {
				c->eof = 1;
				c->broken = 1; /* flush whatever we hold */
				continue;
			}
			wl_unlock();
			return -1; /* errno already set by the real call */
		}
	}
}
