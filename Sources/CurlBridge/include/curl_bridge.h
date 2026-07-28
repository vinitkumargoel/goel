#ifndef CURL_BRIDGE_H
#define CURL_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

// Thin C shim over libcurl (`curl_easy_setopt` is variadic, so uncallable from Swift).
// Blocking by design. Adds ranged GET with true interface egress scoping via SOCKOPTFUNCTION.

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

// HTTP(S) ranged GET with interface-scoped egress (network aggregation).

typedef struct GCBHTTPResult {
    int code;                    // CURLcode
    int http_status;             // HTTP status, 0 if never got headers
    int64_t content_range_total; // Content-Range total, -1 unknown
    int64_t bytes_written;       // body bytes delivered to write_cb
    int range_total_mismatch;    // 1 if expected_total disagreed with Content-Range
    int range_ignored;           /* 1: ranged request answered with a final 200 —
                                    server ignored Range; aborted before body write */
    char etag[256];              /* ETag of the final response, "" if none */
    char last_modified[128];     /* Last-Modified of the final response, "" if none */
} GCBHTTPResult;

// One HTTP(S) GET with Range: bytes=start-end. `range_start < 0` streams the whole body;
// `ifname` binds egress; `expected_total` verifies Content-Range; redirects manual, max 10.
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
