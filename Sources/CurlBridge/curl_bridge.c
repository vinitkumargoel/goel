#include "include/curl_bridge.h"

#include <curl/curl.h>
#include <ctype.h>
#include <net/if.h>
#include <pthread.h>
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

/* Implicit init is thread-safe only from 7.84; concurrent segment threads would race TLS backend setup. */
static pthread_once_t gcb_init_once = PTHREAD_ONCE_INIT;
static void gcb_global_init(void) { curl_global_init(CURL_GLOBAL_DEFAULT); }
static void gcb_ensure_init(void) { pthread_once(&gcb_init_once, gcb_global_init); }

static void gcb_restrict_protocols(CURL *h, const char *list, long mask) {
#if LIBCURL_VERSION_NUM >= 0x075500
    (void)mask;
    curl_easy_setopt(h, CURLOPT_PROTOCOLS_STR, list);
    curl_easy_setopt(h, CURLOPT_REDIR_PROTOCOLS_STR, list);
#else
    (void)list;
    curl_easy_setopt(h, CURLOPT_PROTOCOLS, mask);
    curl_easy_setopt(h, CURLOPT_REDIR_PROTOCOLS, mask);
#endif
}

static void gcb_common(CURL *h, const char *url, const char *userpwd,
                       int require_tls) {
    curl_easy_setopt(h, CURLOPT_URL, url);
    /* Routing by kind is not enough: file://, dict:// or smb:// must never reach an FTP handle. */
    gcb_restrict_protocols(h, "ftp,ftps", (long)(CURLPROTO_FTP | CURLPROTO_FTPS));
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
    gcb_ensure_init();
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
    gcb_ensure_init();
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

int gcb_extract_host(const char *url, char *out, size_t out_sz) {
    if (!out || out_sz == 0) return 0;
    out[0] = '\0';
    if (!url || !url[0]) return 0;

    const char *p = strstr(url, "://");
    p = p ? p + 3 : url;

    const char *auth_end = p;
    while (*auth_end && *auth_end != '/' && *auth_end != '?' && *auth_end != '#')
        auth_end++;

    /* Skip userinfo at the LAST '@' in the authority — the first would let a URL spoof the host. */
    const char *at = NULL;
    for (const char *q = p; q < auth_end; q++) {
        if (*q == '@') at = q;
    }
    if (at) p = at + 1;

    if (p >= auth_end) return 0;

    if (*p == '[') {
        p++;
        size_t i = 0;
        while (p < auth_end && *p != ']' && i + 1 < out_sz) {
            out[i++] = (char)tolower((unsigned char)*p++);
        }
        out[i] = '\0';
        return i > 0 ? 1 : 0;
    }

    size_t i = 0;
    while (p < auth_end && *p != ':' && i + 1 < out_sz) {
        out[i++] = (char)tolower((unsigned char)*p++);
    }
    out[i] = '\0';
    return i > 0 ? 1 : 0;
}

struct gcb_http_ctx {
    gcb_write write_cb;
    gcb_progress progress_cb;
    void *userdata;
    int64_t bytes_written;
    int http_status;
    int64_t content_range_total;
    int64_t content_range_start;
    int64_t content_range_end;
    int64_t expected_total;
    int range_total_mismatch;
    int reject_body;
    /* 1 when no Range header was sent, so 200 (not 206) is the success status. */
    int unranged;
    int range_ignored;
    /* The 206 does not start where we asked: writing it at our offset would corrupt the file. */
    int range_mismatch;
    int64_t range_start;
    /* Ranged only: the most bytes this hop may write; an overshooting 206 must not spill into the next segment. */
    int64_t want;
    int clamped;
    char etag[256];
    char last_modified[128];
    /* Heap, unbounded: presigned Location URLs routinely exceed 2 KB and a clipped signature 403s. */
    char *location;
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

    /* 200 to a ranged request = Range ignored; writing it would corrupt the segment slot. */
    if (!ctx->unranged && ctx->http_status == 200) {
        ctx->range_ignored = 1;
        return 0;
    }

    /* Returning n drains non-success bodies (redirects, errors) without writing them. */
    int ok_status = ctx->unranged ? 200 : 206;
    if (ctx->http_status != 0 && ctx->http_status != ok_status) {
        return n;
    }

    size_t allowed = n;
    if (!ctx->unranged) {
        if (ctx->content_range_start != ctx->range_start) {
            ctx->range_mismatch = 1;
            return 0;
        }
        int64_t remaining = ctx->want - ctx->bytes_written;
        if (remaining <= 0) { ctx->clamped = 1; return 0; }
        if ((int64_t)n > remaining) allowed = (size_t)remaining;
    }

    size_t wrote = ctx->write_cb(ptr, allowed, ctx->userdata);
    if (wrote == allowed) ctx->bytes_written += (int64_t)allowed;
    if (wrote != allowed) return 0;
    if (allowed < n) { ctx->clamped = 1; return 0; }
    return n;
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

/* A value that doesn't fit is dropped, never clipped: a truncated validator would read as a changed file. */
static void gcb_copy_bounded(char *dst, size_t dst_sz, const char *src) {
    if (strlen(src) < dst_sz) snprintf(dst, dst_sz, "%s", src);
    else dst[0] = '\0';
}

/* "bytes a-b/total": each part is -1 when absent or unparseable. */
static void gcb_parse_content_range(const char *v, int64_t *start, int64_t *end, int64_t *total) {
    *start = -1; *end = -1; *total = -1;
    while (*v == ' ' || *v == '\t') v++;
    if (strncasecmp(v, "bytes", 5) == 0) v += 5;
    while (*v == ' ' || *v == '\t') v++;
    if (isdigit((unsigned char)*v)) {
        char *after = NULL;
        long long a = strtoll(v, &after, 10);
        if (after && *after == '-' && isdigit((unsigned char)after[1])) {
            char *after_b = NULL;
            long long b = strtoll(after + 1, &after_b, 10);
            if (a >= 0 && b >= a) { *start = a; *end = b; }
        }
    }
    const char *slash = strrchr(v, '/');
    if (slash && slash[1] && slash[1] != '*') {
        long long t = atoll(slash + 1);
        if (t > 0) *total = t;
    }
}

static size_t gcb_http_header_thunk(char *buffer, size_t size, size_t nitems, void *ud) {
    struct gcb_http_ctx *ctx = (struct gcb_http_ctx *)ud;
    size_t n = size * nitems;
    char *line = malloc(n + 1);
    if (!line) return 0;
    memcpy(line, buffer, n);
    line[n] = '\0';
    gcb_trim_inplace(line);
    if (line[0] == '\0') { free(line); return n; }

    if (strncmp(line, "HTTP/", 5) == 0) {
        const char *p = line;
        while (*p && *p != ' ') p++;
        while (*p == ' ') p++;
        ctx->http_status = atoi(p);
        ctx->content_range_total = -1;
        ctx->content_range_start = -1;
        ctx->content_range_end = -1;
        free(ctx->location);
        ctx->location = NULL;
        ctx->range_total_mismatch = 0;
        ctx->reject_body = 0;
        /* A redirect chain must surface the FINAL response's validators only. */
        ctx->etag[0] = '\0';
        ctx->last_modified[0] = '\0';
    } else if (strncasecmp(line, "Content-Range:", 14) == 0) {
        int64_t start, end, total;
        gcb_parse_content_range(line + 14, &start, &end, &total);
        ctx->content_range_start = start;
        ctx->content_range_end = end;
        if (total > 0) {
            ctx->content_range_total = total;
            if (ctx->expected_total > 0 && total != ctx->expected_total) {
                ctx->range_total_mismatch = 1;
                ctx->reject_body = 1;
            }
        } else if (ctx->expected_total > 0) {
            ctx->range_total_mismatch = 1;
            ctx->reject_body = 1;
        }
    } else if (strncasecmp(line, "Location:", 9) == 0) {
        const char *v = line + 9;
        while (*v == ' ' || *v == '\t') v++;
        free(ctx->location);
        ctx->location = strdup(v);
    } else if (strncasecmp(line, "ETag:", 5) == 0) {
        const char *v = line + 5;
        while (*v == ' ' || *v == '\t') v++;
        gcb_copy_bounded(ctx->etag, sizeof(ctx->etag), v);
    } else if (strncasecmp(line, "Last-Modified:", 14) == 0) {
        const char *v = line + 14;
        while (*v == ' ' || *v == '\t') v++;
        gcb_copy_bounded(ctx->last_modified, sizeof(ctx->last_modified), v);
    }
    free(line);
    return n;
}

static int gcb_is_https(const char *url) {
    return url && strncasecmp(url, "https://", 8) == 0;
}

char *gcb_resolve_location(const char *base, const char *loc) {
    if (!base || !loc || !loc[0]) return NULL;
    gcb_ensure_init();
    /* libcurl's RFC 3986 resolver: handles `//host/…` and a '/' inside the query, which strrchr didn't. */
    CURLU *u = curl_url();
    if (!u) return NULL;
    char *out = NULL;
    if (curl_url_set(u, CURLUPART_URL, base, 0) == CURLUE_OK
        && curl_url_set(u, CURLUPART_URL, loc, CURLU_URLENCODE) == CURLUE_OK) {
        char *resolved = NULL;
        if (curl_url_get(u, CURLUPART_URL, &resolved, 0) == CURLUE_OK && resolved) {
            out = strdup(resolved);
            curl_free(resolved);
        }
    }
    curl_url_cleanup(u);
    return out;
}

void gcb_free(void *p) { free(p); }

struct gcb_origin {
    char scheme[16];
    char host[256];
    long port;
};

static int gcb_parse_origin(const char *url, struct gcb_origin *o) {
    memset(o, 0, sizeof(*o));
    CURLU *u = curl_url();
    if (!u) return 0;
    int ok = 0;
    char *scheme = NULL, *port = NULL;
    char host[256];
    if (curl_url_set(u, CURLUPART_URL, url, 0) == CURLUE_OK
        && curl_url_get(u, CURLUPART_SCHEME, &scheme, 0) == CURLUE_OK
        && curl_url_get(u, CURLUPART_PORT, &port, CURLU_DEFAULT_PORT) == CURLUE_OK
        && gcb_extract_host(url, host, sizeof(host))
        && strlen(scheme) < sizeof(o->scheme)) {
        snprintf(o->scheme, sizeof(o->scheme), "%s", scheme);
        for (char *c = o->scheme; *c; c++) *c = (char)tolower((unsigned char)*c);
        snprintf(o->host, sizeof(o->host), "%s", host);
        o->port = atol(port);
        ok = 1;
    }
    curl_free(scheme);
    curl_free(port);
    curl_url_cleanup(u);
    return ok;
}

int gcb_redirect_keeps_secrets(const char *origin_url, const char *hop_url) {
    gcb_ensure_init();
    struct gcb_origin a, b;
    /* Fail closed: an unparseable origin or hop strips secrets. */
    if (!gcb_parse_origin(origin_url, &a) || !gcb_parse_origin(hop_url, &b)) return 0;
    if (strcasecmp(a.host, b.host) != 0) return 0;
    if (strcmp(a.scheme, b.scheme) == 0) return a.port == b.port;
    /* Same host, http → https on default ports is an upgrade, not a new origin; the reverse is a downgrade. */
    return strcmp(a.scheme, "http") == 0 && strcmp(b.scheme, "https") == 0
        && a.port == 80 && b.port == 443;
}

static int gcb_has_crlf(const char *s) {
    return s && (strchr(s, '\r') || strchr(s, '\n'));
}

/* Exact-size heap line: a fixed buffer silently clipped long JWTs. CR/LF would smuggle a second header. */
static struct curl_slist *gcb_append_header(struct curl_slist *list, const char *name, const char *value) {
    if (!value || !value[0] || gcb_has_crlf(value)) return list;
    size_t len = strlen(name) + 2 + strlen(value) + 1;
    char *line = malloc(len);
    if (!line) return list;
    snprintf(line, len, "%s: %s", name, value);
    struct curl_slist *next = curl_slist_append(list, line);
    free(line);
    return next ? next : list;
}

static struct curl_slist *gcb_http_headers(const char *user_agent,
                                          const char *referer,
                                          const char *authorization,
                                          const char *extra_headers,
                                          const char *range_value,
                                          const char *if_range,
                                          int strip_secrets) {
    struct curl_slist *list = NULL;

    list = gcb_append_header(list, "User-Agent", user_agent);
    list = gcb_append_header(list, "Range", range_value);
    if (range_value && range_value[0]) list = gcb_append_header(list, "If-Range", if_range);
    if (!strip_secrets) {
        list = gcb_append_header(list, "Referer", referer);
        list = gcb_append_header(list, "Authorization", authorization);
        if (extra_headers && extra_headers[0]) {
            const char *p = extra_headers;
            while (*p) {
                const char *nl = strchr(p, '\n');
                size_t len = nl ? (size_t)(nl - p) : strlen(p);
                while (len > 0 && (p[len - 1] == '\r' || p[len - 1] == ' ')) len--;
                if (len > 0) {
                    char *line = malloc(len + 1);
                    if (line) {
                        memcpy(line, p, len);
                        line[len] = '\0';
                        if (strchr(line, ':') && !strchr(line, '\r')) {
                            struct curl_slist *next = curl_slist_append(list, line);
                            if (next) list = next;
                        }
                        free(line);
                    }
                }
                if (!nl) break;
                p = nl + 1;
            }
        }
    }
    struct curl_slist *next = curl_slist_append(list, "Accept-Encoding: identity");
    return next ? next : list;
}

GCBHTTPResult gcb_http_range(const char *url,
                             long long range_start,
                             long long range_end,
                             const char *ifname,
                             const char *user_agent,
                             const char *referer,
                             const char *authorization,
                             const char *extra_headers,
                             const char *if_range,
                             long connect_timeout_sec,
                             long long max_recv_bps,
                             long long expected_total,
                             gcb_write write_cb,
                             gcb_progress progress_cb,
                             void *userdata) {
    GCBHTTPResult result;
    memset(&result, 0, sizeof(result));
    result.code = -1;
    result.content_range_total = -1;
    if (!url || !write_cb || !progress_cb) return result;
    /* range_start < 0 is the sentinel for "whole body, send no Range header". */
    if (range_start >= 0 && range_end < range_start) {
        result.code = (int)CURLE_BAD_FUNCTION_ARGUMENT;
        return result;
    }
    if (gcb_has_crlf(url)) {
        result.code = (int)CURLE_URL_MALFORMAT;
        return result;
    }
    gcb_ensure_init();

    char *current = strdup(url);
    if (!current) {
        result.code = (int)CURLE_OUT_OF_MEMORY;
        return result;
    }

    char range_value[128];
    range_value[0] = '\0';
    if (range_start >= 0) {
        snprintf(range_value, sizeof(range_value), "bytes=%lld-%lld", range_start, range_end);
    }

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
            free(current);
            return result;
        }

        struct gcb_http_ctx ctx;
        memset(&ctx, 0, sizeof(ctx));
        ctx.write_cb = write_cb;
        ctx.progress_cb = progress_cb;
        ctx.userdata = userdata;
        ctx.content_range_total = -1;
        ctx.content_range_start = -1;
        ctx.content_range_end = -1;
        ctx.expected_total = expected_total;
        ctx.unranged = (range_start < 0);
        ctx.range_start = range_start;
        ctx.want = range_start >= 0 ? (int64_t)(range_end - range_start + 1) : 0;

        /* Origin = scheme + host + port, as libcurl's own policy: a port change is a different server. */
        int strip = !gcb_redirect_keeps_secrets(url, current);

        struct curl_slist *headers = gcb_http_headers(
            user_agent, referer, authorization, extra_headers, range_value, if_range, strip);

        curl_easy_setopt(h, CURLOPT_URL, current);
        curl_easy_setopt(h, CURLOPT_NOSIGNAL, 1L);
        curl_easy_setopt(h, CURLOPT_CONNECTTIMEOUT, timeout);
        curl_easy_setopt(h, CURLOPT_LOW_SPEED_LIMIT, 1L);
        curl_easy_setopt(h, CURLOPT_LOW_SPEED_TIME, 60L);
        curl_easy_setopt(h, CURLOPT_FOLLOWLOCATION, 0L);
        gcb_restrict_protocols(h, "http,https", (long)(CURLPROTO_HTTP | CURLPROTO_HTTPS));
        /* 16 KB default means a callback (and a Swift write) per 16 KB at line rate. */
        curl_easy_setopt(h, CURLOPT_BUFFERSIZE, 256L * 1024L);
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
        /* The clamp stops an overshooting 206 by refusing bytes; having everything we asked for is success. */
        if (ctx.clamped && rc == CURLE_WRITE_ERROR) rc = CURLE_OK;

        long status = 0;
        curl_easy_getinfo(h, CURLINFO_RESPONSE_CODE, &status);
        if (ctx.http_status == 0 && status > 0) ctx.http_status = (int)status;

        if (!ctx.range_total_mismatch) total_written += ctx.bytes_written;
        result.code = (int)rc;
        result.http_status = ctx.http_status;
        result.content_range_total = ctx.content_range_total;
        result.bytes_written = total_written;
        result.range_total_mismatch = ctx.range_total_mismatch;
        result.range_ignored = ctx.range_ignored;
        result.range_mismatch = ctx.range_mismatch;
        snprintf(result.etag, sizeof(result.etag), "%s", ctx.etag);
        snprintf(result.last_modified, sizeof(result.last_modified), "%s", ctx.last_modified);

        if (ctx.range_total_mismatch || ctx.range_mismatch) {
            if (rc == CURLE_OK || rc == CURLE_WRITE_ERROR || rc == CURLE_ABORTED_BY_CALLBACK) {
                result.code = (int)CURLE_WRITE_ERROR;
            }
        }

        char *next_url = NULL;
        if (rc == CURLE_OK && !ctx.range_total_mismatch
            && ctx.http_status >= 300 && ctx.http_status < 400 && ctx.location) {
            next_url = gcb_resolve_location(current, ctx.location);
        }

        free(ctx.location);
        curl_slist_free_all(headers);
        curl_easy_cleanup(h);

        int finished = (rc != CURLE_OK) || ctx.range_total_mismatch || ctx.range_mismatch || !next_url;
        if (finished) {
            free(next_url);
            free(current);
            return result;
        }
        free(current);
        current = next_url;
    }

    free(current);
    result.code = (int)CURLE_TOO_MANY_REDIRECTS;
    return result;
}
