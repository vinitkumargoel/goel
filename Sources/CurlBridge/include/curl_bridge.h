#ifndef CURL_BRIDGE_H
#define CURL_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

// Thin C shim over system libcurl. `curl_easy_setopt` is variadic (uncallable
// from Swift). Blocking by design — Swift engines run each transfer on a
// dedicated thread.
//
// Originally FTP/FTPS only; also exposes HTTP(S) ranged GET with *true*
// interface egress scoping (IP_BOUND_IF on Apple, SO_BINDTODEVICE on Linux)
// via CURLOPT_SOCKOPTFUNCTION — plain CURLOPT_INTERFACE source-IP bind is NOT
// sufficient for multi-WAN on macOS.

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

// Perform one (resumable) FTP download. `resume_from` issues REST; `userpwd` is
// "user:password" or NULL; `max_recv_bps` caps throughput (0 = unlimited).
// `require_tls` nonzero makes TLS mandatory.
GCBResult gcb_download(const char *url, long long resume_from,
                       const char *userpwd, int require_tls,
                       long long max_recv_bps,
                       gcb_write write_cb, gcb_progress progress_cb,
                       void *userdata);

// The remote FTP file's size via a body-less request, or -1 when unavailable.
long long gcb_remote_size(const char *url, const char *userpwd, int require_tls, int *out_reachable);

int gcb_is_aborted(int code);
const char *gcb_error_message(int code);

// ---------------------------------------------------------------------------
// HTTP(S) ranged GET with interface-scoped egress (network aggregation)
// ---------------------------------------------------------------------------

// Result of one ranged HTTP attempt. `code` is CURLcode; when 0, inspect
// `http_status`. `content_range_total` is the `/N` suffix of Content-Range, or
// -1 when absent. `bytes_written` is how many body bytes the write callback
// accepted (may be short if aborted).
typedef struct GCBHTTPResult {
    int code;                    // CURLcode
    int http_status;             // HTTP status, 0 if never got headers
    int64_t content_range_total; // Content-Range total, -1 unknown
    int64_t bytes_written;       // body bytes delivered to write_cb
} GCBHTTPResult;

// Perform one HTTP(S) GET with Range: bytes=start-end (inclusive).
//
// `ifname` — BSD/Linux interface name for egress scoping (e.g. "en0"). NULL or
// empty ⇒ no interface bind (default route). On Apple this uses IP_BOUND_IF /
// IPV6_BOUND_IF; on Linux SO_BINDTODEVICE. Do NOT pass an IP address.
//
// `extra_headers` — optional CRLF-separated "Name: value" lines (no trailing
// blank line required), or NULL.
//
// `connect_timeout_sec` — connect timeout; 0 uses 30s default.
//
// Redirects are followed manually (max 10) with cross-host stripping of
// Authorization / Cookie / Referer / non-safe headers (mirrors RedirectSanitizer).
//
// `max_recv_bps` is always treated as 0 for multi-path callers (aggregate
// pacing lives in Swift). Passing >0 still works for single-stream use.
//
// HTTP/3 is disabled so interface pins are not defeated by QUIC migration.
GCBHTTPResult gcb_http_range(const char *url,
                             long long range_start,
                             long long range_end,
                             const char *ifname,
                             const char *user_agent,
                             const char *referer,
                             const char *authorization,
                             const char *extra_headers,
                             long connect_timeout_sec,
                             long long max_recv_bps,
                             gcb_write write_cb,
                             gcb_progress progress_cb,
                             void *userdata);

#ifdef __cplusplus
}
#endif
#endif
