#include "include/curl_bridge.h"
#include <curl/curl.h>

struct gcb_ctx {
    gcb_write write_cb;
    gcb_progress progress_cb;
    void *userdata;
};

static size_t gcb_write_thunk(char *ptr, size_t size, size_t nmemb, void *ud) {
    struct gcb_ctx *ctx = ud;
    return ctx->write_cb(ptr, size * nmemb, ctx->userdata);
}

static int gcb_xfer_thunk(void *ud, curl_off_t dltotal, curl_off_t dlnow,
                          curl_off_t ultotal, curl_off_t ulnow) {
    (void)ultotal; (void)ulnow;
    struct gcb_ctx *ctx = ud;
    return ctx->progress_cb(ctx->userdata, (int64_t)dltotal, (int64_t)dlnow);
}

static void gcb_common(CURL *h, const char *url, const char *userpwd,
                       int require_tls) {
    curl_easy_setopt(h, CURLOPT_URL, url);
    curl_easy_setopt(h, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(h, CURLOPT_CONNECTTIMEOUT, 30L);
    // Stall detection: under 1 B/s for 60 s counts as dead.
    curl_easy_setopt(h, CURLOPT_LOW_SPEED_LIMIT, 1L);
    curl_easy_setopt(h, CURLOPT_LOW_SPEED_TIME, 60L);
    // ftps:// is implicit TLS. For ftp://: CURLUSESSL_ALL makes the AUTH TLS
    // upgrade MANDATORY (transfer fails instead of downgrading) — required
    // whenever the credentials must never travel cleartext; CURLUSESSL_TRY
    // upgrades opportunistically and falls back to plain FTP.
    curl_easy_setopt(h, CURLOPT_USE_SSL,
                     require_tls ? (long)CURLUSESSL_ALL : (long)CURLUSESSL_TRY);
    curl_easy_setopt(h, CURLOPT_FTP_USE_EPSV, 1L);
    if (userpwd && userpwd[0]) {
        curl_easy_setopt(h, CURLOPT_USERPWD, userpwd);
    }
}

GCBResult gcb_download(const char *url, long long resume_from,
                       const char *userpwd, int require_tls,
                       long long max_recv_bps,
                       gcb_write write_cb, gcb_progress progress_cb,
                       void *userdata) {
    GCBResult result = { -1, -1 };
    CURL *h = curl_easy_init();
    if (!h) return result;

    struct gcb_ctx ctx = { write_cb, progress_cb, userdata };
    gcb_common(h, url, userpwd, require_tls);
    curl_easy_setopt(h, CURLOPT_WRITEFUNCTION, gcb_write_thunk);
    curl_easy_setopt(h, CURLOPT_WRITEDATA, &ctx);
    curl_easy_setopt(h, CURLOPT_XFERINFOFUNCTION, gcb_xfer_thunk);
    curl_easy_setopt(h, CURLOPT_XFERINFODATA, &ctx);
    curl_easy_setopt(h, CURLOPT_NOPROGRESS, 0L);
    if (resume_from > 0) {
        curl_easy_setopt(h, CURLOPT_RESUME_FROM_LARGE, (curl_off_t)resume_from);
    }
    if (max_recv_bps > 0) {
        curl_easy_setopt(h, CURLOPT_MAX_RECV_SPEED_LARGE, (curl_off_t)max_recv_bps);
    }

    CURLcode rc = curl_easy_perform(h);
    curl_off_t length = -1;
    curl_easy_getinfo(h, CURLINFO_CONTENT_LENGTH_DOWNLOAD_T, &length);
    result.code = (int)rc;
    result.content_length = (int64_t)length;
    curl_easy_cleanup(h);
    return result;
}

long long gcb_remote_size(const char *url, const char *userpwd, int require_tls) {
    CURL *h = curl_easy_init();
    if (!h) return -1;
    gcb_common(h, url, userpwd, require_tls);
    curl_easy_setopt(h, CURLOPT_NOBODY, 1L);
    CURLcode rc = curl_easy_perform(h);
    curl_off_t length = -1;
    if (rc == CURLE_OK) {
        curl_easy_getinfo(h, CURLINFO_CONTENT_LENGTH_DOWNLOAD_T, &length);
    }
    curl_easy_cleanup(h);
    return (long long)length;
}

int gcb_is_aborted(int code) {
    return code == (int)CURLE_ABORTED_BY_CALLBACK;
}

const char *gcb_error_message(int code) {
    return curl_easy_strerror((CURLcode)code);
}
