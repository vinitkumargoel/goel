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

// ---- one-time libssh2 init ------------------------------------------------

static pthread_once_t g_once = PTHREAD_ONCE_INIT;
static int g_init_rc = 0;

static void gsb_do_init(void) { g_init_rc = libssh2_init(0); }

// ---- small helpers --------------------------------------------------------

static void gsb_set(GSBResult *r, int code, const char *msg) {
    r->code = code;
    if (msg) {
        strncpy(r->message, msg, sizeof(r->message) - 1);
        r->message[sizeof(r->message) - 1] = '\0';
    }
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

// Non-blocking connect with a bounded timeout. Returns a connected socket or -1.
static int gsb_tcp_connect(const char *host, int port, GSBResult *r) {
    char portstr[16];
    snprintf(portstr, sizeof(portstr), "%d", port > 0 ? port : 22);

    struct addrinfo hints, *res = NULL, *ai = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, portstr, &hints, &res) != 0 || !res) {
        gsb_set(r, GSB_ERR_RESOLVE, "Could not resolve host");
        return -1;
    }

    int sock = -1;
    for (ai = res; ai; ai = ai->ai_next) {
        sock = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (sock < 0) continue;

        int flags = fcntl(sock, F_GETFL, 0);
        fcntl(sock, F_SETFL, flags | O_NONBLOCK);

        int rc = connect(sock, ai->ai_addr, ai->ai_addrlen);
        if (rc == 0) {
            fcntl(sock, F_SETFL, flags);
            break;  // immediate connect
        }
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
            }
        }
        close(sock);
        sock = -1;
    }
    freeaddrinfo(res);
    if (sock < 0) gsb_set(r, GSB_ERR_CONNECT, "Could not connect to host");
    return sock;
}

// Full connect + host-key check + auth. On success returns a blocking session
// with `*sock_out` owned by the caller (tear down via gsb_teardown).
static LIBSSH2_SESSION *gsb_open(const GSBAuth *a, int *sock_out, GSBResult *r) {
    pthread_once(&g_once, gsb_do_init);
    if (g_init_rc != 0) { gsb_set(r, GSB_ERR_INIT, "libssh2 init failed"); return NULL; }

    int sock = gsb_tcp_connect(a->host, a->port, r);
    if (sock < 0) return NULL;

    LIBSSH2_SESSION *session = libssh2_session_init();
    if (!session) { gsb_set(r, GSB_ERR_INIT, "session init failed"); close(sock); return NULL; }
    libssh2_session_set_blocking(session, 1);
    // Bound every blocking op so a dead/stalled peer can't hang the transfer
    // thread forever (the abort flag is only observed on progress ticks, which
    // stop arriving if no data moves). 60s of zero progress = failure.
    libssh2_session_set_timeout(session, 60000);

    if (libssh2_session_handshake(session, sock) != 0) {
        char *err = NULL; libssh2_session_last_error(session, &err, NULL, 0);
        gsb_set(r, GSB_ERR_HANDSHAKE, err ? err : "SSH handshake failed");
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

    // Auth: password first (if given), then optionally ssh-agent.
    int authed = 0;
    if (a->password && a->password[0]) {
        if (libssh2_userauth_password(session, a->username, a->password) == 0) authed = 1;
    }
    if (!authed && a->use_agent) {
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
    if (!authed) {
        gsb_set(r, GSB_ERR_AUTH, "Authentication failed");
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

// Sleep to keep the running average under `max_bps`. `elapsed_ns` is the time
// since the transfer started; `sofar` the bytes moved in that window.
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

// ---- public operations ----------------------------------------------------

GSBResult gsb_probe(const GSBAuth *auth) {
    GSBResult r = { GSB_OK, 0, {0}, {0} };
    int sock = -1;
    LIBSSH2_SESSION *s = gsb_open(auth, &sock, &r);
    if (!s) return r;
    gsb_teardown(s, sock);
    return r;
}

GSBResult gsb_list(const GSBAuth *auth, const char *path,
                   gsb_entry_cb cb, void *userdata) {
    GSBResult r = { GSB_OK, 0, {0}, {0} };
    int sock = -1;
    LIBSSH2_SESSION *s = gsb_open(auth, &sock, &r);
    if (!s) return r;

    LIBSSH2_SFTP *sftp = libssh2_sftp_init(s);
    if (!sftp) { gsb_set(&r, GSB_ERR_SFTP, "SFTP subsystem unavailable"); gsb_teardown(s, sock); return r; }

    LIBSSH2_SFTP_HANDLE *dir = libssh2_sftp_opendir(sftp, path);
    if (!dir) {
        gsb_set(&r, GSB_ERR_OPEN, "Could not open directory");
        libssh2_sftp_shutdown(sftp); gsb_teardown(s, sock); return r;
    }

    char name[1024];
    LIBSSH2_SFTP_ATTRIBUTES attrs;
    int n;
    while ((n = libssh2_sftp_readdir_ex(dir, name, sizeof(name) - 1, NULL, 0, &attrs)) > 0) {
        name[n] = '\0';
        if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) continue;
        int is_dir = (attrs.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) &&
                     LIBSSH2_SFTP_S_ISDIR(attrs.permissions);
        long long size = (attrs.flags & LIBSSH2_SFTP_ATTR_SIZE) ? (long long)attrs.filesize : 0;
        long long mtime = (attrs.flags & LIBSSH2_SFTP_ATTR_ACMODTIME) ? (long long)attrs.mtime : 0;
        unsigned long perms = (attrs.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) ? attrs.permissions : 0;
        if (cb) cb(userdata, name, is_dir, size, mtime, perms);
    }

    libssh2_sftp_closedir(dir);
    libssh2_sftp_shutdown(sftp);
    gsb_teardown(s, sock);
    return r;
}

GSBResult gsb_size(const GSBAuth *auth, const char *remote) {
    GSBResult r = { GSB_OK, 0, {0}, {0} };
    int sock = -1;
    LIBSSH2_SESSION *s = gsb_open(auth, &sock, &r);
    if (!s) return r;

    LIBSSH2_SFTP *sftp = libssh2_sftp_init(s);
    if (!sftp) { gsb_set(&r, GSB_ERR_SFTP, "SFTP subsystem unavailable"); gsb_teardown(s, sock); return r; }

    LIBSSH2_SFTP_ATTRIBUTES attrs;
    if (libssh2_sftp_stat(sftp, remote, &attrs) != 0) {
        gsb_set(&r, GSB_ERR_STAT, "Could not stat remote file");
    } else if (attrs.flags & LIBSSH2_SFTP_ATTR_SIZE) {
        r.value = (long long)attrs.filesize;
    }
    libssh2_sftp_shutdown(sftp);
    gsb_teardown(s, sock);
    return r;
}

GSBResult gsb_download(const GSBAuth *auth, const char *remote,
                       long long resume_from, long long max_bps,
                       gsb_write_cb write_cb, gsb_progress_cb progress_cb,
                       void *userdata) {
    GSBResult r = { GSB_OK, 0, {0}, {0} };
    int sock = -1;
    LIBSSH2_SESSION *s = gsb_open(auth, &sock, &r);
    if (!s) return r;

    LIBSSH2_SFTP *sftp = libssh2_sftp_init(s);
    if (!sftp) { gsb_set(&r, GSB_ERR_SFTP, "SFTP subsystem unavailable"); gsb_teardown(s, sock); return r; }

    LIBSSH2_SFTP_HANDLE *h = libssh2_sftp_open(sftp, remote, LIBSSH2_FXF_READ, 0);
    if (!h) {
        gsb_set(&r, GSB_ERR_OPEN, "Could not open remote file");
        libssh2_sftp_shutdown(sftp); gsb_teardown(s, sock); return r;
    }

    long long total = 0;
    LIBSSH2_SFTP_ATTRIBUTES attrs;
    if (libssh2_sftp_fstat(h, &attrs) == 0 && (attrs.flags & LIBSSH2_SFTP_ATTR_SIZE))
        total = (long long)attrs.filesize;
    r.value = total;

    if (resume_from > 0) libssh2_sftp_seek64(h, (libssh2_uint64_t)resume_from);

    struct timespec start;
    clock_gettime(CLOCK_MONOTONIC, &start);

    char buf[GSB_XFER_BUF_SIZE];
    long long sofar = resume_from;
    long long window = 0;  // bytes since `start`, for throttling
    for (;;) {
        ssize_t got = libssh2_sftp_read(h, buf, sizeof(buf));
        if (got == 0) break;                 // EOF
        if (got < 0) { gsb_set(&r, GSB_ERR_IO, "Read error"); break; }

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

    libssh2_sftp_close(h);
    libssh2_sftp_shutdown(sftp);
    gsb_teardown(s, sock);
    return r;
}

GSBResult gsb_upload(const GSBAuth *auth, const char *remote, long long total,
                     long long max_bps,
                     gsb_read_cb read_cb, gsb_progress_cb progress_cb,
                     void *userdata) {
    GSBResult r = { GSB_OK, 0, {0}, {0} };
    int sock = -1;
    LIBSSH2_SESSION *s = gsb_open(auth, &sock, &r);
    if (!s) return r;

    LIBSSH2_SFTP *sftp = libssh2_sftp_init(s);
    if (!sftp) { gsb_set(&r, GSB_ERR_SFTP, "SFTP subsystem unavailable"); gsb_teardown(s, sock); return r; }

    LIBSSH2_SFTP_HANDLE *h = libssh2_sftp_open(sftp, remote,
        LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC,
        LIBSSH2_SFTP_S_IRUSR | LIBSSH2_SFTP_S_IWUSR |
        LIBSSH2_SFTP_S_IRGRP | LIBSSH2_SFTP_S_IROTH);
    if (!h) {
        gsb_set(&r, GSB_ERR_OPEN, "Could not create remote file");
        libssh2_sftp_shutdown(sftp); gsb_teardown(s, sock); return r;
    }

    struct timespec start;
    clock_gettime(CLOCK_MONOTONIC, &start);

    char buf[GSB_XFER_BUF_SIZE];
    long long sofar = 0;
    for (;;) {
        long got = read_cb ? read_cb(buf, (long)sizeof(buf), userdata) : 0;
        if (got == 0) break;                 // EOF
        if (got < 0) { gsb_set(&r, GSB_ERR_ABORTED, "Aborted"); break; }

        // sftp_write can accept a partial buffer; loop until the chunk is flushed.
        char *p = buf;
        long remaining = got;
        int failed = 0;
        while (remaining > 0) {
            ssize_t wrote = libssh2_sftp_write(h, p, (size_t)remaining);
            if (wrote < 0) { gsb_set(&r, GSB_ERR_IO, "Remote write failed"); failed = 1; break; }
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

    libssh2_sftp_close(h);
    libssh2_sftp_shutdown(sftp);
    gsb_teardown(s, sock);
    return r;
}

GSBResult gsb_mkdir(const GSBAuth *auth, const char *path) {
    GSBResult r = { GSB_OK, 0, {0}, {0} };
    int sock = -1;
    LIBSSH2_SESSION *s = gsb_open(auth, &sock, &r);
    if (!s) return r;
    LIBSSH2_SFTP *sftp = libssh2_sftp_init(s);
    if (!sftp) { gsb_set(&r, GSB_ERR_SFTP, "SFTP subsystem unavailable"); gsb_teardown(s, sock); return r; }
    if (libssh2_sftp_mkdir(sftp, path,
            LIBSSH2_SFTP_S_IRWXU | LIBSSH2_SFTP_S_IRGRP | LIBSSH2_SFTP_S_IXGRP |
            LIBSSH2_SFTP_S_IROTH | LIBSSH2_SFTP_S_IXOTH) != 0) {
        gsb_set(&r, GSB_ERR_MKDIR, "Could not create directory");
    }
    libssh2_sftp_shutdown(sftp);
    gsb_teardown(s, sock);
    return r;
}

GSBResult gsb_remove(const GSBAuth *auth, const char *path, int is_dir) {
    GSBResult r = { GSB_OK, 0, {0}, {0} };
    int sock = -1;
    LIBSSH2_SESSION *s = gsb_open(auth, &sock, &r);
    if (!s) return r;
    LIBSSH2_SFTP *sftp = libssh2_sftp_init(s);
    if (!sftp) { gsb_set(&r, GSB_ERR_SFTP, "SFTP subsystem unavailable"); gsb_teardown(s, sock); return r; }
    int rc = is_dir ? libssh2_sftp_rmdir(sftp, path) : libssh2_sftp_unlink(sftp, path);
    if (rc != 0) gsb_set(&r, GSB_ERR_REMOVE, "Could not remove item");
    libssh2_sftp_shutdown(sftp);
    gsb_teardown(s, sock);
    return r;
}

GSBResult gsb_rename(const GSBAuth *auth, const char *from, const char *to) {
    GSBResult r = { GSB_OK, 0, {0}, {0} };
    int sock = -1;
    LIBSSH2_SESSION *s = gsb_open(auth, &sock, &r);
    if (!s) return r;
    LIBSSH2_SFTP *sftp = libssh2_sftp_init(s);
    if (!sftp) { gsb_set(&r, GSB_ERR_SFTP, "SFTP subsystem unavailable"); gsb_teardown(s, sock); return r; }
    if (libssh2_sftp_rename(sftp, from, to) != 0) {
        gsb_set(&r, GSB_ERR_RENAME, "Could not rename item");
    }
    libssh2_sftp_shutdown(sftp);
    gsb_teardown(s, sock);
    return r;
}
