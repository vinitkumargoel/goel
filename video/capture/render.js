/* Builds the Goel° UI replica: each builder returns a DOM string; capture.mjs picks ?page= and ?theme=.
 * Elements needing separate animation carry data-cap="<name>" — read back as cutouts + layout.json bboxes. */
import {
  ROWS, SIDEBAR, ICON, pieceStates, SFTP_REMOTE, SFTP_LOCAL,
  SVG_VIDEO, SVG_DISC, SVG_ARCHIVE,
} from './fixtures.js';

const esc = (s) => String(s).replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));

const ACTION_ICON = { play: 'playFill', retry: 'retry', done: 'folder' };

/* The desktop app abbreviates BITTORRENT to BT in the row badge; the web
   portal spells it out. Both are reproduced as the app draws them. */
const SHORT_PROTO = { BITTORRENT: 'BT' };

function rowHTML(r, i, { shortProto = true } = {}) {
  const bar = r.bar ? ` ${r.bar}` : '';
  const pauseGlyph = ICON[ACTION_ICON[r.action] || 'pauseFill'](13);
  const proto = shortProto ? SHORT_PROTO[r.proto] || r.proto : r.proto;
  return `
  <div class="row${r.sel ? ' sel' : ''}" data-cap="row-${r.id}">
    <span class="idx">${i + 1}</span>
    <button class="pp">${pauseGlyph}</button>
    <span class="namecell">
      <span class="fico ${r.kind}">${r.glyph}</span>
      <span class="nmwrap">
        <span class="nmline">
          <span class="nm">${esc(r.name)}</span>
          <span class="proto ${r.protoCls}">${proto}</span>
        </span>
        <span class="pbar${bar}"><i style="width:${r.pct}%"></i></span>
      </span>
    </span>
    <span class="r">${r.size || '—'}</span>
    <span class="st-c"><span class="st ${r.state}"><span class="t">${esc(r.status)}</span></span></span>
    <span>${r.added}</span>
    <span class="r ${r.down ? 'spd d' : 'spd none'}">${r.down || '—'}</span>
    <span class="r ${r.up ? 'spd u' : 'spd none'}">${r.up || '—'}</span>
  </div>`;
}

function sidebarHTML() {
  return SIDEBAR.map((s) => {
    if (s.h) return `<h4>${s.h}${s.add ? '<span class="srv-add">+</span>' : ''}</h4>`;
    if (s.hint) return `<div class="hint">${s.hint}</div>`;
    return `<div class="si${s.on ? ' on' : ''}"><span class="g">${ICON[s.icon](15)}</span>${s.label}${
      s.n != null ? `<span class="n">${s.n}</span>` : ''
    }</div>`;
  }).join('');
}

function toolbarHTML() {
  return `
  <div class="bar" data-cap="toolbar">
    <span class="tl"><i></i><i></i><i></i></span>
    <button class="btn-add" data-cap="btn-add">${ICON.plus()} Add download</button>
    <span class="sep"></span>
    <span class="chip">${ICON.checkCircle(14)} Select <span class="car">${ICON.chevron()}</span></span>
    <span class="chip">${ICON.sort()} Sort <span class="car">${ICON.chevron()}</span></span>
    <span class="chip">${ICON.filter()} Filter <span class="car">${ICON.chevron()}</span></span>
    <span class="spacer"></span>
    <span class="search">${ICON.search()} Search downloads</span>
    <span class="icon-btn">${ICON.sidebarRight()}</span>
  </div>`;
}

function listHTML(empty, opts) {
  return `
  <div class="list" data-cap="list">
    <div class="lhead">
      <span>#</span><span class="nm-h">Name ↑</span><span class="r">Size</span>
      <span class="st-h">Status</span><span>Added</span>
      <span class="r">↓ Speed</span><span class="r">↑ Speed</span>
    </div>
    <div class="rows" data-cap="rows">${
      empty ? '' : ROWS.map((r, i) => rowHTML(r, i, opts)).join('')
    }</div>
  </div>`;
}

const RING_C = 2 * Math.PI * 52;

function ringHTML(pct, cap = 'ring') {
  return `
  <div class="ringwrap"><div class="ring" data-cap="${cap}">
    <svg width="118" height="118" viewBox="0 0 118 118">
      <circle class="trk" cx="59" cy="59" r="52" fill="none" stroke-width="9"/>
      <circle class="arc" cx="59" cy="59" r="52" fill="none" stroke-width="9"
              stroke-dasharray="${RING_C}" stroke-dashoffset="${RING_C * (1 - pct / 100)}"/>
    </svg>
    <div class="lab"><div><b>${pct}%</b><span>complete</span></div></div>
  </div></div>`;
}

function detailHTML() {
  return `
  <aside class="detail" data-cap="detail">
    <div class="d-top">
      <span class="fico iso">${SVG_DISC}</span>
      <div>
        <div class="d-name">ubuntu-24.04.1-desktop-<br>amd64.iso</div>
        <div class="d-sub2"><span class="proto http">HTTP</span><span class="st down">Downloading</span></div>
      </div>
      <span class="d-panelbtn">${ICON.sidebarRight(12)}</span>
    </div>
    <div class="tabs">
      <span class="tab on">General</span><span class="tab">Details</span>
      <span class="tab">Progress</span><span class="tab">Files</span><span class="tab">Connections</span>
    </div>
    ${ringHTML(62)}
    <div class="ud" data-cap="ud-tiles">
      <div class="t"><span>↓ DOWN</span><b class="g">12 MB/s</b></div>
      <div class="t"><span>↑ UP</span><b>—</b></div>
    </div>
    <div class="d-line">2.90 GB of 4.69 GB · ~3m</div>
    <div class="kv"><span>Connections</span><b>8</b></div>
    <div class="kv"><span>Priority</span><b>Normal</b></div>
    <div class="kv"><span>Added</span><b>Today 21:04</b></div>
    <div class="kv"><span>Save path</span><b><span class="tr">~/Downloads/ubuntu-24.04.1…</span><span class="cp">${ICON.copy()}</span></b></div>
    <div class="kv"><span>Source</span><b><span class="tr">releases.ubuntu.com/24.04…</span><span class="cp">${ICON.copy()}</span></b></div>
    <div class="d-acts">
      <span class="b pri">${ICON.pauseFill(12)} Pause</span><span class="b">${ICON.folder(12)} Folder</span><span class="b">${ICON.copy(12)} Copy</span>
    </div>
  </aside>`;
}

/** BitTorrent detail: same panel, Progress tab, piece map instead of the ring. */
function torrentDetailHTML(emptyMap) {
  const cells = pieceStates()
    .map((s, i) => `<i class="${emptyMap ? '' : s}" data-p="${i}"></i>`)
    .join('');
  return `
  <aside class="detail" data-cap="detail">
    <div class="d-top" data-cap="tcell-head">
      <span class="fico video">${SVG_VIDEO}</span>
      <div>
        <div class="d-name">Cosmos.S01E04.2160p.<br>HDR.mkv</div>
        <div class="d-sub2"><span class="proto bt">BITTORRENT</span><span class="st down">Downloading</span></div>
      </div>
      <span class="d-panelbtn">▥</span>
    </div>
    <div class="tabs">
      <span class="tab">General</span><span class="tab">Details</span>
      <span class="tab on">Progress</span><span class="tab">Files</span><span class="tab">Connections</span>
    </div>
    <div style="padding:18px 0 0" data-cap="tcell-map">
      <div class="pmap" data-cap="pmap">${cells}</div>
      <div class="pmap-legend">
        <span>pieces <b>408</b></span><span>have <b>294</b></span><span>ratio <b>2.40</b></span>
      </div>
    </div>
    <div class="ud" style="margin-top:16px" data-cap="tcell-rate">
      <div class="t"><span>↓ DOWN</span><b class="g">24 MB/s</b></div>
      <div class="t"><span>↑ UP</span><b>640 KB/s</b></div>
    </div>
    <div data-cap="tcell-facts">
      <div class="d-line">7.0 GB of 17 GB · ~7m · 34 peers</div>
      <div class="kv"><span>Seed ratio</span><b>2.40</b></div>
      <div class="kv"><span>Peers</span><b>34 connected</b></div>
      <div class="kv"><span>Priority</span><b>High · per-file</b></div>
    </div>
    <div class="d-acts" data-cap="tcell-acts">
      <span class="b pri">${ICON.pauseFill(12)} Pause</span><span class="b">${ICON.folder(12)} Folder</span><span class="b">${ICON.copy(12)} Copy</span>
    </div>
  </aside>`;
}

function statusHTML() {
  return `
  <div class="status" data-cap="statusbar">
    <span class="chip">∞ Unlimited</span>
    <span class="m d" data-cap="speed-down">↓ 43 MB/s</span>
    <span class="m u" data-cap="speed-up">↑ 2.4 MB/s</span>
    <span class="spacer"></span>
    <span style="color:var(--ink-faint)">Profile</span>
    <span class="prof"><b>Low</b><b>Medium</b><b class="on">High</b></span>
  </div>`;
}

export function buildApp({ empty = false, torrent = false } = {}) {
  return `
  <div class="win" data-cap="window">
    ${toolbarHTML()}
    <div class="body">
      <aside class="side" data-cap="sidebar">${sidebarHTML()}</aside>
      ${listHTML(empty)}
      ${torrent ? torrentDetailHTML(false) : detailHTML()}
    </div>
    ${statusHTML()}
  </div>`;
}

export function buildSFTP() {
  const rows = (list) =>
    list
      .map(
        (f) => `<div class="frow${f.dir ? ' dir' : ''}"${f.hot ? ' data-cap="sftp-hot"' : ''}>
        <span class="fg">${f.g}</span>${esc(f.name)}<span class="sz">${f.size}</span></div>`
      )
      .join('');
  return `
  <div class="win" data-cap="window">
    ${toolbarHTML()}
    <div class="body">
      <aside class="side" data-cap="sidebar">${sidebarHTML()}</aside>
      <div class="sftp-panes">
        <div class="pane" data-cap="pane-remote">
          <div class="pane-head"><span class="dot"></span> home-server
            <span class="path">/srv/backups</span>
            <span style="margin-left:auto;color:var(--green);font-size:10px">host key pinned</span>
          </div>
          ${rows(SFTP_REMOTE)}
        </div>
        <div class="pane" data-cap="pane-local">
          <div class="pane-head" style="color:var(--ink-faint)">This Mac
            <span class="path">~/Downloads</span>
          </div>
          ${rows(SFTP_LOCAL)}
        </div>
      </div>
    </div>
    ${statusHTML()}
  </div>`;
}

export function buildMenuBar({ popover = true, rows = true, window: showWin = false } = {}) {
  const items = ROWS.filter((r) => r.state === 'down' || r.state === 'meta').slice(0, 4);
  return `
  ${showWin ? buildApp() : ''}
  <div class="menubar">
    <span class="brand">Goel°</span>
    <span>File</span><span>Edit</span><span>Downloads</span><span>Window</span><span>Help</span>
    <span class="right">
      <span style="opacity:.7">◷</span><span style="opacity:.7">◉</span><span style="opacity:.7">≋</span>
      <span class="mb-speed"><span class="d">↓ 43 MB/s</span><span class="u">↑ 2.4 MB/s</span></span>
      <span>Thu 22:41</span>
    </span>
  </div>
  ${!popover ? '' : `
  <div class="pop" data-cap="popover" style="left:570px;top:36px">
    <div class="pop-head">Active · 4
      <span class="m" style="margin-left:auto;color:var(--green)">↓ 43 MB/s</span>
      <span class="m" style="color:var(--accent)">↑ 2.4 MB/s</span>
    </div>
    ${!rows ? '' : items
      .map(
        (r, i) => `<div class="pop-row" data-cap="pop-row-${i}">
      <span class="fico ${r.kind}">${r.glyph}</span>
      <span class="mid">
        <span class="l1"><span class="nm">${esc(
          r.name.length > 30 ? r.name.slice(0, 29) + '…' : r.name
        )}</span><span class="proto ${r.protoCls}">${r.protoCls === 'bt' ? 'BT' : r.proto}</span></span>
        <span class="pbar${r.bar ? ' ' + r.bar : ''}"><i style="width:${r.pct}%"></i></span>
        <span class="l2">${esc(r.status)}<span class="sp">${r.down || (r.state === 'meta' ? '3 peers' : '—')}</span></span>
      </span>
      <span class="pp">⏸</span>
    </div>`
      )
      .join('')}
    <div class="pop-cta">+ Add download</div>
    <div class="pop-foot">⏸ Pause all<span class="r">Open Goel° ›</span></div>
  </div>`}`;
}

export function buildPortal() {
  return `
  <div class="chrome" data-cap="window">
    <div class="chrome-bar">
      <span class="tl"><i></i><i></i><i></i></span>
      <span class="urlbar"><span class="lock">🔒</span> goel.local:7878/queue</span>
    </div>
    <div class="portal-top">
      <span class="logo-sq">g</span><span class="wordmark">Goel°</span><span class="tagchip">WEB</span>
      <span class="search" style="width:300px;margin-left:14px">${ICON.search()} Search downloads</span>
      <span class="spacer" style="flex:1"></span>
      <span class="m spd d" style="font-size:12px">↓ 43 MB/s</span>
      <span class="m spd u" style="font-size:12px">↑ 2.3 MB/s</span>
      <span class="btn-add" style="margin-left:6px">+ Add</span>
      <span class="avatar">A</span><span style="color:var(--ink-soft);font-size:12px">admin</span>
    </div>
    <div class="body" style="flex:1;display:flex;min-height:0">
      <aside class="side" data-cap="sidebar">${sidebarHTML()}</aside>
      ${listHTML(false)}
    </div>
    <div class="status">
      <span>8 downloads</span><span class="spacer" style="flex:1"></span><span>Signed in · admin</span>
    </div>
  </div>`;
}

/** A compact transfer card — the object that flies between windows in shot 9. Same tokens as the
 *  app's rows; a 17:1 table row does not read as a thing you can carry. */
export function buildChip() {
  return `
  <div class="tchip" data-cap="chip">
    <span class="fico archive">${SVG_ARCHIVE}</span>
    <span class="tc-mid">
      <span class="tc-name">project-backup-2026-07.tar.zst</span>
      <span class="tc-meta"><span class="proto sftp">SFTP</span>home-server &middot; 2.2 GB</span>
    </span>
  </div>`;
}

export const PAGES = {
  app: () => buildApp(),
  'app-empty': () => buildApp({ empty: true }),
  torrent: () => buildApp({ torrent: true }),
  sftp: buildSFTP,
  menubar: () => buildMenuBar(),
  // the desktop the popover drops onto, and the popover body without its rows —
  // shot 12 needs both so the rows can stagger in over an empty panel
  desktop: () => buildMenuBar({ popover: false, window: true }),
  'menubar-norows': () => buildMenuBar({ rows: false }),
  portal: buildPortal,
  chip: buildChip,
};
