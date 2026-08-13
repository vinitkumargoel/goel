#ifndef SSH_BRIDGE_H
#define SSH_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

// THREAD AFFINITY: `LIBSSH2_SESSION` is not thread-safe — each session is pinned to one thread.

#ifdef __cplusplus
extern "C" {
#endif

enum {
    GSB_OK               =  0,
    GSB_ERR_INIT         = -1,
    GSB_ERR_RESOLVE      = -2,
    GSB_ERR_CONNECT      = -3,
    GSB_ERR_HANDSHAKE    = -4,
    GSB_ERR_HOSTKEY      = -5,
    GSB_ERR_HOSTKEY_MISMATCH = -6,
    GSB_ERR_AUTH         = -7,
    GSB_ERR_SFTP         = -8,
    GSB_ERR_OPEN         = -9,
    GSB_ERR_IO           = -10,
    GSB_ERR_ABORTED      = -11,
    GSB_ERR_MKDIR        = -12,
    GSB_ERR_REMOVE       = -13,
    GSB_ERR_STAT         = -14,
    GSB_ERR_RENAME       = -15,
};

typedef struct GSBResult {
    int code;
    long long value;
    char fingerprint[80];
    char message[256];
} GSBResult;

// expected_fp: hex SHA-256 to REQUIRE (else GSB_ERR_HOSTKEY_MISMATCH); "" means TOFU, so never pass "" blindly.
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

typedef struct GSBSession GSBSession;

// Return exactly `len` to continue; anything else aborts the download.
typedef long (*gsb_write_cb)(const char *buf, long len, void *userdata);

// Return the count filled, 0 for EOF, negative to abort.
typedef long (*gsb_read_cb)(char *buf, long cap, void *userdata);

// Return 0 to continue, nonzero to abort.
typedef int (*gsb_progress_cb)(void *userdata, long long total, long long sofar);

// is_link: the entry ITSELF is a symlink; is_dir: whether it RESOLVES to a directory.
typedef void (*gsb_entry_cb)(void *userdata, const char *name, int is_dir,
                             long long size, long long mtime, unsigned long perms,
                             int is_link, const char *link_target,
                             unsigned long uid, unsigned long gid);

// `*r` is filled on failure, including `r->fingerprint` whenever the key was read.
GSBSession *gsb_session_open(const GSBAuth *auth, GSBResult *r);

void gsb_session_close(GSBSession *s);

// Storage belongs to the session — do not free.
const char *gsb_session_fingerprint(const GSBSession *s);

// LOCAL check, no round trip: nonzero only means "not known to be dead".
int gsb_session_alive(GSBSession *s);

GSBResult gsb_probe(const GSBAuth *auth);

// NO credential is ever offered here: the fingerprint is approved BEFORE any auth.
GSBResult gsb_hostkey(const GSBAuth *auth);

GSBResult gsb_list(GSBSession *s, const char *path,
                   gsb_entry_cb cb, void *userdata);

GSBResult gsb_size(GSBSession *s, const char *remote);

// `max_bps` of 0 means unlimited, not stalled.
GSBResult gsb_download(GSBSession *s, const char *remote,
                       long long resume_from, long long max_bps,
                       gsb_write_cb write_cb, gsb_progress_cb progress_cb,
                       void *userdata);

// `resume_from` > 0 appends after that offset instead of truncating; the read
// callback must already be positioned there. Progress reports absolute offsets.
GSBResult gsb_upload(GSBSession *s, const char *remote, long long total,
                     long long resume_from, long long max_bps,
                     gsb_read_cb read_cb, gsb_progress_cb progress_cb,
                     void *userdata);

GSBResult gsb_mkdir(GSBSession *s, const char *path);
GSBResult gsb_remove(GSBSession *s, const char *path, int is_dir);

// Fails across filesystems; the caller must fall back to copying.
GSBResult gsb_rename(GSBSession *s, const char *from, const char *to);

// `is_link` reports on the item ITSELF (lstat semantics): a symlink is never reported as its target.
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

GSBResult gsb_lstat(GSBSession *s, const char *path, GSBStat *out);

GSBResult gsb_stat(GSBSession *s, const char *path, GSBStat *out);

GSBResult gsb_readlink(GSBSession *s, const char *path, char *buf, size_t cap);

GSBResult gsb_realpath(GSBSession *s, const char *path, char *buf, size_t cap);

GSBResult gsb_setstat(GSBSession *s, const char *path, unsigned long perms);

typedef struct GSBSpace {
    long long total_bytes;
    long long free_bytes;      // available to THIS user (statvfs f_bavail)
} GSBSpace;

// statvfs@openssh.com extension: a server without it returns GSB_ERR_SFTP, which is not an error.
GSBResult gsb_statvfs(GSBSession *s, const char *path, GSBSpace *out);

#ifdef __cplusplus
}
#endif
#endif
