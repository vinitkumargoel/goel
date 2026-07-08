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

typedef size_t (*gcb_write)(const char *data, size_t size, void *userdata);
typedef int (*gcb_progress)(void *userdata, int64_t dltotal, int64_t dlnow);

typedef struct GCBResult {
    int code;
    int64_t content_length;
} GCBResult;

GCBResult gcb_download(const char *url, long long resume_from,
                       const char *userpwd, int require_tls,
                       long long max_recv_bps,
                       gcb_write write_cb, gcb_progress progress_cb,
                       void *userdata);

long long gcb_remote_size(const char *url, const char *userpwd, int require_tls, int *out_reachable);

int gcb_is_aborted(int code);
const char *gcb_error_message(int code);

// ---------------------------------------------------------------------------
// HTTP(S) ranged GET with interface-scoped egress (network aggregation)
// ---------------------------------------------------------------------------

typedef struct GCBHTTPResult {
    int code;                    // CURLcode
    int http_status;             // HTTP status, 0 if never got headers
    int64_t content_range_total; // Content-Range total, -1 unknown
    int64_t bytes_written;       // body bytes delivered to write_cb
    int range_total_mismatch;    // 1 if expected_total disagreed with Content-Range
} GCBHTTPResult;

// Perform one HTTP(S) GET with Range: bytes=start-end (inclusive).
//
// `ifname` — interface name for egress scoping. NULL/empty ⇒ no bind.
// Apple: IP_BOUND_IF / IPV6_BOUND_IF (fails closed if neither setsockopt works).
// Linux: SO_BINDTODEVICE.
//
// `expected_total` — when > 0, require Content-Range total to match and abort
// before writing body on mismatch/missing total (multi-path integrity).
//
// Redirects: manual, max 10; secrets stripped on host change / https→http /
// unparseable host (fail closed). Host parser handles userinfo and IPv6.
//
// `max_recv_bps` — leave 0 for multi-path (Swift RateLimiter owns aggregate).
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
                             long long expected_total,
                             gcb_write write_cb,
                             gcb_progress progress_cb,
                             void *userdata);

// Extract lowercase host from URL into `out`. Returns 1 on success, 0 on failure.
// Skips userinfo, handles [IPv6], ignores port. Exposed for unit tests.
int gcb_extract_host(const char *url, char *out, size_t out_sz);

#ifdef __cplusplus
}
#endif
#endif
