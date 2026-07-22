#ifndef SSH_BRIDGE_H
#define SSH_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

// A thin C shim over libssh2 for SFTP: connect, host-key hashing, password /
// ssh-agent auth, directory listing, and (resumable) file download/upload.
// It exists because the libssh2 surface is C-only and keeps thread-affinity
// simple — every operation opens its own session on the caller's dedicated
// thread and tears it down before returning, so a session never crosses
// threads. Blocking by design.

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
    GSB_ERR_VERIFY       = -16,  // bytes landed, but the remote size disagrees
    GSB_ERR_EXISTS       = -17,  // refusing to clobber an existing remote entry
};

typedef struct GSBResult {
    int code;               // one of the GSB_* codes
    long long value;        // file size for size/stat ops, else 0
    char fingerprint[80];   // hex SHA-256 of the server host key (always filled on connect)
    char message[256];      // human-readable detail
} GSBResult;

// Connection + auth parameters, shared by every operation.
//   password    "" / NULL to skip password auth
//   use_agent   nonzero to also try the running ssh-agent
//   expected_fp hex SHA-256 to REQUIRE (mismatch -> GSB_ERR_HOSTKEY_MISMATCH);
//               "" / NULL learns the key (trust-on-first-use) and returns it.
typedef struct GSBAuth {
    const char *host;
    int port;
    const char *username;
    const char *password;
    int use_agent;
    const char *expected_fp;
} GSBAuth;

// Write callback: receive `len` bytes; return `len` to continue, anything else
// aborts the download.
typedef long (*gsb_write_cb)(const char *buf, long len, void *userdata);

// Read callback (upload): fill up to `cap` bytes; return count, 0 for EOF,
// negative to abort.
typedef long (*gsb_read_cb)(char *buf, long cap, void *userdata);

// Progress callback: return 0 to continue, nonzero to abort.
typedef int (*gsb_progress_cb)(void *userdata, long long total, long long sofar);

// Directory-entry callback, once per child.
typedef void (*gsb_entry_cb)(void *userdata, const char *name, int is_dir,
                             long long size, long long mtime, unsigned long perms);

// Connect + authenticate only (the "Test Connection" button). Fills fingerprint.
GSBResult gsb_probe(const GSBAuth *auth);

// List a remote directory, invoking `cb` for each entry.
GSBResult gsb_list(const GSBAuth *auth, const char *path,
                   gsb_entry_cb cb, void *userdata);

// Size of a single remote file (fills result.value), or an error.
GSBResult gsb_size(const GSBAuth *auth, const char *remote);

// Download `remote`, resuming from byte `resume_from`. `max_bps` throttles the
// receive rate (0 = unlimited).
GSBResult gsb_download(const GSBAuth *auth, const char *remote,
                       long long resume_from, long long max_bps,
                       gsb_write_cb write_cb, gsb_progress_cb progress_cb,
                       void *userdata);

// Upload to `remote` (created / truncated). `total` is the source size for
// progress; `max_bps` throttles the send rate (0 = unlimited).
GSBResult gsb_upload(const GSBAuth *auth, const char *remote, long long total,
                     long long max_bps,
                     gsb_read_cb read_cb, gsb_progress_cb progress_cb,
                     void *userdata);

// ---- upload-destination preflight ----------------------------------------

// What a destination path actually is; `resolved` carries the realpath so a symlinked destination can be re-checked against the intended tree rather than followed blindly.
typedef struct GSBStat {
    int exists;
    int is_dir;
    int is_link;              // the path itself is a symlink (lstat)
    unsigned long perms;      // 0 when the server didn't report permissions
    long long size;
    long long mtime;
    char resolved[1024];      // realpath, "" if unavailable
} GSBStat;

// stat + lstat + realpath in ONE session. `exists == 0` with GSB_OK is a legitimate answer, not an error.
GSBResult gsb_stat(const GSBAuth *auth, const char *path, GSBStat *out);

// Free space on the filesystem holding `path`; `supported == 0` means the server lacks the statvfs@openssh.com extension, so warn rather than refuse.
typedef struct GSBSpace {
    int supported;
    long long free_bytes;
    long long total_bytes;
} GSBSpace;

GSBResult gsb_statvfs(const GSBAuth *auth, const char *path, GSBSpace *out);

// Upload to `temp_remote`, verify the landed size, rename onto `final_remote` — one session, so nothing can slip between the check and the rename. `overwrite == 0` refuses an existing target (GSB_ERR_EXISTS). Any failure removes the temporary.
GSBResult gsb_upload_atomic(const GSBAuth *auth,
                            const char *temp_remote, const char *final_remote,
                            long long total, long long max_bps, int overwrite,
                            gsb_read_cb read_cb, gsb_progress_cb progress_cb,
                            void *userdata);

GSBResult gsb_mkdir(const GSBAuth *auth, const char *path);
GSBResult gsb_remove(const GSBAuth *auth, const char *path, int is_dir);

// Rename / move `from` to `to` (same session; works across directories on the
// same server). Fails if the server rejects it (e.g. target exists).
GSBResult gsb_rename(const GSBAuth *auth, const char *from, const char *to);

#ifdef __cplusplus
}
#endif
#endif
