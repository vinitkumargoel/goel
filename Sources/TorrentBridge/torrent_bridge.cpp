#include "torrent_bridge.h"

#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/alert.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_flags.hpp>
#include <libtorrent/file_storage.hpp>
#include <libtorrent/download_priority.hpp>
#include <libtorrent/peer_info.hpp>
#include <libtorrent/announce_entry.hpp>
#include <libtorrent/info_hash.hpp>
#include <libtorrent/sha1_hash.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/write_resume_data.hpp>

#include <chrono>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <vector>

namespace lt = libtorrent;

namespace {

/// What a `GTSession` really points at: the libtorrent session plus the last
/// session-level failure we pulled off its alert queue. Alerts are drained by
/// `gt_save_resume_data` (the only consumer); anything that isn't the blob we
/// are waiting for is inspected for a listen failure and then discarded.
struct SessionBox {
    lt::session ses;
    std::mutex mu;
    std::string last_error;
    explicit SessionBox(lt::settings_pack const &sp) : ses(sp) {}
};

void copy_string(char *dst, int cap, std::string const &src) {
    if (cap <= 0) return;
    int n = static_cast<int>(src.size());
    if (n >= cap) n = cap - 1;
    std::memcpy(dst, src.data(), static_cast<size_t>(n));
    dst[n] = '\0';
}

lt::torrent_handle *as_handle(GTHandle h) { return static_cast<lt::torrent_handle *>(h); }

SessionBox *as_box(GTSession s) { return static_cast<SessionBox *>(s); }

/// Map our 0/1/2 encryption selector onto libtorrent's policy constants. Shared
/// by session creation and the live-apply path so the two can't drift.
int map_enc_policy(int enc_policy) {
    if (enc_policy == 0) return lt::settings_pack::pe_disabled;
    if (enc_policy == 2) return lt::settings_pack::pe_forced;
    return lt::settings_pack::pe_enabled;
}

/// Fold the caller's `GTAddMode` bits into an `add_torrent_params`.
void apply_add_mode(lt::add_torrent_params &atp, int mode) {
    if (mode & GT_ADD_METADATA_ONLY) {
        // `duplicate_is_error`: without it libtorrent hands back the handle of a
        // torrent already in the session, so removing the probe would evict the
        // user's running download. Fail closed instead.
        // `upload_mode`: a preview must not fetch payload before the user has
        // agreed to anything. Magnet metadata rides a separate extension and
        // still resolves.
        atp.flags |= lt::torrent_flags::duplicate_is_error;
        atp.flags |= lt::torrent_flags::upload_mode;
    }
    if (mode & GT_ADD_DISABLE_PEX) atp.flags |= lt::torrent_flags::disable_pex;
}

/// Record a session-level failure worth telling the user about. First one wins
/// until it is read, so a flapping interface can't bury the original cause.
void note_session_error(SessionBox *box, lt::alert const *a) {
    auto const *failed = lt::alert_cast<lt::listen_failed_alert>(a);
    if (!failed) return;
    std::lock_guard<std::mutex> lock(box->mu);
    if (box->last_error.empty()) box->last_error = failed->message();
}

/// Replace `path` with `data` atomically, so an interrupted write can never
/// leave a truncated resume blob behind (libtorrent would reject it and the
/// torrent would silently re-hash).
bool write_atomically(std::string const &path, std::vector<char> const &data) {
    std::string const tmp = path + ".tmp";
    {
        std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
        if (!out) return false;
        out.write(data.data(), static_cast<std::streamsize>(data.size()));
        out.close();
        if (!out) { std::remove(tmp.c_str()); return false; }
    }
    if (std::rename(tmp.c_str(), path.c_str()) != 0) {
        std::remove(tmp.c_str());
        return false;
    }
    return true;
}

GTState map_state(lt::torrent_status const &st) {
    if (st.errc) return GT_STATE_ERROR;
    if (st.flags & lt::torrent_flags::paused) return GT_STATE_PAUSED;
    switch (st.state) {
        case lt::torrent_status::checking_files:
        case lt::torrent_status::checking_resume_data:
            return GT_STATE_CHECKING;
        case lt::torrent_status::downloading_metadata:
            return GT_STATE_METADATA;
        case lt::torrent_status::downloading:
            return GT_STATE_DOWNLOADING;
        case lt::torrent_status::finished:
            return GT_STATE_FINISHED;
        case lt::torrent_status::seeding:
            return GT_STATE_SEEDING;
        default:
            return GT_STATE_DOWNLOADING;
    }
}

} // namespace

extern "C" {

GTSession gt_session_create(int enable_dht, int enable_lsd, int enable_utp, int enc_policy) {
    lt::settings_pack sp;
    // `storage` carries save_resume_data_alert — without it fast resume would
    // silently never produce a blob.
    sp.set_int(lt::settings_pack::alert_mask,
               lt::alert_category::status | lt::alert_category::error
                   | lt::alert_category::storage);
    sp.set_bool(lt::settings_pack::enable_dht, enable_dht != 0);
    sp.set_bool(lt::settings_pack::enable_lsd, enable_lsd != 0);
    sp.set_bool(lt::settings_pack::enable_outgoing_utp, enable_utp != 0);
    sp.set_bool(lt::settings_pack::enable_incoming_utp, enable_utp != 0);

    int const policy = map_enc_policy(enc_policy);
    sp.set_int(lt::settings_pack::out_enc_policy, policy);
    sp.set_int(lt::settings_pack::in_enc_policy, policy);

    // The ephemeral entries are a fallback: another BitTorrent client already
    // holding 6881 would otherwise leave us with no listen socket at all, i.e.
    // no inbound peers, with nothing in the UI saying so.
    sp.set_str(lt::settings_pack::listen_interfaces,
               "0.0.0.0:6881,[::]:6881,0.0.0.0:0,[::]:0");
    sp.set_str(lt::settings_pack::user_agent, "GoelDownloader/1.0 libtorrent/2.0");

    // Throughput tuning. libtorrent's stock defaults are tuned conservatively;
    // these safe bumps help a client saturate modern broadband:
    //  - connection_speed: peer connection attempts per second — dial the swarm
    //    up faster so download speed ramps sooner (default ~30).
    //  - aio_threads: disk I/O / hashing worker threads — keeps piece writes and
    //    hash checks off the critical path on fast NVMe storage (default ~10).
    // connections_limit is applied separately from the active traffic profile
    // (see gt_session_set_connections).
    sp.set_int(lt::settings_pack::connection_speed, 100);
    sp.set_int(lt::settings_pack::aio_threads, 16);

    return static_cast<GTSession>(new SessionBox(sp));
}

void gt_session_destroy(GTSession session) {
    delete as_box(session);
}

void gt_session_set_rate_limits(GTSession session, int download_bps, int upload_bps) {
    if (!session) return;
    lt::settings_pack sp;
    sp.set_int(lt::settings_pack::download_rate_limit, download_bps);
    sp.set_int(lt::settings_pack::upload_rate_limit, upload_bps);
    as_box(session)->ses.apply_settings(sp);
}

void gt_session_set_connections(GTSession session, int connections_limit) {
    if (!session || connections_limit < 1) return;
    lt::settings_pack sp;
    sp.set_int(lt::settings_pack::connections_limit, connections_limit);
    as_box(session)->ses.apply_settings(sp);
}

void gt_session_apply_settings(GTSession session, int enable_dht, int enable_lsd,
                               int enable_utp, int enc_policy) {
    if (!session) return;
    lt::settings_pack sp;
    sp.set_bool(lt::settings_pack::enable_dht, enable_dht != 0);
    sp.set_bool(lt::settings_pack::enable_lsd, enable_lsd != 0);
    sp.set_bool(lt::settings_pack::enable_outgoing_utp, enable_utp != 0);
    sp.set_bool(lt::settings_pack::enable_incoming_utp, enable_utp != 0);
    int const policy = map_enc_policy(enc_policy);
    sp.set_int(lt::settings_pack::out_enc_policy, policy);
    sp.set_int(lt::settings_pack::in_enc_policy, policy);
    as_box(session)->ses.apply_settings(sp);
}

void gt_session_set_proxy(GTSession session, int proxy_type, const char *host,
                          int port, int peer_connections) {
    if (!session) return;
    lt::settings_pack sp;
    sp.set_int(lt::settings_pack::proxy_type, proxy_type);
    sp.set_str(lt::settings_pack::proxy_hostname, host ? host : "");
    sp.set_int(lt::settings_pack::proxy_port, port);
    // Resolve tracker/peer hostnames at the proxy so the local resolver never
    // sees them, and always carry tracker announces. Peer connections are the
    // caller's call — an HTTP proxy cannot carry them, and libtorrent warns
    // against asking it to.
    sp.set_bool(lt::settings_pack::proxy_hostnames, true);
    sp.set_bool(lt::settings_pack::proxy_tracker_connections, true);
    sp.set_bool(lt::settings_pack::proxy_peer_connections, peer_connections != 0);
    as_box(session)->ses.apply_settings(sp);
}

int gt_session_last_error(GTSession session, char *out, int cap) {
    if (!session || !out || cap <= 0) return 0;
    auto *box = as_box(session);
    // Drain whatever is queued first. Nothing else consumes alerts between
    // resume saves, and libtorrent starts dropping them once the queue fills.
    // Safe against `gt_save_resume_data`'s own pump: both are called from the
    // same actor, which never runs two of its own methods at once.
    std::vector<lt::alert *> alerts;
    box->ses.pop_alerts(&alerts);
    for (auto *a : alerts) note_session_error(box, a);
    std::lock_guard<std::mutex> lock(box->mu);
    if (box->last_error.empty()) return 0;
    copy_string(out, cap, box->last_error);
    box->last_error.clear();
    return 1;
}

GTHandle gt_add_magnet(GTSession session, const char *magnet_uri, const char *save_path,
                       int mode, char *err_out, int err_cap) {
    if (!session) return nullptr;
    auto *ses = &as_box(session)->ses;
    lt::error_code ec;
    lt::add_torrent_params atp = lt::parse_magnet_uri(magnet_uri, ec);
    if (ec) { if (err_out) copy_string(err_out, err_cap, ec.message()); return nullptr; }
    atp.save_path = save_path;
    atp.flags &= ~lt::torrent_flags::auto_managed;
    atp.flags &= ~lt::torrent_flags::paused;
    apply_add_mode(atp, mode);
    lt::torrent_handle handle = ses->add_torrent(std::move(atp), ec);
    if (ec || !handle.is_valid()) {
        if (err_out) copy_string(err_out, err_cap, ec ? ec.message() : "could not add magnet");
        return nullptr;
    }
    return static_cast<GTHandle>(new lt::torrent_handle(handle));
}

GTHandle gt_add_torrent_file(GTSession session, const char *file_path, const char *save_path,
                             int mode, char *err_out, int err_cap) {
    if (!session) return nullptr;
    auto *ses = &as_box(session)->ses;
    lt::error_code ec;
    auto info = std::make_shared<lt::torrent_info>(std::string(file_path), ec);
    if (ec) { if (err_out) copy_string(err_out, err_cap, ec.message()); return nullptr; }
    lt::add_torrent_params atp;
    atp.ti = info;
    atp.save_path = save_path;
    atp.flags &= ~lt::torrent_flags::auto_managed;
    atp.flags &= ~lt::torrent_flags::paused;
    apply_add_mode(atp, mode);
    lt::torrent_handle handle = ses->add_torrent(std::move(atp), ec);
    if (ec || !handle.is_valid()) {
        if (err_out) copy_string(err_out, err_cap, ec ? ec.message() : "could not add torrent");
        return nullptr;
    }
    return static_cast<GTHandle>(new lt::torrent_handle(handle));
}

int gt_save_resume_data(GTSession session, GTHandle handle, const char *path, int timeout_ms) {
    auto *h = as_handle(handle);
    if (!session || !h || !h->is_valid() || !path) return 0;
    auto *box = as_box(session);
    auto *ses = &box->ses;
    try {
        // Without metadata there is nothing worth persisting, and libtorrent
        // answers with save_resume_data_failed_alert anyway.
        if (!h->torrent_file()) return 0;
        h->save_resume_data(lt::torrent_handle::save_info_dict);
    } catch (...) { return 0; }

    auto const deadline = std::chrono::steady_clock::now()
        + std::chrono::milliseconds(timeout_ms > 0 ? timeout_ms : 5000);
    try {
        for (;;) {
            auto const now = std::chrono::steady_clock::now();
            if (now >= deadline) return 0;
            ses->wait_for_alert(std::chrono::duration_cast<lt::time_duration>(deadline - now));
            std::vector<lt::alert *> alerts;
            ses->pop_alerts(&alerts);
            for (auto *a : alerts) {
                note_session_error(box, a);
                if (auto const *failed = lt::alert_cast<lt::save_resume_data_failed_alert>(a)) {
                    if (failed->handle == *h) return 0;
                } else if (auto const *saved = lt::alert_cast<lt::save_resume_data_alert>(a)) {
                    if (!(saved->handle == *h)) continue;
                    return write_atomically(path, lt::write_resume_data_buf(saved->params)) ? 1 : 0;
                }
            }
        }
    } catch (...) { return 0; }
}

GTHandle gt_add_resume(GTSession session, const char *resume_path, const char *save_path,
                       int mode, char *err_out, int err_cap) {
    if (!session || !resume_path) return nullptr;
    auto *ses = &as_box(session)->ses;
    std::ifstream in(resume_path, std::ios::binary);
    if (!in) { if (err_out) copy_string(err_out, err_cap, "no saved resume data"); return nullptr; }
    std::vector<char> const buf((std::istreambuf_iterator<char>(in)),
                                std::istreambuf_iterator<char>());
    if (buf.empty()) { if (err_out) copy_string(err_out, err_cap, "resume data is empty"); return nullptr; }
    lt::error_code ec;
    lt::add_torrent_params atp = lt::read_resume_data(buf, ec);
    if (ec) { if (err_out) copy_string(err_out, err_cap, ec.message()); return nullptr; }
    // The blob remembers where it was last saved; the app's folder is the one
    // the user can still see and change, so it wins.
    atp.save_path = save_path;
    atp.flags &= ~lt::torrent_flags::auto_managed;
    atp.flags &= ~lt::torrent_flags::paused;
    apply_add_mode(atp, mode);
    lt::torrent_handle handle = ses->add_torrent(std::move(atp), ec);
    if (ec || !handle.is_valid()) {
        if (err_out) copy_string(err_out, err_cap, ec ? ec.message() : "could not restore torrent");
        return nullptr;
    }
    return static_cast<GTHandle>(new lt::torrent_handle(handle));
}

void gt_pause(GTHandle handle) {
    auto *h = as_handle(handle);
    if (h && h->is_valid()) {
        h->unset_flags(lt::torrent_flags::auto_managed);
        h->pause();
    }
}

void gt_resume(GTHandle handle) {
    auto *h = as_handle(handle);
    if (h && h->is_valid()) h->resume();
}

void gt_remove(GTSession session, GTHandle handle, int delete_files) {
    auto *h = as_handle(handle);
    if (session && h && h->is_valid()) {
        as_box(session)->ses.remove_torrent(
            *h, delete_files ? lt::session::delete_files : lt::remove_flags_t{});
    }
    delete h;
}

void gt_handle_free(GTHandle handle) {
    delete as_handle(handle);
}

int gt_get_status(GTHandle handle, GTStatus *out) {
    auto *h = as_handle(handle);
    if (!h || !h->is_valid() || !out) return 0;
    lt::torrent_status st = h->status();
    std::memset(out, 0, sizeof(GTStatus));
    out->state = map_state(st);
    out->has_metadata = (h->torrent_file() != nullptr) ? 1 : 0;
    out->num_peers = st.num_peers;
    out->num_seeds = st.num_seeds;
    out->total_bytes = static_cast<int64_t>(st.total_wanted);
    out->downloaded_bytes = static_cast<int64_t>(st.total_wanted_done);
    out->uploaded_bytes = static_cast<int64_t>(st.all_time_upload);
    out->download_rate = static_cast<double>(st.download_payload_rate);
    out->upload_rate = static_cast<double>(st.upload_payload_rate);
    out->progress = static_cast<double>(st.progress);
    copy_string(out->name, sizeof(out->name), st.name);
    if (st.errc) copy_string(out->error, sizeof(out->error), st.errc.message());
    return 1;
}

int gt_peers(GTHandle handle, GTPeer *out, int cap) {
    auto *h = as_handle(handle);
    if (!h || !h->is_valid() || !out || cap <= 0) return 0;
    std::vector<lt::peer_info> peers;
    h->get_peer_info(peers);
    int n = 0;
    for (auto const &p : peers) {
        if (n >= cap) break;
        GTPeer &gp = out[n];
        std::memset(&gp, 0, sizeof(GTPeer));
        std::ostringstream endpoint;
        endpoint << p.ip;
        copy_string(gp.address, sizeof(gp.address), endpoint.str());
        copy_string(gp.client, sizeof(gp.client), p.client);
        gp.down_rate = static_cast<double>(p.payload_down_speed);
        gp.up_rate = static_cast<double>(p.payload_up_speed);
        gp.progress = static_cast<double>(p.progress);
        ++n;
    }
    return n;
}

void gt_set_sequential(GTHandle handle, int sequential) {
    auto *h = as_handle(handle);
    if (!h || !h->is_valid()) return;
    if (sequential) h->set_flags(lt::torrent_flags::sequential_download);
    else h->unset_flags(lt::torrent_flags::sequential_download);
}

void gt_set_download_limit(GTHandle handle, int bytes_per_sec) {
    auto *h = as_handle(handle);
    if (!h || !h->is_valid()) return;
    h->set_download_limit(bytes_per_sec > 0 ? bytes_per_sec : 0);
}

void gt_set_pex(GTHandle handle, int enable) {
    auto *h = as_handle(handle);
    if (!h || !h->is_valid()) return;
    try {
        if (enable) h->unset_flags(lt::torrent_flags::disable_pex);
        else h->set_flags(lt::torrent_flags::disable_pex);
    } catch (...) {}
}

int gt_file_count(GTHandle handle) {
    auto *h = as_handle(handle);
    if (!h || !h->is_valid()) return 0;
    auto info = h->torrent_file();
    if (!info) return 0;
    return info->files().num_files();
}

int gt_file_info(GTHandle handle, int index, char *name_out, int name_cap,
                 int64_t *size_out, int64_t *done_out, int *priority_out) {
    auto *h = as_handle(handle);
    if (!h || !h->is_valid()) return 0;
    auto info = h->torrent_file();
    if (!info) return 0;
    lt::file_storage const &fs = info->files();
    if (index < 0 || index >= fs.num_files()) return 0;
    lt::file_index_t fi(index);
    // The path relative to the save folder, not the bare file name: two files
    // called `01.mkv` in different subfolders are otherwise indistinguishable in
    // the picker and over the remote portal. It stays inert text on the Swift
    // side — nothing joins it onto a save directory.
    if (name_out) copy_string(name_out, name_cap, fs.file_path(fi));
    if (size_out) *size_out = static_cast<int64_t>(fs.file_size(fi));
    if (done_out) {
        std::vector<std::int64_t> progress;
        h->file_progress(progress);
        *done_out = (index < static_cast<int>(progress.size()))
            ? static_cast<int64_t>(progress[static_cast<size_t>(index)]) : 0;
    }
    if (priority_out) *priority_out = static_cast<int>(h->file_priority(fi));
    return 1;
}

int gt_file_progress(GTHandle handle, int64_t *out, int cap) {
    auto *h = as_handle(handle);
    if (!h || !h->is_valid() || !out || cap <= 0) return 0;
    try {
        std::vector<std::int64_t> progress;
        h->file_progress(progress);
        int n = static_cast<int>(progress.size());
        if (n > cap) n = cap;
        for (int i = 0; i < n; ++i) out[i] = static_cast<int64_t>(progress[static_cast<size_t>(i)]);
        return n;
    } catch (...) { return 0; }
}

void gt_set_file_priority(GTHandle handle, int index, int priority) {
    auto *h = as_handle(handle);
    if (!h || !h->is_valid()) return;
    try {
        // Bounds-check the index (like gt_file_info): this is now reached with
        // indices sourced from persisted/preview state, not just a fresh
        // 0..<count enumeration, so a stale out-of-range id must not be handed
        // to libtorrent unchecked.
        auto info = h->torrent_file();
        if (!info) return;
        if (index < 0 || index >= info->files().num_files()) return;
        h->file_priority(lt::file_index_t(index),
                         lt::download_priority_t(static_cast<std::uint8_t>(priority)));
    } catch (...) {}
}

int gt_info_hash(GTHandle handle, char *out, int cap) {
    auto *h = as_handle(handle);
    if (!h || !h->is_valid() || !out || cap <= 0) return 0;
    try {
        lt::info_hash_t const ih = h->info_hashes();
        lt::sha1_hash const hash = ih.has_v1() ? ih.v1 : lt::sha1_hash();
        if (hash.is_all_zeros()) return 0;
        std::ostringstream oss;
        oss << hash;   // libtorrent renders a sha1_hash as lowercase hex
        copy_string(out, cap, oss.str());
        return 1;
    } catch (...) { return 0; }
}

int gt_trackers(GTHandle handle, GTTracker *out, int cap) {
    auto *h = as_handle(handle);
    if (!h || !h->is_valid() || !out || cap <= 0) return 0;
    try {
    std::vector<lt::announce_entry> const trackers = h->trackers();
    int n = 0;
    for (auto const &ae : trackers) {
        if (n >= cap) break;
        GTTracker &gt = out[n];
        std::memset(&gt, 0, sizeof(GTTracker));
        copy_string(gt.url, sizeof(gt.url), ae.url);
        gt.tier = ae.tier;
        gt.verified = ae.verified ? 1 : 0;
        gt.num_seeds = -1;
        gt.num_leeches = -1;

        // Aggregate the per-endpoint / per-protocol (v1+v2) announce state into a
        // single row: worst-case status, best-known scrape counts, first message.
        bool anyUpdating = false, anyError = false, anyWorking = false;
        for (auto const &ep : ae.endpoints) {
            for (int v = 0; v < 2; ++v) {
                auto const &aih = ep.info_hashes[lt::protocol_version(v)];
                if (aih.updating) anyUpdating = true;
                if (aih.last_error) {
                    anyError = true;
                    if (gt.message[0] == '\0')
                        copy_string(gt.message, sizeof(gt.message), aih.last_error.message());
                } else if (!aih.message.empty() && gt.message[0] == '\0') {
                    copy_string(gt.message, sizeof(gt.message), aih.message);
                }
                if (aih.scrape_complete >= 0) {
                    anyWorking = true;
                    if (aih.scrape_complete > gt.num_seeds) gt.num_seeds = aih.scrape_complete;
                }
                if (aih.scrape_incomplete >= 0 && aih.scrape_incomplete > gt.num_leeches)
                    gt.num_leeches = aih.scrape_incomplete;
                if (aih.start_sent || aih.complete_sent) anyWorking = true;
            }
        }
        if (anyWorking) gt.status = GT_TRACKER_WORKING;
        else if (anyUpdating) gt.status = GT_TRACKER_UPDATING;
        else if (anyError) gt.status = GT_TRACKER_ERROR;
        else gt.status = GT_TRACKER_INACTIVE;
        ++n;
    }
    return n;
    } catch (...) { return 0; }
}

int gt_piece_count(GTHandle handle) {
    auto *h = as_handle(handle);
    if (!h || !h->is_valid()) return 0;
    try {
        auto info = h->torrent_file();
        if (!info) return 0;
        return info->num_pieces();
    } catch (...) { return 0; }
}

int gt_pieces(GTHandle handle, uint8_t *out, int cap) {
    auto *h = as_handle(handle);
    if (!h || !h->is_valid() || !out || cap <= 0) return 0;
    try {
        lt::torrent_status const st = h->status(lt::torrent_handle::query_pieces);
        auto const &pieces = st.pieces;
        int const total = static_cast<int>(pieces.size());
        if (total <= 0) return 0;
        // Downsample the WHOLE piece bitfield into up to `cap` contiguous
        // buckets, each carrying the fraction of its pieces that are complete
        // scaled to 0..255. libtorrent already materialises the full bitfield
        // for query_pieces, so averaging here is cheap and — unlike copying just
        // the first `cap` pieces — represents torrents of any size (a torrent
        // with more pieces than `cap` previously showed only its head, hiding
        // the tail's progress on the piece map).
        int const buckets = total < cap ? total : cap;   // never more buckets than pieces
        for (int b = 0; b < buckets; ++b) {
            long long const lo = static_cast<long long>(b) * total / buckets;
            long long hi = static_cast<long long>(b + 1) * total / buckets;
            if (hi <= lo) hi = lo + 1;
            if (hi > total) hi = total;
            int have = 0;
            int const cnt = static_cast<int>(hi - lo);
            for (long long i = lo; i < hi; ++i) {
                if (pieces[lt::piece_index_t{static_cast<int>(i)}]) ++have;
            }
            out[b] = static_cast<uint8_t>((have * 255 + cnt / 2) / cnt);
        }
        return buckets;
    } catch (...) { return 0; }
}

void gt_force_recheck(GTHandle handle) {
    auto *h = as_handle(handle);
    if (!h || !h->is_valid()) return;
    try { h->force_recheck(); } catch (...) {}
}

void gt_force_reannounce(GTHandle handle) {
    auto *h = as_handle(handle);
    if (!h || !h->is_valid()) return;
    try { h->force_reannounce(); } catch (...) {}
}

void gt_set_upload_limit(GTHandle handle, int bytes_per_sec) {
    auto *h = as_handle(handle);
    if (!h || !h->is_valid()) return;
    try { h->set_upload_limit(bytes_per_sec > 0 ? bytes_per_sec : 0); } catch (...) {}
}

} // extern "C"
