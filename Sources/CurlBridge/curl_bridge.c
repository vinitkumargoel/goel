#include "include/curl_bridge.h"

#include <curl/curl.h>
#include <ctype.h>
#include <net/if.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>

#if defined(__APPLE__)
#include <netinet/in.h>
#elif defined(__linux__)
#ifndef SO_BINDTODEVICE
#define SO_BINDTODEVICE 25
#endif
#endif

/* -------------------------------------------------------------------------- */
/* Shared FTP path                                                            */
/* -------------------------------------------------------------------------- */

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
    curl_easy_setopt(h, CURLOPT_LOW_SPEED_LIMIT, 1L);
    curl_easy_setopt(h, CURLOPT_LOW_SPEED_TIME, 60L);
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

long long gcb_remote_size(const char *url, const char *userpwd, int require_tls, int *out_reachable) {
    if (out_reachable) *out_reachable = 0;
    CURL *h = curl_easy_init();
    if (!h) return -1;
    gcb_common(h, url, userpwd, require_tls);
    curl_easy_setopt(h, CURLOPT_NOBODY, 1L);
    CURLcode rc = curl_easy_perform(h);
    if (out_reachable) *out_reachable = (rc == CURLE_OK) ? 1 : 0;
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

/* -------------------------------------------------------------------------- */
/* Host extraction (userinfo-safe, IPv6-aware) — used for redirect strip     */
/* -------------------------------------------------------------------------- */

int gcb_extract_host(const char *url, char *out, size_t out_sz) {
    if (!out || out_sz == 0) return 0;
    out[0] = '\0';
    if (!url || !url[0]) return 0;

    const char *p = strstr(url, "://");
    p = p ? p + 3 : url;

    /* Authority ends at / ? # */
    const char *auth_end = p;
    while (*auth_end && *auth_end != '/' && *auth_end != '?' && *auth_end != '#')
        auth_end++;

    /* Skip userinfo: last '@' within authority */
    const char *at = NULL;
    for (const char *q = p; q < auth_end; q++) {
        if (*q == '@') at = q;
    }
    if (at) p = at + 1;

    if (p >= auth_end) return 0;

    /* IPv6 literal: [2001:db8::1] */
    if (*p == '[') {
        p++;
        size_t i = 0;
        while (p < auth_end && *p != ']' && i + 1 < out_sz) {
            out[i++] = (char)tolower((unsigned char)*p++);
        }
        out[i] = '\0';
        return i > 0 ? 1 : 0;
    }

    /* Hostname or IPv4 — stop before port */
    size_t i = 0;
    while (p < auth_end && *p != ':' && i + 1 < out_sz) {
        out[i++] = (char)tolower((unsigned char)*p++);
    }
    out[i] = '\0';
    return i > 0 ? 1 : 0;
}

/* -------------------------------------------------------------------------- */
/* HTTP range + interface-scoped egress                                       */
/* -------------------------------------------------------------------------- */

struct gcb_http_ctx {
    gcb_write write_cb;
    gcb_progress progress_cb;
    void *userdata;
    int64_t bytes_written;
    int http_status;
    int64_t content_range_total;
    int64_t expected_total;
    int range_total_mismatch;
    int reject_body;
    char location[2048];
};

struct gcb_sockopt_ctx {
    char ifname[IF_NAMESIZE];
};

/* True interface egress — NOT source-IP bind. Fail closed on bind failure. */
static int gcb_sockopt_cb(void *clientp, curl_socket_t curlfd, curlsocktype purpose) {
    if (purpose != CURLSOCKTYPE_IPCXN) return CURL_SOCKOPT_OK;
    struct gcb_sockopt_ctx *s = (struct gcb_sockopt_ctx *)clientp;
    if (!s || s->ifname[0] == '\0') return CURL_SOCKOPT_OK;

#if defined(__APPLE__)
    unsigned int ifindex = if_nametoindex(s->ifname);
    if (ifindex == 0) return CURL_SOCKOPT_ERROR;
    /* Family-unknown: try both; at least one must succeed for the socket family. */
    int r4 = setsockopt(curlfd, IPPROTO_IP, IP_BOUND_IF, &ifindex, sizeof(ifindex));
#ifdef IPV6_BOUND_IF
    int r6 = setsockopt(curlfd, IPPROTO_IPV6, IPV6_BOUND_IF, &ifindex, sizeof(ifindex));
#else
    int r6 = -1;
#endif
    if (r4 != 0 && r6 != 0) return CURL_SOCKOPT_ERROR;
    return CURL_SOCKOPT_OK;
#elif defined(__linux__)
    if (setsockopt(curlfd, SOL_SOCKET, SO_BINDTODEVICE,
                   s->ifname, (socklen_t)strlen(s->ifname)) != 0) {
        return CURL_SOCKOPT_ERROR;
    }
    return CURL_SOCKOPT_OK;
#else
    (void)curlfd;
    return CURL_SOCKOPT_OK;
#endif
}

static size_t gcb_http_write_thunk(char *ptr, size_t size, size_t nmemb, void *ud) {
    struct gcb_http_ctx *ctx = (struct gcb_http_ctx *)ud;
    size_t n = size * nmemb;

    /* Require Content-Range total when caller supplied expected_total. */
    if (ctx->expected_total > 0 && ctx->http_status == 206 && !ctx->range_total_mismatch) {
        if (ctx->content_range_total < 0) {
            ctx->range_total_mismatch = 1;
            ctx->reject_body = 1;
        } else if (ctx->content_range_total != ctx->expected_total) {
            ctx->range_total_mismatch = 1;
            ctx->reject_body = 1;
        }
    }

    if (ctx->reject_body || ctx->range_total_mismatch) {
        return 0; /* abort — do not write mismatched body into the segment slot */
    }

    /* Drain non-206 bodies without writing (redirects, errors). */
    if (ctx->http_status != 0 && ctx->http_status != 206) {
        return n;
    }

    size_t wrote = ctx->write_cb(ptr, n, ctx->userdata);
    if (wrote == n) ctx->bytes_written += (int64_t)n;
    return wrote;
}

static int gcb_http_xfer_thunk(void *ud, curl_off_t dltotal, curl_off_t dlnow,
                               curl_off_t ultotal, curl_off_t ulnow) {
    (void)ultotal; (void)ulnow; (void)dltotal; (void)dlnow;
    struct gcb_http_ctx *ctx = (struct gcb_http_ctx *)ud;
    if (ctx->reject_body || ctx->range_total_mismatch) return 1;
    return ctx->progress_cb(ctx->userdata, (int64_t)dltotal, (int64_t)dlnow);
}

static void gcb_trim_inplace(char *s) {
    if (!s) return;
    size_t n = strlen(s);
    while (n > 0 && (s[n - 1] == '\r' || s[n - 1] == '\n' || s[n - 1] == ' ' || s[n - 1] == '\t'))
        s[--n] = '\0';
    size_t i = 0;
    while (s[i] == ' ' || s[i] == '\t') i++;
    if (i) memmove(s, s + i, strlen(s + i) + 1);
}

static size_t gcb_http_header_thunk(char *buffer, size_t size, size_t nitems, void *ud) {
    struct gcb_http_ctx *ctx = (struct gcb_http_ctx *)ud;
    size_t n = size * nitems;
    char line[2048];
    size_t copy = n < sizeof(line) - 1 ? n : sizeof(line) - 1;
    memcpy(line, buffer, copy);
    line[copy] = '\0';
    gcb_trim_inplace(line);
    if (line[0] == '\0') return n;

    if (strncmp(line, "HTTP/", 5) == 0) {
        const char *p = line;
        while (*p && *p != ' ') p++;
        while (*p == ' ') p++;
        ctx->http_status = atoi(p);
        ctx->content_range_total = -1;
        ctx->location[0] = '\0';
        ctx->range_total_mismatch = 0;
        ctx->reject_body = 0;
        return n;
    }
    if (strncasecmp(line, "Content-Range:", 14) == 0) {
        const char *slash = strrchr(line, '/');
        if (slash && slash[1] && slash[1] != '*') {
            long long total = atoll(slash + 1);
            if (total > 0) {
                ctx->content_range_total = (int64_t)total;
                if (ctx->expected_total > 0 && total != ctx->expected_total) {
                    ctx->range_total_mismatch = 1;
                    ctx->reject_body = 1;
                }
            }
        } else if (ctx->expected_total > 0) {
            /* Content-Range present but unusable — treat as mismatch for multi-path. */
            ctx->range_total_mismatch = 1;
            ctx->reject_body = 1;
        }
        return n;
    }
    if (strncasecmp(line, "Location:", 9) == 0) {
        const char *v = line + 9;
        while (*v == ' ' || *v == '\t') v++;
        snprintf(ctx->location, sizeof(ctx->location), "%s", v);
        return n;
    }
    return n;
}

static int gcb_is_https(const char *url) {
    return url && strncasecmp(url, "https://", 8) == 0;
}

static int gcb_resolve_location(const char *base, const char *loc, char *out, size_t out_sz) {
    if (!loc || !loc[0] || !out_sz) return 0;
    if (strstr(loc, "://") != NULL) {
        snprintf(out, out_sz, "%s", loc);
        return 1;
    }
    if (loc[0] == '/') {
        const char *scheme_end = strstr(base, "://");
        if (!scheme_end) return 0;
        const char *host_start = scheme_end + 3;
        const char *path = strchr(host_start, '/');
        size_t origin_len = path ? (size_t)(path - base) : strlen(base);
        if (origin_len + strlen(loc) + 1 > out_sz) return 0;
        memcpy(out, base, origin_len);
        out[origin_len] = '\0';
        strncat(out, loc, out_sz - origin_len - 1);
        return 1;
    }
    const char *slash = strrchr(base, '/');
    if (!slash) return 0;
    size_t dir_len = (size_t)(slash - base + 1);
    if (dir_len + strlen(loc) + 1 > out_sz) return 0;
    memcpy(out, base, dir_len);
    out[dir_len] = '\0';
    strncat(out, loc, out_sz - dir_len - 1);
    return 1;
}

static struct curl_slist *gcb_http_headers(const char *user_agent,
                                          const char *referer,
                                          const char *authorization,
                                          const char *extra_headers,
                                          const char *range_value,
                                          int strip_secrets) {
    struct curl_slist *list = NULL;
    char buf[4096];

    if (user_agent && user_agent[0]) {
        snprintf(buf, sizeof(buf), "User-Agent: %s", user_agent);
        list = curl_slist_append(list, buf);
    }
    if (range_value && range_value[0]) {
        snprintf(buf, sizeof(buf), "Range: %s", range_value);
        list = curl_slist_append(list, buf);
    }
    if (!strip_secrets) {
        if (referer && referer[0]) {
            snprintf(buf, sizeof(buf), "Referer: %s", referer);
            list = curl_slist_append(list, buf);
        }
        if (authorization && authorization[0]) {
            snprintf(buf, sizeof(buf), "Authorization: %s", authorization);
            list = curl_slist_append(list, buf);
        }
        if (extra_headers && extra_headers[0]) {
            const char *p = extra_headers;
            while (*p) {
                const char *nl = strchr(p, '\n');
                size_t len = nl ? (size_t)(nl - p) : strlen(p);
                while (len > 0 && (p[len - 1] == '\r' || p[len - 1] == ' ')) len--;
                if (len > 0 && len < sizeof(buf) - 1) {
                    memcpy(buf, p, len);
                    buf[len] = '\0';
                    if (strchr(buf, ':')) list = curl_slist_append(list, buf);
                }
                if (!nl) break;
                p = nl + 1;
            }
        }
    }
    list = curl_slist_append(list, "Accept-Encoding: identity");
    return list;
}

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
                             void *userdata) {
    GCBHTTPResult result = { -1, 0, -1, 0, 0 };
    if (!url || !write_cb || !progress_cb) return result;
    if (range_start < 0 || range_end < range_start) {
        result.code = (int)CURLE_BAD_FUNCTION_ARGUMENT;
        return result;
    }

    char current[2048];
    snprintf(current, sizeof(current), "%s", url);
    char origin_host[256];
    int origin_ok = gcb_extract_host(url, origin_host, sizeof(origin_host));
    int origin_https = gcb_is_https(url);

    char range_value[128];
    snprintf(range_value, sizeof(range_value), "bytes=%lld-%lld", range_start, range_end);

    struct gcb_sockopt_ctx sockctx;
    memset(&sockctx, 0, sizeof(sockctx));
    if (ifname && ifname[0]) {
        snprintf(sockctx.ifname, sizeof(sockctx.ifname), "%s", ifname);
    }

    long timeout = connect_timeout_sec > 0 ? connect_timeout_sec : 30;
    int64_t total_written = 0;

    for (int hop = 0; hop < 10; hop++) {
        CURL *h = curl_easy_init();
        if (!h) {
            result.code = (int)CURLE_FAILED_INIT;
            return result;
        }

        struct gcb_http_ctx ctx;
        memset(&ctx, 0, sizeof(ctx));
        ctx.write_cb = write_cb;
        ctx.progress_cb = progress_cb;
        ctx.userdata = userdata;
        ctx.content_range_total = -1;
        ctx.expected_total = expected_total;

        char hop_host[256];
        int hop_ok = gcb_extract_host(current, hop_host, sizeof(hop_host));
        /* Fail closed: unparseable host or origin ⇒ strip secrets. */
        int strip = 1;
        if (origin_ok && hop_ok) {
            strip = (strcasecmp(hop_host, origin_host) != 0)
                 || (origin_https && !gcb_is_https(current));
        }

        struct curl_slist *headers = gcb_http_headers(
            user_agent, referer, authorization, extra_headers, range_value, strip);

        curl_easy_setopt(h, CURLOPT_URL, current);
        curl_easy_setopt(h, CURLOPT_NOSIGNAL, 1L);
        curl_easy_setopt(h, CURLOPT_CONNECTTIMEOUT, timeout);
        curl_easy_setopt(h, CURLOPT_LOW_SPEED_LIMIT, 1L);
        curl_easy_setopt(h, CURLOPT_LOW_SPEED_TIME, 60L);
        curl_easy_setopt(h, CURLOPT_FOLLOWLOCATION, 0L);
        curl_easy_setopt(h, CURLOPT_PROTOCOLS, (long)(CURLPROTO_HTTP | CURLPROTO_HTTPS));
#ifdef CURL_HTTP_VERSION_2TLS
        curl_easy_setopt(h, CURLOPT_HTTP_VERSION, (long)CURL_HTTP_VERSION_2TLS);
#endif
        curl_easy_setopt(h, CURLOPT_HTTPHEADER, headers);
        curl_easy_setopt(h, CURLOPT_WRITEFUNCTION, gcb_http_write_thunk);
        curl_easy_setopt(h, CURLOPT_WRITEDATA, &ctx);
        curl_easy_setopt(h, CURLOPT_HEADERFUNCTION, gcb_http_header_thunk);
        curl_easy_setopt(h, CURLOPT_HEADERDATA, &ctx);
        curl_easy_setopt(h, CURLOPT_XFERINFOFUNCTION, gcb_http_xfer_thunk);
        curl_easy_setopt(h, CURLOPT_XFERINFODATA, &ctx);
        curl_easy_setopt(h, CURLOPT_NOPROGRESS, 0L);
        curl_easy_setopt(h, CURLOPT_SOCKOPTFUNCTION, gcb_sockopt_cb);
        curl_easy_setopt(h, CURLOPT_SOCKOPTDATA, &sockctx);
        curl_easy_setopt(h, CURLOPT_FRESH_CONNECT, 1L);
        curl_easy_setopt(h, CURLOPT_FORBID_REUSE, 1L);
        if (max_recv_bps > 0) {
            curl_easy_setopt(h, CURLOPT_MAX_RECV_SPEED_LARGE, (curl_off_t)max_recv_bps);
        }

        CURLcode rc = curl_easy_perform(h);

        long status = 0;
        curl_easy_getinfo(h, CURLINFO_RESPONSE_CODE, &status);
        if (ctx.http_status == 0 && status > 0) ctx.http_status = (int)status;

        /* Only credit body bytes from non-mismatch attempts. */
        if (!ctx.range_total_mismatch) total_written += ctx.bytes_written;
        result.code = (int)rc;
        result.http_status = ctx.http_status;
        result.content_range_total = ctx.content_range_total;
        result.bytes_written = total_written;
        result.range_total_mismatch = ctx.range_total_mismatch;

        if (ctx.range_total_mismatch) {
            /* Force a distinct failure surface for Swift. */
            if (rc == CURLE_OK || rc == CURLE_WRITE_ERROR || rc == CURLE_ABORTED_BY_CALLBACK) {
                result.code = (int)CURLE_WRITE_ERROR;
            }
        }

        char next_url[2048];
        int has_redirect = 0;
        if (rc == CURLE_OK && !ctx.range_total_mismatch
            && ctx.http_status >= 300 && ctx.http_status < 400 && ctx.location[0]) {
            has_redirect = gcb_resolve_location(current, ctx.location, next_url, sizeof(next_url));
        }

        curl_slist_free_all(headers);
        curl_easy_cleanup(h);

        if (rc == CURLE_ABORTED_BY_CALLBACK && !ctx.range_total_mismatch) return result;
        if (ctx.range_total_mismatch) return result;
        if (rc != CURLE_OK) return result;

        if (has_redirect) {
            snprintf(current, sizeof(current), "%s", next_url);
            continue;
        }
        return result;
    }

    result.code = (int)CURLE_TOO_MANY_REDIRECTS;
    return result;
}
