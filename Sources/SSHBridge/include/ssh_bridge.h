#ifndef SSH_BRIDGE_H
#define SSH_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

// Thin C shim over libssh2 SFTP (C-only API). THREAD AFFINITY: `LIBSSH2_SESSION` is not thread-safe, so
// `SFTPSessionActor` pins each session to one thread; sessions are long-lived as handshakes are costly.

#ifdef __cplusplus
extern "C" {
#endif

// Error categories (negative). 0 == success.
enum {
    GSB_OK               =  0,
    GSB_ERR_INIT         = -1,
    GSB_ERR_RESOLVE      = -2,
    GSB_ERR_CONNECT      = -3,
    GSB_ERR_HANDSHAKE    = -4,
    GSB_ERR_HOSTKEY      = -5,   // could not read the host key
    GSB_ERR_HOSTKEY_MISMATCH = -6,
    GSB_ERR_AUTH         = -7,
    GSB_ERR_SFTP         = -8,
    GSB_ERR_OPEN         = -9,
    GSB_ERR_IO           = -10,
    GSB_ERR_ABORTED      = -11,  // a callback asked to stop (pause/cancel)
    GSB_ERR_MKDIR        = -12,
    GSB_ERR_REMOVE       = -13,
    GSB_ERR_STAT         = -14,
    GSB_ERR_RENAME       = -15,
};

typedef struct GSBResult {
    int code;               // one of the GSB_* codes
    long long value;        // file size for size/stat ops, else 0
    char fingerprint[80];   // hex SHA-256 of the server host key (filled on connect)
    char message[256];      // human-readable detail
} GSBResult;

// Session-open parameters; "" / NULL disables a field (public_key_path then derives from the private).
// expected_fp: hex SHA-256 to REQUIRE (else GSB_ERR_HOSTKEY_MISMATCH), "" = TOFU. Order: password, key, agent.
typedef struct GSBAuth {
    const char *host;
    int port;
    const char *username;
    const char *password;
    int use_agent;
    const char *expected_fp;
    const char *private_key_path;
    const char *public_key_path;
    const char *key_passphrase;
} GSBAuth;

// An authenticated, SFTP-initialised connection. Opaque: the layout is private
// to ssh_bridge.c. See the thread-affinity note above.
typedef struct GSBSession GSBSession;

// Write callback: receive `len` bytes; return `len` to continue, anything else
// aborts the download.
typedef long (*gsb_write_cb)(const char *buf, long len, void *userdata);

// Read callback (upload): fill up to `cap` bytes; return count, 0 for EOF,
// negative to abort.
typedef long (*gsb_read_cb)(char *buf, long cap, void *userdata);

// Progress callback: return 0 to continue, nonzero to abort.
typedef int (*gsb_progress_cb)(void *userdata, long long total, long long sofar);

// Directory-entry callback, once per child. is_link: entry itself is a symlink; link_target: "" when
// not a link / unreadable; is_dir: whether the entry RESOLVES to a directory (targets followed).
typedef void (*gsb_entry_cb)(void *userdata, const char *name, int is_dir,
                             long long size, long long mtime, unsigned long perms,
                             int is_link, const char *link_target,
                             unsigned long uid, unsigned long gid);

// ---- session lifecycle ----------------------------------------------------

// Connect, verify the host key, authenticate, open the SFTP channel. NULL on failure with `*r` filled
// (incl. `r->fingerprint` whenever the key was read, so the caller can pin it). Close w/ gsb_session_close.
GSBSession *gsb_session_open(const GSBAuth *auth, GSBResult *r);

// Tear down the SFTP channel, disconnect and close the socket. NULL-safe.
void gsb_session_close(GSBSession *s);

// The host-key fingerprint this session connected with. Never NULL for a live
// session; the storage belongs to the session.
const char *gsb_session_fingerprint(const GSBSession *s);

// Cheap LOCAL liveness check — no round trip. 0 = peer closed or socket errored, so reopen; nonzero
// only means "not known to be dead", which is the most a local check can say.
int gsb_session_alive(GSBSession *s);

// ---- one-shot operations (open their own connection) ----------------------

// Connect + authenticate, then hang up (the "Test Connection" button).
GSBResult gsb_probe(const GSBAuth *auth);

// Connect, handshake, read the host key, disconnect. NO credential is ever offered, so an unknown
// host is safe: the fingerprint gets approved BEFORE any auth. Fills fingerprint; honours expected_fp.
GSBResult gsb_hostkey(const GSBAuth *auth);

// ---- session operations ---------------------------------------------------

// List a remote directory, invoking `cb` for each entry.
GSBResult gsb_list(GSBSession *s, const char *path,
                   gsb_entry_cb cb, void *userdata);

// Size of a single remote file (fills result.value), or an error.
GSBResult gsb_size(GSBSession *s, const char *remote);

// Download `remote`, resuming from byte `resume_from`. `max_bps` throttles the
// receive rate (0 = unlimited).
GSBResult gsb_download(GSBSession *s, const char *remote,
                       long long resume_from, long long max_bps,
                       gsb_write_cb write_cb, gsb_progress_cb progress_cb,
                       void *userdata);

// Upload to `remote` (created / truncated). `total` is the source size for
// progress; `max_bps` throttles the send rate (0 = unlimited).
GSBResult gsb_upload(GSBSession *s, const char *remote, long long total,
                     long long max_bps,
                     gsb_read_cb read_cb, gsb_progress_cb progress_cb,
                     void *userdata);

GSBResult gsb_mkdir(GSBSession *s, const char *path);
GSBResult gsb_remove(GSBSession *s, const char *path, int is_dir);

// Rename / move `from` to `to` across directories on one server. Fails if the server rejects it —
// notably across filesystems, which the caller must then handle by copying instead.
GSBResult gsb_rename(GSBSession *s, const char *from, const char *to);

// ---- metadata -------------------------------------------------------------

// Attributes of one remote item. `is_link` reports on the item ITSELF (lstat
// semantics), so a symlink is never silently reported as its target.
typedef struct GSBStat {
    int exists;
    int is_dir;
    int is_link;
    long long size;
    long long mtime;
    unsigned long perms;
    unsigned long uid;
    unsigned long gid;
} GSBStat;

// lstat: describes the item itself, never following a final symlink.
GSBResult gsb_lstat(GSBSession *s, const char *path, GSBStat *out);

// stat: follows symlinks. Used to decide whether a link resolves to a directory.
GSBResult gsb_stat(GSBSession *s, const char *path, GSBStat *out);

// Read a symlink's target into `buf` (NUL-terminated, truncated to `cap`).
GSBResult gsb_readlink(GSBSession *s, const char *path, char *buf, size_t cap);

// Canonicalise a path server-side.
GSBResult gsb_realpath(GSBSession *s, const char *path, char *buf, size_t cap);

// Change the permission bits of an existing item.
GSBResult gsb_setstat(GSBSession *s, const char *path, unsigned long perms);

// Filesystem capacity for the volume holding `path`.
typedef struct GSBSpace {
    long long total_bytes;
    long long free_bytes;      // available to THIS user (statvfs f_bavail)
} GSBSpace;

// Free/total space. Uses the statvfs@openssh.com extension, so a server without
// it returns GSB_ERR_SFTP and the caller should simply show nothing.
GSBResult gsb_statvfs(GSBSession *s, const char *path, GSBSpace *out);

#ifdef __cplusplus
}
#endif
#endif
