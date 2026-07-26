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

/// How a torrent is added. Bit flags OR'd together into the `mode` argument of
/// `gt_add_magnet` / `gt_add_torrent_file` / `gt_add_resume`.
typedef enum {
    GT_ADD_DEFAULT       = 0,
    /// A metadata-only probe for the add-confirmation preview. Fails closed on
    /// a torrent that is already in the session (libtorrent would otherwise
    /// hand back the LIVE handle, and removing the probe would evict the user's
    /// running download), and requests no payload the user hasn't agreed to.
    GT_ADD_METADATA_ONLY = 1,
    /// Add with Peer Exchange disabled for this torrent. libtorrent has no
    /// session-wide PeX switch — it is a per-torrent flag.
    GT_ADD_DISABLE_PEX   = 2
} GTAddMode;

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

/// Set the session-wide peer connection ceiling (libtorrent `connections_limit`).
/// libtorrent otherwise runs at its built-in default regardless of the active
/// traffic profile; wiring the profile's `maxConnections` here lets a well-seeded
/// torrent pull from more peers on the High profile. Values < 1 are ignored.
void gt_session_set_connections(GTSession session, int connections_limit);

/// Apply the settings that libtorrent accepts on a *running* session (DHT / LSD
/// / uTP / encryption), so a Settings change takes effect immediately instead of
/// waiting for the next launch. `enc_policy` matches `gt_session_create`.
void gt_session_apply_settings(GTSession session, int enable_dht, int enable_lsd,
                               int enable_utp, int enc_policy);

/// Route the torrent swarm through a proxy. `proxy_type` follows libtorrent's
/// `settings_pack::proxy_type_t` (0 = none, 2 = SOCKS5, 4 = HTTP). Hostnames are
/// always resolved by the proxy (no DNS leak) and tracker announces always
/// follow it; `peer_connections` decides whether peer connections do too — pass
/// 0 for an HTTP proxy, which cannot carry them.
void gt_session_set_proxy(GTSession session, int proxy_type, const char *host,
                          int port, int peer_connections);

/// Drain the session's alert queue (nothing else consumes it, and libtorrent
/// drops alerts once it fills), then copy the last session-level failure it
/// reported — currently a failed listen — into `out` and clear it, so the caller
/// surfaces it once. Returns 1 when a message was written, 0 when there is
/// nothing to report.
int gt_session_last_error(GTSession session, char *out, int cap);

/* --- Adding torrents ----------------------------------------------------- */

/// Add a magnet URI with the given `GTAddMode` bits. Returns a handle, or NULL
/// (writing a message to err_out).
GTHandle gt_add_magnet(GTSession session, const char *magnet_uri, const char *save_path,
                       int mode, char *err_out, int err_cap);

/// Add a `.torrent` file by path. Returns a handle, or NULL (err_out set).
GTHandle gt_add_torrent_file(GTSession session, const char *file_path, const char *save_path,
                             int mode, char *err_out, int err_cap);

/* --- Fast resume ---------------------------------------------------------- */

/// Write libtorrent fast-resume data for `handle` to `path`, replacing it
/// atomically (temp file + rename). Blocks up to `timeout_ms` for the session to
/// produce the blob. Returns 1 on success, 0 on timeout/failure — in which case
/// any previously saved blob is left untouched.
int gt_save_resume_data(GTSession session, GTHandle handle, const char *path, int timeout_ms);

/// Re-add a torrent from previously saved resume data, so its lifetime upload
/// total survives a relaunch and its pieces aren't re-hashed. `save_path` is
/// forced onto the restored parameters — the app's folder stays authoritative.
/// Returns a handle, or NULL (err_out set) when there is no usable blob.
GTHandle gt_add_resume(GTSession session, const char *resume_path, const char *save_path,
                       int mode, char *err_out, int err_cap);

/* --- Per-torrent control ------------------------------------------------- */

void gt_pause(GTHandle handle);
void gt_resume(GTHandle handle);
/// Remove from the session, optionally deleting downloaded files. Frees handle.
void gt_remove(GTSession session, GTHandle handle, int delete_files);
/// Free the wrapper without removing the torrent (used on engine teardown).
void gt_handle_free(GTHandle handle);

/// Fill `out` with a status snapshot. Returns 1 on success, 0 if invalid.
int gt_get_status(GTHandle handle, GTStatus *out);

/* --- Peers ---------------------------------------------------------------- */

/// A snapshot of one connected peer, filled by `gt_peers`.
typedef struct {
    char   address[64];   /* "ip:port" */
    char   client[128];   /* remote client name, may be empty */
    double down_rate;     /* payload bytes/sec */
    double up_rate;       /* payload bytes/sec */
    double progress;      /* remote peer's completeness, 0..1 */
} GTPeer;

/// Fill up to `cap` connected peers into `out`. Returns the number written.
int gt_peers(GTHandle handle, GTPeer *out, int cap);

/// Toggle sequential (in-order) piece download for streaming/preview.
void gt_set_sequential(GTHandle handle, int sequential);

/// Per-torrent download rate cap in bytes/sec (0 = unlimited).
void gt_set_download_limit(GTHandle handle, int bytes_per_sec);

/// Toggle Peer Exchange for one torrent. libtorrent has no session-wide PeX
/// setting, so a live toggle has to be applied handle by handle.
void gt_set_pex(GTHandle handle, int enable);

/* --- Per-file selection (multi-file torrents) ---------------------------- */

int  gt_file_count(GTHandle handle);
/// Fill name/size/done/priority for file `index`. `name_out` receives the file's
/// path *relative to the save folder*, so files with the same name in different
/// subfolders stay distinguishable. Returns 1 ok, 0 otherwise.
int  gt_file_info(GTHandle handle, int index, char *name_out, int name_cap,
                  int64_t *size_out, int64_t *done_out, int *priority_out);
/// Fill `out[i]` with file `i`'s completed byte count, for up to `cap` files, in
/// one pass. Returns the number written. `gt_file_info`'s `done_out` recomputes
/// the whole vector per call, which is O(n²) over a torrent's file list.
int  gt_file_progress(GTHandle handle, int64_t *out, int cap);
/// Set libtorrent file priority (0 = don't download … 7 = top).
void gt_set_file_priority(GTHandle handle, int index, int priority);

/* --- Identity, trackers, pieces, maintenance ----------------------------- */

/// Write the torrent's v1 info-hash (40-char hex) into `out`. Unlike parsing it
/// from a magnet link, this works for `.torrent` files too. Returns 1 ok, 0 if
/// the hash isn't known yet (pre-metadata) or the handle is invalid.
int gt_info_hash(GTHandle handle, char *out, int cap);

/// Tracker status flags (see `GTTracker.status`).
typedef enum {
    GT_TRACKER_INACTIVE = 0,  /* not yet contacted */
    GT_TRACKER_UPDATING = 1,  /* announce in flight */
    GT_TRACKER_WORKING  = 2,  /* announced/scraped successfully */
    GT_TRACKER_ERROR    = 3   /* last announce failed */
} GTTrackerStatus;

/// A snapshot of one tracker, filled by `gt_trackers`.
typedef struct {
    char url[512];
    char message[256];   /* last error / status message, may be empty */
    int  tier;
    int  num_seeds;      /* scrape "complete", -1 if unknown */
    int  num_leeches;    /* scrape "incomplete", -1 if unknown */
    int  status;         /* GTTrackerStatus */
    int  verified;       /* 1 once the tracker has been reached */
} GTTracker;

/// Fill up to `cap` trackers into `out`. Returns the number written.
int gt_trackers(GTHandle handle, GTTracker *out, int cap);

/// Number of pieces in the torrent (0 before metadata is known).
int gt_piece_count(GTHandle handle);
/// Fill `out[i]` = 1 if piece `i` is downloaded, else 0, for up to `cap` pieces.
/// Returns the number of piece bits written.
int gt_pieces(GTHandle handle, uint8_t *out, int cap);

/// Re-verify the on-disk data against the torrent's piece hashes.
void gt_force_recheck(GTHandle handle);
/// Force an immediate re-announce to all trackers.
void gt_force_reannounce(GTHandle handle);
/// Per-torrent upload rate cap in bytes/sec (0 = unlimited).
void gt_set_upload_limit(GTHandle handle, int bytes_per_sec);

#ifdef __cplusplus
}
#endif

#endif /* TORRENT_BRIDGE_H */
