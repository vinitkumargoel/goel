#ifndef CURL_BRIDGE_H
#define CURL_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

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

typedef struct GCBHTTPResult {
    int code;
    int http_status;
    int64_t content_range_total; // -1 when unknown
    int64_t bytes_written;
    int range_total_mismatch;
    int range_ignored;           /* server answered a ranged GET with 200; aborted before any body write */
    char etag[256];
    char last_modified[128];
} GCBHTTPResult;

// `range_start < 0` streams the whole body; redirects are followed manually, capped at 10.
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

// Returns 1 on success; skips userinfo so `user@host` cannot spoof the host callers screen on.
int gcb_extract_host(const char *url, char *out, size_t out_sz);

#ifdef __cplusplus
}
#endif
#endif
