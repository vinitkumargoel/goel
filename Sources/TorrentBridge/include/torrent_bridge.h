#ifndef TORRENT_BRIDGE_H
#define TORRENT_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handles across the C boundary. A `GTSession` owns the libtorrent
/// session; a `GTHandle` wraps one torrent_handle (heap-allocated copy).
typedef void *GTSession;
typedef void *GTHandle;

/// Torrent lifecycle states, mapped to `DownloadStatus` on the Swift side.
typedef enum {
    GT_STATE_QUEUED       = 0,
    GT_STATE_CHECKING     = 1,
    GT_STATE_METADATA     = 2,  /* downloading_metadata (magnet) */
    GT_STATE_DOWNLOADING  = 3,
    GT_STATE_FINISHED     = 4,
    GT_STATE_SEEDING      = 5,
    GT_STATE_ERROR        = 6,
    GT_STATE_PAUSED       = 7
} GTState;

/// A snapshot of a torrent's progress, filled by `gt_get_status`.
typedef struct {
    int32_t state;
    int32_t has_metadata;
    int32_t num_peers;
    int32_t num_seeds;
    int64_t total_bytes;
    int64_t downloaded_bytes;
    int64_t uploaded_bytes;
    double  download_rate;   /* bytes/sec */
    double  upload_rate;     /* bytes/sec */
    double  progress;        /* 0..1 */
    char    name[1024];
    char    error[512];
} GTStatus;

/* --- Session lifecycle --------------------------------------------------- */

/// Create a session. `enc_policy`: 0 = disabled, 1 = enabled, 2 = forced.
GTSession gt_session_create(int enable_dht, int enable_lsd, int enable_utp, int enc_policy);
void      gt_session_destroy(GTSession session);

/// Apply global rate limits in bytes/sec (0 = unlimited).
void gt_session_set_rate_limits(GTSession session, int download_bps, int upload_bps);

/* --- Adding torrents ----------------------------------------------------- */

/// Add a magnet URI. Returns a handle, or NULL (writing a message to err_out).
GTHandle gt_add_magnet(GTSession session, const char *magnet_uri, const char *save_path,
                       char *err_out, int err_cap);

/// Add a `.torrent` file by path. Returns a handle, or NULL (err_out set).
GTHandle gt_add_torrent_file(GTSession session, const char *file_path, const char *save_path,
                             char *err_out, int err_cap);

/* --- Per-torrent control ------------------------------------------------- */

void gt_pause(GTHandle handle);
void gt_resume(GTHandle handle);
/// Remove from the session, optionally deleting downloaded files. Frees handle.
void gt_remove(GTSession session, GTHandle handle, int delete_files);
/// Free the wrapper without removing the torrent (used on engine teardown).
void gt_handle_free(GTHandle handle);

/// Fill `out` with a status snapshot. Returns 1 on success, 0 if invalid.
int gt_get_status(GTHandle handle, GTStatus *out);

/* --- Per-file selection (multi-file torrents) ---------------------------- */

int  gt_file_count(GTHandle handle);
/// Fill name/size/done/priority for file `index`. Returns 1 ok, 0 otherwise.
int  gt_file_info(GTHandle handle, int index, char *name_out, int name_cap,
                  int64_t *size_out, int64_t *done_out, int *priority_out);
/// Set libtorrent file priority (0 = don't download … 7 = top).
void gt_set_file_priority(GTHandle handle, int index, int priority);

#ifdef __cplusplus
}
#endif

#endif /* TORRENT_BRIDGE_H */
