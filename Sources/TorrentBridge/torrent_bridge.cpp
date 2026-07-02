#include "torrent_bridge.h"

#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_flags.hpp>
#include <libtorrent/file_storage.hpp>
#include <libtorrent/download_priority.hpp>
#include <libtorrent/peer_info.hpp>

#include <cstring>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

namespace lt = libtorrent;

namespace {

void copy_string(char *dst, int cap, std::string const &src) {
    if (cap <= 0) return;
    int n = static_cast<int>(src.size());
    if (n >= cap) n = cap - 1;
    std::memcpy(dst, src.data(), static_cast<size_t>(n));
    dst[n] = '\0';
}

lt::torrent_handle *as_handle(GTHandle h) { return static_cast<lt::torrent_handle *>(h); }

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
    sp.set_int(lt::settings_pack::alert_mask,
               lt::alert_category::status | lt::alert_category::error);
    sp.set_bool(lt::settings_pack::enable_dht, enable_dht != 0);
    sp.set_bool(lt::settings_pack::enable_lsd, enable_lsd != 0);
    sp.set_bool(lt::settings_pack::enable_outgoing_utp, enable_utp != 0);
    sp.set_bool(lt::settings_pack::enable_incoming_utp, enable_utp != 0);

    int policy = lt::settings_pack::pe_enabled;
    if (enc_policy == 0) policy = lt::settings_pack::pe_disabled;
    else if (enc_policy == 2) policy = lt::settings_pack::pe_forced;
    sp.set_int(lt::settings_pack::out_enc_policy, policy);
    sp.set_int(lt::settings_pack::in_enc_policy, policy);

    sp.set_str(lt::settings_pack::listen_interfaces, "0.0.0.0:6881,[::]:6881");
    sp.set_str(lt::settings_pack::user_agent, "GoelDownloader/1.0 libtorrent/2.0");

    auto *session = new lt::session(sp);
    return static_cast<GTSession>(session);
}

void gt_session_destroy(GTSession session) {
    delete static_cast<lt::session *>(session);
}

void gt_session_set_rate_limits(GTSession session, int download_bps, int upload_bps) {
    if (!session) return;
    auto *ses = static_cast<lt::session *>(session);
    lt::settings_pack sp;
    sp.set_int(lt::settings_pack::download_rate_limit, download_bps);
    sp.set_int(lt::settings_pack::upload_rate_limit, upload_bps);
    ses->apply_settings(sp);
}

GTHandle gt_add_magnet(GTSession session, const char *magnet_uri, const char *save_path,
                       char *err_out, int err_cap) {
    if (!session) return nullptr;
    auto *ses = static_cast<lt::session *>(session);
    lt::error_code ec;
    lt::add_torrent_params atp = lt::parse_magnet_uri(magnet_uri, ec);
    if (ec) { if (err_out) copy_string(err_out, err_cap, ec.message()); return nullptr; }
    atp.save_path = save_path;
    atp.flags &= ~lt::torrent_flags::auto_managed;
    atp.flags &= ~lt::torrent_flags::paused;
    lt::torrent_handle handle = ses->add_torrent(std::move(atp), ec);
    if (ec || !handle.is_valid()) {
        if (err_out) copy_string(err_out, err_cap, ec ? ec.message() : "could not add magnet");
        return nullptr;
    }
    return static_cast<GTHandle>(new lt::torrent_handle(handle));
}

GTHandle gt_add_torrent_file(GTSession session, const char *file_path, const char *save_path,
                             char *err_out, int err_cap) {
    if (!session) return nullptr;
    auto *ses = static_cast<lt::session *>(session);
    lt::error_code ec;
    auto info = std::make_shared<lt::torrent_info>(std::string(file_path), ec);
    if (ec) { if (err_out) copy_string(err_out, err_cap, ec.message()); return nullptr; }
    lt::add_torrent_params atp;
    atp.ti = info;
    atp.save_path = save_path;
    atp.flags &= ~lt::torrent_flags::auto_managed;
    atp.flags &= ~lt::torrent_flags::paused;
    lt::torrent_handle handle = ses->add_torrent(std::move(atp), ec);
    if (ec || !handle.is_valid()) {
        if (err_out) copy_string(err_out, err_cap, ec ? ec.message() : "could not add torrent");
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
        auto *ses = static_cast<lt::session *>(session);
        ses->remove_torrent(*h, delete_files ? lt::session::delete_files : lt::remove_flags_t{});
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
    if (name_out) copy_string(name_out, name_cap, std::string(fs.file_name(fi)));
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

void gt_set_file_priority(GTHandle handle, int index, int priority) {
    auto *h = as_handle(handle);
    if (!h || !h->is_valid()) return;
    h->file_priority(lt::file_index_t(index), lt::download_priority_t(static_cast<std::uint8_t>(priority)));
}

} // extern "C"
