#ifndef TORRENT_BRIDGE_H
#define TORRENT_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void *GTSession;
typedef void *GTHandle;

typedef enum {
    GT_STATE_QUEUED       = 0,
    GT_STATE_CHECKING     = 1,
    GT_STATE_METADATA     = 2,
    GT_STATE_DOWNLOADING  = 3,
    GT_STATE_FINISHED     = 4,
    GT_STATE_SEEDING      = 5,
    GT_STATE_ERROR        = 6,
    GT_STATE_PAUSED       = 7
} GTState;

/// Bit flags OR'd into the `mode` argument, not an ordinary enum.
typedef enum {
    GT_ADD_DEFAULT       = 0,
    /// Fails closed if already in the session — libtorrent would hand back the LIVE handle and evict it.
    GT_ADD_METADATA_ONLY = 1,
    GT_ADD_DISABLE_PEX   = 2
} GTAddMode;

typedef struct {
    int32_t state;
    int32_t has_metadata;
    int32_t num_peers;
    int32_t num_seeds;
    int64_t total_bytes;
    int64_t downloaded_bytes;
    int64_t uploaded_bytes;
    double  download_rate;
    double  upload_rate;
    double  progress;
    char    name[1024];
    char    error[512];
} GTStatus;

/// `enc_policy`: 0 = disabled, 1 = enabled, 2 = forced.
GTSession gt_session_create(int enable_dht, int enable_lsd, int enable_utp, int enc_policy);
void      gt_session_destroy(GTSession session);

/// Bytes/sec; 0 = unlimited.
void gt_session_set_rate_limits(GTSession session, int download_bps, int upload_bps);

/// Without this libtorrent ignores the traffic profile and uses its own default. Values < 1 are ignored.
void gt_session_set_connections(GTSession session, int connections_limit);

void gt_session_apply_settings(GTSession session, int enable_dht, int enable_lsd,
                               int enable_utp, int enc_policy);

/// `proxy_type` is libtorrent's `proxy_type_t` (0 none, 2 SOCKS5, 4 HTTP); it always resolves names (no DNS leak).
void gt_session_set_proxy(GTSession session, int proxy_type, const char *host,
                          int port, int peer_connections);

/// Also drains the alert queue — nothing else consumes it and libtorrent drops alerts once full.
int gt_session_last_error(GTSession session, char *out, int cap);

GTHandle gt_add_magnet(GTSession session, const char *magnet_uri, const char *save_path,
                       int mode, char *err_out, int err_cap);

GTHandle gt_add_torrent_file(GTSession session, const char *file_path, const char *save_path,
                             int mode, char *err_out, int err_cap);

/// Replaced atomically (temp + rename) — on timeout/failure the previous blob survives intact.
int gt_save_resume_data(GTSession session, GTHandle handle, const char *path, int timeout_ms);

GTHandle gt_add_resume(GTSession session, const char *resume_path, const char *save_path,
                       int mode, char *err_out, int err_cap);

void gt_pause(GTHandle handle);
void gt_resume(GTHandle handle);
/// Frees `handle`.
void gt_remove(GTSession session, GTHandle handle, int delete_files);
/// Frees the wrapper WITHOUT removing the torrent from the session.
void gt_handle_free(GTHandle handle);

int gt_get_status(GTHandle handle, GTStatus *out);

typedef struct {
    char   address[64];
    char   client[128];
    double down_rate;
    double up_rate;
    double progress;
} GTPeer;

int gt_peers(GTHandle handle, GTPeer *out, int cap);

void gt_set_sequential(GTHandle handle, int sequential);

/// Bytes/sec; 0 = unlimited.
void gt_set_download_limit(GTHandle handle, int bytes_per_sec);

/// libtorrent has no session-wide PeX setting, so a live toggle must be applied handle by handle.
void gt_set_pex(GTHandle handle, int enable);

int  gt_file_count(GTHandle handle);
/// `name_out` is the path *relative to the save folder*, so same-named files in subfolders stay distinct.
int  gt_file_info(GTHandle handle, int index, char *name_out, int name_cap,
                  int64_t *size_out, int64_t *done_out, int *priority_out);
/// One pass: `gt_file_info`'s `done_out` recomputes the whole vector per call — O(n²) over the file list.
int  gt_file_progress(GTHandle handle, int64_t *out, int cap);
/// libtorrent priority: 0 = don't download … 7 = top.
void gt_set_file_priority(GTHandle handle, int index, int priority);

int gt_info_hash(GTHandle handle, char *out, int cap);

typedef enum {
    GT_TRACKER_INACTIVE = 0,
    GT_TRACKER_UPDATING = 1,
    GT_TRACKER_WORKING  = 2,
    GT_TRACKER_ERROR    = 3
} GTTrackerStatus;

typedef struct {
    char url[512];
    char message[256];
    int  tier;
    int  num_seeds;      /* -1 if unknown */
    int  num_leeches;    /* -1 if unknown */
    int  status;
    int  verified;
} GTTracker;

int gt_trackers(GTHandle handle, GTTracker *out, int cap);

int gt_piece_count(GTHandle handle);
int gt_pieces(GTHandle handle, uint8_t *out, int cap);

void gt_force_recheck(GTHandle handle);
void gt_force_reannounce(GTHandle handle);
/// Bytes/sec; 0 = unlimited.
void gt_set_upload_limit(GTHandle handle, int bytes_per_sec);

#ifdef __cplusplus
}
#endif

#endif
