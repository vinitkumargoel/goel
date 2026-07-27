#include "include/ssh_bridge.h"

#include <libssh2.h>
#include <libssh2_sftp.h>

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <netdb.h>
#include <netinet/in.h>
#include <pthread.h>

// The per-transfer read/write buffer. libssh2 ≥1.11 pipelines a single
// `libssh2_sftp_read`/`libssh2_sftp_write` internally, keeping multiple packets
// in flight up to this size — so a bigger buffer is the main lever against the
// request/response round-trip that otherwise caps SFTP throughput on any
// non-LAN link. 256 KiB sits comfortably inside the 1 MiB transfer-thread stack
// (see `SFTPClient` thread setup).
#define GSB_XFER_BUF_SIZE (256 * 1024)

// Longest remote path this shim will assemble. Server-supplied names are bounded
// by the listing buffer below; the join guards against overflowing this.
#define GSB_PATH_MAX 4096

// ---- one-time libssh2 init ------------------------------------------------

static pthread_once_t g_once = PTHREAD_ONCE_INIT;
static int g_init_rc = 0;

static void gsb_do_init(void) { g_init_rc = libssh2_init(0); }

// ---- session --------------------------------------------------------------

// One authenticated connection with its SFTP channel already open. Owned by, and
// only ever touched from, a single thread — libssh2 sessions are not thread-safe
// and the Swift layer pins each of these to a dedicated thread.
struct GSBSession {
    LIBSSH2_SESSION *session;
    LIBSSH2_SFTP    *sftp;
    int              sock;
    char             fingerprint[80];
};

// ---- small helpers --------------------------------------------------------

static void gsb_set(GSBResult *r, int code, const char *msg) {
    r->code = code;
    if (msg) {
        strncpy(r->message, msg, sizeof(r->message) - 1);
        r->message[sizeof(r->message) - 1] = '\0';
    }
}

// Set an error and append libssh2's own explanation when it has one. Without
// this a dropped session surfaces as a bare "Could not open directory", which
// reads as a permissions problem rather than a dead connection.
static void gsb_set_detailed(GSBResult *r, LIBSSH2_SESSION *s, int code, const char *what) {
    char *e = NULL;
    if (s) libssh2_session_last_error(s, &e, NULL, 0);
    char msg[256];
    snprintf(msg, sizeof(msg), "%s%s%s", what,
             (e && *e) ? " — " : "", (e && *e) ? e : "");
    gsb_set(r, code, msg);
}

// Guard every session operation: a NULL or half-torn-down handle must fail
// cleanly rather than dereference.
static int gsb_usable(GSBSession *s, GSBResult *r) {
    if (!s || !s->session || !s->sftp) {
        gsb_set(r, GSB_ERR_SFTP, "The connection to this server is no longer open.");
        return 0;
    }
    return 1;
}

static void gsb_hex_sha256(const char *raw, size_t len, char *out, size_t out_cap) {
    static const char *H = "0123456789abcdef";
    size_t n = 0;
    for (size_t i = 0; i < len && (n + 2) < out_cap; i++) {
        unsigned char b = (unsigned char)raw[i];
        out[n++] = H[b >> 4];
        out[n++] = H[b & 0xf];
    }
    out[n] = '\0';
}

// Join a directory path and a child name into `out`. Returns 0 when the result
// would not fit, so a pathological name can never overflow the buffer.
static int gsb_join(const char *dir, const char *name, char *out, size_t cap) {
    if (!dir || !name) return 0;
    int n;
    if (strcmp(dir, ".") == 0 || dir[0] == '\0') {
        n = snprintf(out, cap, "%s", name);
    } else if (dir[strlen(dir) - 1] == '/') {
        n = snprintf(out, cap, "%s%s", dir, name);
    } else {
        n = snprintf(out, cap, "%s/%s", dir, name);
    }
    return (n > 0 && (size_t)n < cap);
}

// Non-blocking connect with a bounded timeout. Returns a connected socket or -1.
static int gsb_tcp_connect(const char *host, int port, GSBResult *r) {
    char portstr[16];
    snprintf(portstr, sizeof(portstr), "%d", port > 0 ? port : 22);

    struct addrinfo hints, *res = NULL, *ai = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, portstr, &hints, &res) != 0 || !res) {
        char m[192];
        snprintf(m, sizeof(m), "Could not resolve \"%s\"", host);
        gsb_set(r, GSB_ERR_RESOLVE, m);
        return -1;
    }

    int sock = -1;
    int last_errno = 0;   // why the final candidate address failed, for the message
    for (ai = res; ai; ai = ai->ai_next) {
        sock = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (sock < 0) { last_errno = errno; continue; }

        int flags = fcntl(sock, F_GETFL, 0);
        fcntl(sock, F_SETFL, flags | O_NONBLOCK);

        int rc = connect(sock, ai->ai_addr, ai->ai_addrlen);
        if (rc == 0) {
            fcntl(sock, F_SETFL, flags);
            break;  // immediate connect
        }
        last_errno = errno;
        if (errno == EINPROGRESS) {
            fd_set wset;
            FD_ZERO(&wset);
            FD_SET(sock, &wset);
            struct timeval tv = { 15, 0 };  // 15s connect timeout
            rc = select(sock + 1, NULL, &wset, NULL, &tv);
            if (rc > 0) {
                int soerr = 0;
                socklen_t l = sizeof(soerr);
                getsockopt(sock, SOL_SOCKET, SO_ERROR, &soerr, &l);
                if (soerr == 0) {
                    fcntl(sock, F_SETFL, flags);
                    break;  // connected
                }
                last_errno = soerr;
            } else {
                last_errno = (rc == 0) ? ETIMEDOUT : errno;
            }
        }
        close(sock);
        sock = -1;
    }
    freeaddrinfo(res);
    if (sock < 0) {
        // Carry the OS reason through: "no route to host" on a LAN address is
        // how macOS reports a missing Local Network permission, and it is
        // otherwise indistinguishable from the server being down.
        //
        // strerror_r, not strerror: sessions run on their own threads, and
        // strerror returns a shared static buffer.
        char reason[96] = {0};
        if (last_errno && strerror_r(last_errno, reason, sizeof(reason)) != 0) {
            snprintf(reason, sizeof(reason), "errno %d", last_errno);
        }
        char m[192];
        snprintf(m, sizeof(m), "Could not connect to %s:%s%s%s", host, portstr,
                 reason[0] ? " — " : "", reason);
        gsb_set(r, GSB_ERR_CONNECT, m);
    }
    return sock;
}

// Connect + handshake + host-key check, and nothing else — everything that must
// happen BEFORE a credential is offered. Split out (rather than inlined into
// gsb_open) so `gsb_hostkey` can stop here, learn the fingerprint and hang up
// without ever presenting a password or a key. On success returns a blocking
// session with `*sock_out` owned by the caller and `r->fingerprint` filled.
static LIBSSH2_SESSION *gsb_connect_verified(const GSBAuth *a, int *sock_out, GSBResult *r) {
    pthread_once(&g_once, gsb_do_init);
    if (g_init_rc != 0) { gsb_set(r, GSB_ERR_INIT, "libssh2 init failed"); return NULL; }

    int sock = gsb_tcp_connect(a->host, a->port, r);
    if (sock < 0) return NULL;

    LIBSSH2_SESSION *session = libssh2_session_init();
    if (!session) { gsb_set(r, GSB_ERR_INIT, "session init failed"); close(sock); return NULL; }
    libssh2_session_set_blocking(session, 1);
    // Bound every blocking op so a dead/stalled peer can't hang the owning
    // thread forever (the abort flag is only observed on progress ticks, which
    // stop arriving if no data moves). 60s of zero progress = failure.
    libssh2_session_set_timeout(session, 60000);

    if (libssh2_session_handshake(session, sock) != 0) {
        // libssh2 reports most handshake faults as KEY_EXCHANGE_FAILURE ("Unable
        // to exchange encryption keys") including the peer going away mid-
        // handshake, so its text alone names a cause that usually isn't the real
        // one. Keep it, but anchor it to the endpoint we were talking to.
        char *err = NULL; libssh2_session_last_error(session, &err, NULL, 0);
        char msg[256];
        snprintf(msg, sizeof(msg), "SSH handshake with %s:%d failed%s%s",
                 a->host, a->port > 0 ? a->port : 22,
                 (err && *err) ? " — " : "", (err && *err) ? err : "");
        gsb_set(r, GSB_ERR_HANDSHAKE, msg);
        libssh2_session_free(session); close(sock); return NULL;
    }

    // Host-key fingerprint (SHA-256), trust-on-first-use vs. pinned.
    const char *hash = libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_SHA256);
    if (!hash) {
        gsb_set(r, GSB_ERR_HOSTKEY, "Server did not present a host key");
        libssh2_session_disconnect(session, "bye");
        libssh2_session_free(session); close(sock); return NULL;
    }
    gsb_hex_sha256(hash, 32, r->fingerprint, sizeof(r->fingerprint));
    if (a->expected_fp && a->expected_fp[0] &&
        strcmp(a->expected_fp, r->fingerprint) != 0) {
        gsb_set(r, GSB_ERR_HOSTKEY_MISMATCH,
                "Host key changed — refusing to connect");
        libssh2_session_disconnect(session, "bye");
        libssh2_session_free(session); close(sock); return NULL;
    }

    *sock_out = sock;
    return session;
}

// Full connect + host-key check + auth. On success returns a blocking session
// with `*sock_out` owned by the caller (tear down via gsb_teardown).
static LIBSSH2_SESSION *gsb_open(const GSBAuth *a, int *sock_out, GSBResult *r) {
    int sock = -1;
    LIBSSH2_SESSION *session = gsb_connect_verified(a, &sock, r);
    if (!session) return NULL;

    // Auth: password first (if given), then a private key file, then optionally
    // ssh-agent. `tried` records what was actually attempted so a failure can say
    // which credential the server refused instead of a bare "auth failed".
    int authed = 0;
    char tried[128] = {0};
    char detail[160] = {0};
    #define GSB_NOTE_TRIED(what) do { \
        if (tried[0]) strncat(tried, ", ", sizeof(tried) - strlen(tried) - 1); \
        strncat(tried, (what), sizeof(tried) - strlen(tried) - 1); \
    } while (0)

    if (a->password && a->password[0]) {
        GSB_NOTE_TRIED("password");
        if (libssh2_userauth_password(session, a->username, a->password) == 0) authed = 1;
    }
    if (!authed && a->private_key_path && a->private_key_path[0]) {
        GSB_NOTE_TRIED("key");
        // NULL public key => libssh2 derives it from the private key.
        const char *pub  = (a->public_key_path && a->public_key_path[0]) ? a->public_key_path : NULL;
        const char *pass = (a->key_passphrase  && a->key_passphrase[0])  ? a->key_passphrase  : NULL;
        if (libssh2_userauth_publickey_fromfile_ex(session, a->username,
                                                   (unsigned int)strlen(a->username),
                                                   pub, a->private_key_path, pass) == 0) {
            authed = 1;
        } else {
            // Distinguishes "wrong passphrase / unreadable key" from "server
            // rejected this key", which are very different fixes for the user.
            char *e = NULL; libssh2_session_last_error(session, &e, NULL, 0);
            if (e && *e) snprintf(detail, sizeof(detail), "%s", e);
        }
    }
    if (!authed && a->use_agent) {
        GSB_NOTE_TRIED("ssh-agent");
        LIBSSH2_AGENT *agent = libssh2_agent_init(session);
        if (agent && libssh2_agent_connect(agent) == 0 &&
            libssh2_agent_list_identities(agent) == 0) {
            struct libssh2_agent_publickey *id = NULL, *prev = NULL;
            while (libssh2_agent_get_identity(agent, &id, prev) == 0) {
                if (libssh2_agent_userauth(agent, a->username, id) == 0) { authed = 1; break; }
                prev = id;
            }
        }
        if (agent) { libssh2_agent_disconnect(agent); libssh2_agent_free(agent); }
    }
    #undef GSB_NOTE_TRIED
    if (!authed) {
        char msg[256];
        if (!tried[0]) {
            snprintf(msg, sizeof(msg),
                     "No credentials to try for \"%s\" — set a password, choose a "
                     "private key, or enable the SSH agent", a->username);
        } else {
            snprintf(msg, sizeof(msg), "Server rejected the %s for \"%s\"%s%s",
                     tried, a->username,
                     detail[0] ? " — " : "", detail[0] ? detail : "");
        }
        gsb_set(r, GSB_ERR_AUTH, msg);
        libssh2_session_disconnect(session, "bye");
        libssh2_session_free(session); close(sock); return NULL;
    }

    *sock_out = sock;
    return session;
}

static void gsb_teardown(LIBSSH2_SESSION *session, int sock) {
    if (session) {
        libssh2_session_disconnect(session, "bye");
        libssh2_session_free(session);
    }
    if (sock >= 0) close(sock);
}

// Sleep to keep the running average under `max_bps`. `start` is when the
// transfer began; `sofar` the bytes moved in that window.
static void gsb_throttle(long long max_bps, long long sofar, struct timespec *start) {
    if (max_bps <= 0) return;
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    double elapsed = (now.tv_sec - start->tv_sec) + (now.tv_nsec - start->tv_nsec) / 1e9;
    double target = (double)sofar / (double)max_bps;  // seconds this many bytes *should* take
    if (target > elapsed) {
        double sleep_s = target - elapsed;
        if (sleep_s > 0 && sleep_s < 5.0) usleep((useconds_t)(sleep_s * 1e6));
    }
}

// ---- session lifecycle ----------------------------------------------------

GSBSession *gsb_session_open(const GSBAuth *auth, GSBResult *r) {
    if (!auth || !r) return NULL;
    int sock = -1;
    LIBSSH2_SESSION *s = gsb_open(auth, &sock, r);
    if (!s) return NULL;

    LIBSSH2_SFTP *sftp = libssh2_sftp_init(s);
    if (!sftp) {
        gsb_set_detailed(r, s, GSB_ERR_SFTP, "SFTP subsystem unavailable");
        gsb_teardown(s, sock);
        return NULL;
    }

    GSBSession *out = (GSBSession *)calloc(1, sizeof(GSBSession));
    if (!out) {
        gsb_set(r, GSB_ERR_INIT, "Out of memory opening the session");
        libssh2_sftp_shutdown(sftp);
        gsb_teardown(s, sock);
        return NULL;
    }
    out->session = s;
    out->sftp = sftp;
    out->sock = sock;
    // `r->fingerprint` was filled during the host-key check; keep a copy on the
    // session so the caller can pin it at any point in the session's life.
    strncpy(out->fingerprint, r->fingerprint, sizeof(out->fingerprint) - 1);
    return out;
}

void gsb_session_close(GSBSession *s) {
    if (!s) return;
    if (s->sftp) libssh2_sftp_shutdown(s->sftp);
    gsb_teardown(s->session, s->sock);
    s->sftp = NULL;
    s->session = NULL;
    s->sock = -1;
    free(s);
}

const char *gsb_session_fingerprint(const GSBSession *s) {
    return s ? s->fingerprint : "";
}

int gsb_session_alive(GSBSession *s) {
    if (!s || !s->session || !s->sftp || s->sock < 0) return 0;
    // A local check only: peek at the socket without consuming. A clean close
    // from the peer shows up as a zero-length read; a live connection with no
    // pending data gives EAGAIN. Anything else is a dead socket. Deliberately
    // no round trip — this is called before reusing an idle session, and paying
    // an RTT to ask "are you there?" would undo the point of pooling.
    char b;
    ssize_t n;
    // A signal delivered to this thread mid-peek is not evidence of anything;
    // treating EINTR as death would throw away a healthy session and pay a full
    // handshake to rebuild it.
    do {
        n = recv(s->sock, &b, 1, MSG_PEEK | MSG_DONTWAIT);
    } while (n < 0 && errno == EINTR);
    if (n == 0) return 0;
    if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK) return 0;
    return 1;
}

// ---- one-shot operations --------------------------------------------------

GSBResult gsb_probe(const GSBAuth *auth) {
    GSBResult r = { GSB_OK, 0, {0}, {0} };
    int sock = -1;
    LIBSSH2_SESSION *s = gsb_open(auth, &sock, &r);
    if (!s) return r;
    gsb_teardown(s, sock);
    return r;
}

GSBResult gsb_hostkey(const GSBAuth *auth) {
    GSBResult r = { GSB_OK, 0, {0}, {0} };
    int sock = -1;
    // Deliberately gsb_connect_verified, not gsb_open: the point of this call is
    // to learn who we are talking to while offering nothing to a host we have
    // not yet decided to trust.
    LIBSSH2_SESSION *s = gsb_connect_verified(auth, &sock, &r);
    if (!s) return r;
    gsb_teardown(s, sock);
    return r;
}

// ---- listing --------------------------------------------------------------

// Fill a GSBStat from libssh2 attributes. `is_link` cannot be derived from a
// followed stat, so the caller supplies it.
static void gsb_fill_stat(GSBStat *out, const LIBSSH2_SFTP_ATTRIBUTES *a, int is_link) {
    out->exists  = 1;
    out->is_dir  = (a->flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) &&
                   LIBSSH2_SFTP_S_ISDIR(a->permissions);
    out->is_link = is_link;
    out->size    = (a->flags & LIBSSH2_SFTP_ATTR_SIZE) ? (long long)a->filesize : 0;
    out->mtime   = (a->flags & LIBSSH2_SFTP_ATTR_ACMODTIME) ? (long long)a->mtime : 0;
    out->perms   = (a->flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) ? a->permissions : 0;
    out->uid     = (a->flags & LIBSSH2_SFTP_ATTR_UIDGID) ? a->uid : 0;
    out->gid     = (a->flags & LIBSSH2_SFTP_ATTR_UIDGID) ? a->gid : 0;
}

GSBResult gsb_list(GSBSession *s, const char *path,
                   gsb_entry_cb cb, void *userdata) {
    GSBResult r = { GSB_OK, 0, {0}, {0} };
    if (!gsb_usable(s, &r)) return r;

    LIBSSH2_SFTP_HANDLE *dir = libssh2_sftp_opendir(s->sftp, path);
    if (!dir) {
        gsb_set_detailed(&r, s->session, GSB_ERR_OPEN, "Could not open directory");
        return r;
    }

    char name[1024];
    LIBSSH2_SFTP_ATTRIBUTES attrs;
    int n;
    // A negative return is NOT end-of-directory — that is n == 0. It is a read
    // failure, an SFTP protocol error, or a server-supplied name too long for the
    // buffer, arriving partway through the enumeration. Leaving the loop on it the
    // same way as on EOF reported a TRUNCATED listing as a complete one, and this
    // listing is what the upload path uses to decide which remote names are free:
    // entries that fell off the end look unused, so the overwrite prompt never
    // appears and the upload truncates a file the user was never asked about. Fail
    // the whole call instead — a directory we could only partly read is a directory
    // we cannot vouch for. (The session is blocking, so EAGAIN is not in play.)
    while ((n = libssh2_sftp_readdir_ex(dir, name, sizeof(name) - 1, NULL, 0, &attrs)) != 0) {
        if (n < 0) {
            gsb_set_detailed(&r, s->session, GSB_ERR_IO, "Directory listing ended early");
            break;
        }
        name[n] = '\0';
        if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) continue;

        int has_perms = (attrs.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) != 0;
        // readdir reports the entry itself (lstat semantics), so a symlink is
        // visible here rather than being silently reported as its target.
        int is_link = has_perms && LIBSSH2_SFTP_S_ISLNK(attrs.permissions);
        int is_dir  = has_perms && LIBSSH2_SFTP_S_ISDIR(attrs.permissions);
        long long size = (attrs.flags & LIBSSH2_SFTP_ATTR_SIZE) ? (long long)attrs.filesize : 0;
        long long mtime = (attrs.flags & LIBSSH2_SFTP_ATTR_ACMODTIME) ? (long long)attrs.mtime : 0;
        unsigned long perms = has_perms ? attrs.permissions : 0;
        unsigned long uid = (attrs.flags & LIBSSH2_SFTP_ATTR_UIDGID) ? attrs.uid : 0;
        unsigned long gid = (attrs.flags & LIBSSH2_SFTP_ATTR_UIDGID) ? attrs.gid : 0;

        char target[GSB_PATH_MAX];
        target[0] = '\0';
        if (is_link) {
            // Two extra round trips, but only for links, which are rare in a
            // typical listing. Without them a symlinked directory is
            // indistinguishable from a file and cannot be opened.
            char full[GSB_PATH_MAX];
            if (gsb_join(path, name, full, sizeof(full))) {
                int tn = libssh2_sftp_symlink_ex(s->sftp, full, (unsigned int)strlen(full),
                                                 target, sizeof(target) - 1,
                                                 LIBSSH2_SFTP_READLINK);
                target[(tn > 0 && (size_t)tn < sizeof(target)) ? tn : 0] = '\0';

                // Follow the link to learn whether it lands on a directory, so the
                // browser can offer to open it. A dangling link simply stays a file.
                LIBSSH2_SFTP_ATTRIBUTES tattrs;
                if (libssh2_sftp_stat_ex(s->sftp, full, (unsigned int)strlen(full),
                                         LIBSSH2_SFTP_STAT, &tattrs) == 0 &&
                    (tattrs.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS)) {
                    is_dir = LIBSSH2_SFTP_S_ISDIR(tattrs.permissions) ? 1 : 0;
                    if (tattrs.flags & LIBSSH2_SFTP_ATTR_SIZE)
                        size = (long long)tattrs.filesize;
                }
            }
        }

        if (cb) cb(userdata, name, is_dir, size, mtime, perms, is_link, target, uid, gid);
    }

    libssh2_sftp_closedir(dir);
    return r;
}

GSBResult gsb_size(GSBSession *s, const char *remote) {
    GSBResult r = { GSB_OK, 0, {0}, {0} };
    if (!gsb_usable(s, &r)) return r;

    LIBSSH2_SFTP_ATTRIBUTES attrs;
    if (libssh2_sftp_stat(s->sftp, remote, &attrs) != 0) {
        gsb_set_detailed(&r, s->session, GSB_ERR_STAT, "Could not stat remote file");
    } else if (attrs.flags & LIBSSH2_SFTP_ATTR_SIZE) {
        r.value = (long long)attrs.filesize;
    }
    return r;
}

// ---- transfers ------------------------------------------------------------

GSBResult gsb_download(GSBSession *s, const char *remote,
                       long long resume_from, long long max_bps,
                       gsb_write_cb write_cb, gsb_progress_cb progress_cb,
                       void *userdata) {
    GSBResult r = { GSB_OK, 0, {0}, {0} };
    if (!gsb_usable(s, &r)) return r;

    LIBSSH2_SFTP_HANDLE *h = libssh2_sftp_open(s->sftp, remote, LIBSSH2_FXF_READ, 0);
    if (!h) {
        gsb_set_detailed(&r, s->session, GSB_ERR_OPEN, "Could not open remote file");
        return r;
    }

    long long total = 0;
    LIBSSH2_SFTP_ATTRIBUTES attrs;
    if (libssh2_sftp_fstat(h, &attrs) == 0 && (attrs.flags & LIBSSH2_SFTP_ATTR_SIZE))
        total = (long long)attrs.filesize;
    r.value = total;

    if (resume_from > 0) libssh2_sftp_seek64(h, (libssh2_uint64_t)resume_from);

    struct timespec start;
    clock_gettime(CLOCK_MONOTONIC, &start);

    // Heap, not stack: a 256 KiB frame is a large share of the 1 MiB thread
    // stack, and the session thread now also runs listings and metadata calls.
    char *buf = (char *)malloc(GSB_XFER_BUF_SIZE);
    if (!buf) {
        gsb_set(&r, GSB_ERR_IO, "Out of memory starting the download");
        libssh2_sftp_close(h);
        return r;
    }

    long long sofar = resume_from;
    long long window = 0;  // bytes since `start`, for throttling
    for (;;) {
        ssize_t got = libssh2_sftp_read(h, buf, GSB_XFER_BUF_SIZE);
        if (got == 0) break;                 // EOF
        if (got < 0) { gsb_set_detailed(&r, s->session, GSB_ERR_IO, "Read error"); break; }

        if (write_cb && write_cb(buf, (long)got, userdata) != (long)got) {
            gsb_set(&r, GSB_ERR_IO, "Write to disk failed");
            break;
        }
        sofar += got;
        window += got;
        if (progress_cb && progress_cb(userdata, total, sofar) != 0) {
            gsb_set(&r, GSB_ERR_ABORTED, "Aborted");
            break;
        }
        gsb_throttle(max_bps, window, &start);
    }
    free(buf);

    // EOF is not the same as "the whole file arrived". A stream cut short must
    // fail loudly rather than leave a truncated file looking finished — the Swift
    // side treats a clean return as "every byte moved" and snaps the row to 100%.
    // `total` is 0 when the size was never known, and `<` (not `!=`) so a file
    // that grew mid-read is not failed.
    if (r.code == GSB_OK && total > 0 && sofar < total) {
        char m[160];
        snprintf(m, sizeof(m), "Transfer ended early — received %lld of %lld bytes", sofar, total);
        gsb_set(&r, GSB_ERR_IO, m);
    }

    libssh2_sftp_close(h);
    return r;
}

GSBResult gsb_upload(GSBSession *s, const char *remote, long long total,
                     long long max_bps,
                     gsb_read_cb read_cb, gsb_progress_cb progress_cb,
                     void *userdata) {
    GSBResult r = { GSB_OK, 0, {0}, {0} };
    if (!gsb_usable(s, &r)) return r;

    LIBSSH2_SFTP_HANDLE *h = libssh2_sftp_open(s->sftp, remote,
        LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC,
        LIBSSH2_SFTP_S_IRUSR | LIBSSH2_SFTP_S_IWUSR |
        LIBSSH2_SFTP_S_IRGRP | LIBSSH2_SFTP_S_IROTH);
    if (!h) {
        gsb_set_detailed(&r, s->session, GSB_ERR_OPEN, "Could not create remote file");
        return r;
    }

    struct timespec start;
    clock_gettime(CLOCK_MONOTONIC, &start);

    char *buf = (char *)malloc(GSB_XFER_BUF_SIZE);
    if (!buf) {
        gsb_set(&r, GSB_ERR_IO, "Out of memory starting the upload");
        libssh2_sftp_close(h);
        return r;
    }

    long long sofar = 0;
    for (;;) {
        long got = read_cb ? read_cb(buf, (long)GSB_XFER_BUF_SIZE, userdata) : 0;
        if (got == 0) break;                 // EOF
        if (got < 0) { gsb_set(&r, GSB_ERR_ABORTED, "Aborted"); break; }

        // sftp_write can accept a partial buffer; loop until the chunk is flushed.
        char *p = buf;
        long remaining = got;
        int failed = 0;
        while (remaining > 0) {
            ssize_t wrote = libssh2_sftp_write(h, p, (size_t)remaining);
            if (wrote < 0) {
                gsb_set_detailed(&r, s->session, GSB_ERR_IO, "Remote write failed");
                failed = 1; break;
            }
            p += wrote;
            remaining -= wrote;
        }
        if (failed) break;
        sofar += got;
        if (progress_cb && progress_cb(userdata, total, sofar) != 0) {
            gsb_set(&r, GSB_ERR_ABORTED, "Aborted");
            break;
        }
        gsb_throttle(max_bps, sofar, &start);
    }
    free(buf);

    // Same assertion as the download side: the read callback returning 0 means
    // "no more bytes", which is only the same as "the file is sent" when the
    // count matches. Guarded on GSB_OK so a user cancel still reports as aborted.
    if (r.code == GSB_OK && total > 0 && sofar < total) {
        char m[160];
        snprintf(m, sizeof(m), "Upload ended early — sent %lld of %lld bytes", sofar, total);
        gsb_set(&r, GSB_ERR_IO, m);
    }

    libssh2_sftp_close(h);
    return r;
}

// ---- mutations ------------------------------------------------------------

GSBResult gsb_mkdir(GSBSession *s, const char *path) {
    GSBResult r = { GSB_OK, 0, {0}, {0} };
    if (!gsb_usable(s, &r)) return r;
    if (libssh2_sftp_mkdir(s->sftp, path,
            LIBSSH2_SFTP_S_IRWXU | LIBSSH2_SFTP_S_IRGRP | LIBSSH2_SFTP_S_IXGRP |
            LIBSSH2_SFTP_S_IROTH | LIBSSH2_SFTP_S_IXOTH) != 0) {
        gsb_set_detailed(&r, s->session, GSB_ERR_MKDIR, "Could not create directory");
    }
    return r;
}

GSBResult gsb_remove(GSBSession *s, const char *path, int is_dir) {
    GSBResult r = { GSB_OK, 0, {0}, {0} };
    if (!gsb_usable(s, &r)) return r;
    int rc = is_dir ? libssh2_sftp_rmdir(s->sftp, path) : libssh2_sftp_unlink(s->sftp, path);
    if (rc != 0) gsb_set_detailed(&r, s->session, GSB_ERR_REMOVE, "Could not remove item");
    return r;
}

GSBResult gsb_rename(GSBSession *s, const char *from, const char *to) {
    GSBResult r = { GSB_OK, 0, {0}, {0} };
    if (!gsb_usable(s, &r)) return r;
    if (libssh2_sftp_rename(s->sftp, from, to) != 0) {
        gsb_set_detailed(&r, s->session, GSB_ERR_RENAME, "Could not rename item");
    }
    return r;
}

// ---- metadata -------------------------------------------------------------

// Shared body for lstat/stat. `follow` picks which libssh2 mode to use.
static GSBResult gsb_stat_impl(GSBSession *s, const char *path, GSBStat *out, int follow) {
    GSBResult r = { GSB_OK, 0, {0}, {0} };
    if (!gsb_usable(s, &r)) return r;
    if (!path || !out) { gsb_set(&r, GSB_ERR_STAT, "Nothing to stat"); return r; }
    memset(out, 0, sizeof(*out));

    LIBSSH2_SFTP_ATTRIBUTES attrs;
    int mode = follow ? LIBSSH2_SFTP_STAT : LIBSSH2_SFTP_LSTAT;
    if (libssh2_sftp_stat_ex(s->sftp, path, (unsigned int)strlen(path), mode, &attrs) != 0) {
        gsb_set_detailed(&r, s->session, GSB_ERR_STAT, "Could not read the item's details");
        return r;
    }
    int is_link = (attrs.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) &&
                  LIBSSH2_SFTP_S_ISLNK(attrs.permissions);
    gsb_fill_stat(out, &attrs, follow ? 0 : is_link);
    r.value = out->size;
    return r;
}

GSBResult gsb_lstat(GSBSession *s, const char *path, GSBStat *out) {
    return gsb_stat_impl(s, path, out, 0);
}

GSBResult gsb_stat(GSBSession *s, const char *path, GSBStat *out) {
    return gsb_stat_impl(s, path, out, 1);
}

// Shared body for readlink/realpath — libssh2 exposes both through symlink_ex.
static GSBResult gsb_symlink_query(GSBSession *s, const char *path,
                                   char *buf, size_t cap, int mode, const char *what) {
    GSBResult r = { GSB_OK, 0, {0}, {0} };
    if (!gsb_usable(s, &r)) return r;
    if (!path || !buf || cap == 0) { gsb_set(&r, GSB_ERR_STAT, "Nothing to resolve"); return r; }
    buf[0] = '\0';

    int n = libssh2_sftp_symlink_ex(s->sftp, path, (unsigned int)strlen(path),
                                    buf, (unsigned int)(cap - 1), mode);
    if (n < 0) {
        gsb_set_detailed(&r, s->session, GSB_ERR_STAT, what);
        buf[0] = '\0';
        return r;
    }
    // libssh2 does not NUL-terminate; it returns the length it wrote.
    buf[((size_t)n < cap) ? (size_t)n : (cap - 1)] = '\0';
    r.value = n;
    return r;
}

GSBResult gsb_readlink(GSBSession *s, const char *path, char *buf, size_t cap) {
    return gsb_symlink_query(s, path, buf, cap, LIBSSH2_SFTP_READLINK,
                             "Could not read where this link points");
}

GSBResult gsb_realpath(GSBSession *s, const char *path, char *buf, size_t cap) {
    return gsb_symlink_query(s, path, buf, cap, LIBSSH2_SFTP_REALPATH,
                             "Could not resolve this path on the server");
}

GSBResult gsb_setstat(GSBSession *s, const char *path, unsigned long perms) {
    GSBResult r = { GSB_OK, 0, {0}, {0} };
    if (!gsb_usable(s, &r)) return r;

    // Read-modify-write the permission bits only: sending a zeroed attribute
    // struct with just PERMISSIONS set is what the protocol wants, but the mode
    // must keep the file-type bits or some servers reject it outright.
    // Zeroed first, and the flag checked after: libssh2 only writes a field the
    // server actually sent, so on a server whose STAT omits permissions this
    // would otherwise read uninitialised stack and send it back as the file type.
    LIBSSH2_SFTP_ATTRIBUTES cur;
    memset(&cur, 0, sizeof(cur));
    if (libssh2_sftp_stat_ex(s->sftp, path, (unsigned int)strlen(path),
                             LIBSSH2_SFTP_STAT, &cur) != 0) {
        gsb_set_detailed(&r, s->session, GSB_ERR_STAT, "Could not read the current permissions");
        return r;
    }
    unsigned long type_bits = (cur.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS)
        ? (cur.permissions & ~(unsigned long)07777)
        : 0;

    LIBSSH2_SFTP_ATTRIBUTES attrs;
    memset(&attrs, 0, sizeof(attrs));
    attrs.flags = LIBSSH2_SFTP_ATTR_PERMISSIONS;
    attrs.permissions = type_bits | (perms & 07777);

    if (libssh2_sftp_stat_ex(s->sftp, path, (unsigned int)strlen(path),
                             LIBSSH2_SFTP_SETSTAT, &attrs) != 0) {
        gsb_set_detailed(&r, s->session, GSB_ERR_STAT, "Could not change the permissions");
        return r;
    }
    return r;
}

// blocks * size, saturating at INT64_MAX rather than wrapping.
static long long gsb_scale_blocks(libssh2_uint64_t blocks, unsigned long long size) {
    if (size == 0 || blocks == 0) return 0;
    if (blocks > (unsigned long long)INT64_MAX / size) return INT64_MAX;
    unsigned long long bytes = (unsigned long long)blocks * size;
    return (bytes > (unsigned long long)INT64_MAX) ? INT64_MAX : (long long)bytes;
}

GSBResult gsb_statvfs(GSBSession *s, const char *path, GSBSpace *out) {
    GSBResult r = { GSB_OK, 0, {0}, {0} };
    if (!gsb_usable(s, &r)) return r;
    if (!out) { gsb_set(&r, GSB_ERR_STAT, "Nowhere to report space"); return r; }
    memset(out, 0, sizeof(*out));

    LIBSSH2_SFTP_STATVFS st;
    memset(&st, 0, sizeof(st));
    const char *p = (path && path[0]) ? path : ".";
    if (libssh2_sftp_statvfs(s->sftp, p, (unsigned int)strlen(p), &st) != 0) {
        // Very common: the statvfs@openssh.com extension is optional and plenty
        // of servers omit it. The caller is expected to show nothing, not error.
        gsb_set_detailed(&r, s->session, GSB_ERR_SFTP,
                         "This server does not report free space");
        return r;
    }
    // f_frsize is the fragment size the block counts are expressed in. Guard the
    // multiply so a server reporting nonsense cannot overflow into a negative.
    unsigned long long frsize = st.f_frsize ? st.f_frsize : st.f_bsize;
    if (frsize == 0) frsize = 512;
    // Checked BEFORE multiplying: a wrap is well-defined but numerically wrong,
    // and a wrapped product looks like a small disk rather than an overflow, so
    // saturating afterwards would never see it.
    out->total_bytes = gsb_scale_blocks(st.f_blocks, frsize);
    out->free_bytes  = gsb_scale_blocks(st.f_bavail, frsize);
    return r;
}
