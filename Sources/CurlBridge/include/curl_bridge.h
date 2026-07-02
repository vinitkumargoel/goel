#ifndef CURL_BRIDGE_H
#define CURL_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

// A thin C shim over the system libcurl for FTP/FTPS downloads. It exists
// because `curl_easy_setopt` is variadic (uncallable from Swift) and keeps the
// whole libcurl surface out of the Swift target. Blocking by design — the
// Swift engine runs each transfer on its own thread.

#ifdef __cplusplus
extern "C" {
#endif

// Write callback: receive `size` bytes; return `size` to continue, anything
// else aborts the transfer with a write error.
typedef size_t (*gcb_write)(const char *data, size_t size, void *userdata);

// Progress callback: return 0 to continue, nonzero to abort (maps to
// CURLE_ABORTED_BY_CALLBACK — the engine's pause path).
typedef int (*gcb_progress)(void *userdata, int64_t dltotal, int64_t dlnow);

typedef struct GCBResult {
    int code;                 // CURLcode (0 = OK)
    int64_t content_length;   // bytes the transfer had left at start, -1 unknown
} GCBResult;

// Perform one (resumable) download. `resume_from` issues REST; `userpwd` is
// "user:password" or NULL; `max_recv_bps` caps throughput (0 = unlimited).
// `require_tls` nonzero makes TLS mandatory (the transfer FAILS if the
// control/data channels can't be protected — for credentials that must never
// travel cleartext); zero attempts an opportunistic AUTH TLS upgrade.
GCBResult gcb_download(const char *url, long long resume_from,
                       const char *userpwd, int require_tls,
                       long long max_recv_bps,
                       gcb_write write_cb, gcb_progress progress_cb,
                       void *userdata);

// The remote file's size via a body-less request, or -1 when unavailable.
long long gcb_remote_size(const char *url, const char *userpwd, int require_tls);

int gcb_is_aborted(int code);
const char *gcb_error_message(int code);

#ifdef __cplusplus
}
#endif
#endif
