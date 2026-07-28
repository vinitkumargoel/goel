/* No Date.now()/Math.random() anywhere: the capture must be byte-reproducible. */

export const SVG_MAGNET =
  '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor"' +
  ' stroke-width="2.6" stroke-linecap="round">' +
  '<path d="M5 4v8a7 7 0 0 0 14 0V4"/><path d="M5 11h5M14 11h5"/></svg>';

export const SVG_VIDEO =
  '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor"' +
  ' stroke-width="2" stroke-linejoin="round">' +
  '<rect x="2.5" y="6" width="14" height="12" rx="2.5"/>' +
  '<path d="M16.5 10.5 21.5 7.5v9l-5-3z"/></svg>';

export const SVG_DISC =
  '<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor"' +
  ' stroke-width="1.9"><circle cx="12" cy="12" r="8.4"/>' +
  '<circle cx="12" cy="12" r="2.5" fill="currentColor" stroke="none"/></svg>';

export const SVG_ARCHIVE =
  '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor"' +
  ' stroke-width="1.9" stroke-linejoin="round">' +
  '<rect x="5" y="3.4" width="14" height="17.2" rx="2.6"/>' +
  '<rect x="10.4" y="6.4" width="3.2" height="4.6" rx="1"/>' +
  '<path d="M12 11v6.4"/></svg>';

export const ROWS = [
  {
    id: 1, kind: 'iso', glyph: SVG_DISC, proto: 'HTTP', protoCls: 'http',
    name: 'ubuntu-24.04.1-desktop-amd64.iso',
    size: '4.7 GB', pct: 62, bar: '',
    state: 'down', status: '62% · 3m left',
    added: 'Today 21:04', down: '12 MB/s', up: null, sel: true,
  },
  {
    id: 2, kind: 'iso', glyph: SVG_DISC, proto: 'BITTORRENT', protoCls: 'bt',
    name: 'debian-12.6.0-amd64-DVD-1.iso',
    size: '3.7 GB', pct: 100, bar: 'green',
    state: 'seed', status: 'Seeding · ratio 2.40',
    added: 'Today 18:20', down: null, up: '1.8 MB/s',
  },
  {
    id: 3, kind: 'video', glyph: SVG_VIDEO, proto: 'BITTORRENT', protoCls: 'bt',
    name: 'Cosmos.S01E04.2160p.HDR.mkv',
    size: '17 GB', pct: 41, bar: '',
    state: 'down', status: '41% · 7m left',
    added: 'Today 20:55', down: '24 MB/s', up: '640 KB/s',
  },
  {
    id: 4, kind: 'archive', glyph: SVG_ARCHIVE, proto: 'SFTP', protoCls: 'sftp',
    name: 'project-backup-2026-07.tar.zst',
    size: '2.2 GB', pct: 78, bar: '',
    state: 'down', status: '78% · 1m left',
    added: 'Today 22:31', down: '7.7 MB/s', up: null,
  },
  {
    id: 5, kind: 'magnet', glyph: SVG_MAGNET, proto: 'BITTORRENT', protoCls: 'bt',
    name: 'magnet:?xt=urn:btih:5c1a9d3e77…metadata',
    size: null, pct: 18, bar: 'yellow',
    state: 'meta', status: 'Requesting info…',
    added: 'Today 22:40', down: null, up: null,
  },
  {
    id: 6, kind: 'archive', glyph: SVG_ARCHIVE, proto: 'HTTP', protoCls: 'http',
    name: 'imagenet-mini-dataset.zip',
    size: '1.1 GB', pct: 34, bar: 'dim',
    state: 'pause', status: 'Paused · 34%',
    added: 'Yesterday 14:02', down: null, up: null, action: 'play',
  },
  {
    id: 7, kind: 'video', glyph: SVG_VIDEO, proto: 'HLS', protoCls: 'hls',
    name: 'BigBuckBunny-1080p.mp4',
    size: '340 MB', pct: 100, bar: 'green',
    state: 'done', status: 'Completed',
    added: 'Yesterday 11:20', down: null, up: null, action: 'done',
  },
  {
    id: 8, kind: 'iso', glyph: SVG_DISC, proto: 'FTP', protoCls: 'ftp',
    name: 'Fedora-Workstation-40.iso',
    size: '2.4 GB', pct: 12, bar: 'red',
    state: 'fail', status: 'FTP server closed connection',
    added: 'Yesterday 09:15', down: null, up: null, action: 'retry',
  },
];

export const SIDEBAR = [
  { h: 'LIBRARY' },
  { icon: 'tray', label: 'All files', n: 8, on: true },
  { h: 'STATUS' },
  { icon: 'arrowDownCircle', label: 'Active', n: 4 },
  { icon: 'pauseCircle', label: 'Paused', n: 1 },
  { icon: 'checkCircle', label: 'Completed', n: 1 },
  { icon: 'arrowUpCircle', label: 'Seeding', n: 1 },
  { h: 'TYPE' },
  { icon: 'film', label: 'Video' },
  { icon: 'disc', label: 'Disc images' },
  { icon: 'zipper', label: 'Archives' },
  { icon: 'appBadge', label: 'Apps' },
  { h: 'SERVERS', add: true },
  { hint: 'Add an SFTP server to browse and transfer files.' },
];

export function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function pieceStates(count = 408, filled = 0.72, seed = 0x60e1) {
  const rnd = mulberry32(seed);
  const order = Array.from({ length: count }, (_, i) => ({ i, k: rnd() }))
    .sort((a, b) => a.k - b.k)
    .map((o) => o.i);
  const have = new Set(order.slice(0, Math.floor(count * filled)));
  const busy = new Set(order.slice(Math.floor(count * filled), Math.floor(count * filled) + 5));
  return Array.from({ length: count }, (_, i) =>
    have.has(i) ? 'have' : busy.has(i) ? 'busy' : ''
  );
}

export const SFTP_REMOTE = [
  { g: '▸', name: 'backups', dir: true, size: '—' },
  { g: '▸', name: 'isos', dir: true, size: '—' },
  { g: SVG_ARCHIVE, name: 'project-backup-2026-07.tar.zst', size: '2.2 GB', hot: true },
  { g: SVG_ARCHIVE, name: 'db-dump-nightly.sql.gz', size: '840 MB' },
  { g: SVG_DISC, name: 'ubuntu-24.04.1-live-server.iso', size: '2.1 GB' },
  { g: '📄', name: 'deploy.log', size: '1.4 MB' },
];

export const SFTP_LOCAL = [
  { g: '▸', name: 'Downloads', dir: true, size: '—' },
  { g: SVG_DISC, name: 'ubuntu-24.04.1-desktop-amd64.iso', size: '4.7 GB' },
  { g: SVG_VIDEO, name: 'Cosmos.S01E04.2160p.HDR.mkv', size: '17 GB' },
  { g: SVG_ARCHIVE, name: 'imagenet-mini-dataset.zip', size: '1.1 GB' },
];

export const DEPS = ['libcurl', 'libssh2', 'OpenSSL', 'FFmpeg', 'yt-dlp', 'SQLite', 'Sparkle'];

export const BROWSERS = ['chrome', 'safari', 'firefox', 'edge', 'brave'];

const svg = (size, body, sw = 1.7) =>
  `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none"` +
  ` stroke="currentColor" stroke-width="${sw}" stroke-linecap="round"` +
  ` stroke-linejoin="round">${body}</svg>`;

const RING = '<circle cx="12" cy="12" r="9"/>';

export const ICON = {
  tray: (s = 15) =>
    svg(s, '<path d="M4 13.5h4l1.2 2h5.6l1.2-2h4"/>' +
           '<path d="M4 13.5 6.2 7.4A1.6 1.6 0 0 1 7.7 6.3h8.6a1.6 1.6 0 0 1 1.5 1.1L20 13.5v3.1a1.9 1.9 0 0 1-1.9 1.9H5.9A1.9 1.9 0 0 1 4 16.6z"/>'),
  arrowDownCircle: (s = 15) => svg(s, RING + '<path d="M12 7.9v8.2M8.7 12.8 12 16.1l3.3-3.3"/>'),
  pauseCircle: (s = 15) => svg(s, RING + '<path d="M10.2 8.9v6.2M13.8 8.9v6.2"/>'),
  checkCircle: (s = 15) => svg(s, RING + '<path d="M8.2 12.2 11 15l4.9-5.6"/>'),
  arrowUpCircle: (s = 15) => svg(s, RING + '<path d="M12 16.1V7.9M8.7 11.2 12 7.9l3.3 3.3"/>'),
  /* The source passes `film`, but the shipped build draws the camcorder body, and that is what this replica is judged against. */
  film: (s = 15) =>
    svg(s, '<rect x="2.8" y="6.6" width="12.6" height="10.8" rx="2.2"/>' +
           '<path d="M15.4 11 21 8v8l-5.6-3z"/>', 1.7),
  disc: (s = 15) => svg(s, RING + '<circle cx="12" cy="12" r="2.6"/>'),
  zipper: (s = 15) =>
    svg(s, '<path d="M7.6 3.6h5.9l4.9 4.9v11.9a1.8 1.8 0 0 1-1.8 1.8H7.6a1.8 1.8 0 0 1-1.8-1.8V5.4a1.8 1.8 0 0 1 1.8-1.8z"/>' +
           '<path d="M13.2 3.7v4.6h4.8"/><path d="M9.6 6.2h1.4M9.6 9h1.4M9.6 11.8h1.4M9.6 14.6h1.4"/>', 1.5),
  appBadge: (s = 15) =>
    svg(s, '<rect x="3.4" y="5.4" width="13.2" height="13.2" rx="3.4"/><circle cx="18.4" cy="6.6" r="3"/>', 1.5),
  sort: (s = 14) =>
    svg(s, '<path d="M8.4 19.2V5.2M5.2 8.4l3.2-3.2 3.2 3.2"/>' +
           '<path d="M15.6 4.8v14M12.4 15.6l3.2 3.2 3.2-3.2"/>'),
  filter: (s = 14) => svg(s, '<path d="M4.2 7.2h15.6M6.6 12h10.8M9.4 16.8h5.2"/>'),
  chevron: (s = 10) => svg(s, '<path d="M6.4 9.6 12 15.2l5.6-5.6"/>', 2.4),
  search: (s = 13) => svg(s, '<circle cx="10.6" cy="10.6" r="5.8"/><path d="M14.9 14.9 19.4 19.4"/>', 1.9),
  sidebarRight: (s = 14) =>
    svg(s, '<rect x="3" y="5" width="18" height="14" rx="2.4"/><path d="M14.6 5v14"/>', 1.6),
  plus: (s = 12) => svg(s, '<path d="M12 5.6v12.8M5.6 12h12.8"/>', 2.2),
  pauseFill: (s = 13) =>
    svg(s, '<rect x="8.4" y="5.2" width="3" height="13.6" rx="1" fill="currentColor" stroke="none"/>' +
           '<rect x="12.6" y="5.2" width="3" height="13.6" rx="1" fill="currentColor" stroke="none"/>'),
  playFill: (s = 13) =>
    svg(s, '<path d="M7.6 5 18.6 12 7.6 19z" fill="currentColor" stroke="none"/>'),
  folder: (s = 13) =>
    svg(s, '<path d="M3.4 7.4a2 2 0 0 1 2-2h3.4l1.9 2.3h7.9a2 2 0 0 1 2 2v7.5a2 2 0 0 1-2 2H5.4a2 2 0 0 1-2-2z"/>', 1.7),
  retry: (s = 13) =>
    svg(s, '<path d="M19.4 12a7.4 7.4 0 1 1-2.2-5.2"/><path d="M19.6 4v4.6H15"/>', 1.9),
  copy: (s = 12) =>
    svg(s, '<rect x="8.4" y="8.4" width="11.2" height="11.2" rx="2"/>' +
           '<path d="M15.6 8.4V6.4a2 2 0 0 0-2-2H6.4a2 2 0 0 0-2 2v7.2a2 2 0 0 0 2 2h2"/>', 1.6),
};
