/**
 * Sample data for `npm run dev` with `?fixtures` (see dev/install.ts) and for tests: the Studio
 * mockup's queue — every state once or twice — with details, history, and server settings.
 * Dev-only: nothing here is reachable from the production bundle.
 */
import type { BandwidthState } from '../lib/bandwidth'
import type {
  AddPreviewResult,
  ConnRow,
  FileRow,
  FolderListing,
  HistoryRow,
  NetworkState,
  ScheduleState,
  TaskDetail,
  TaskRow,
  TrackerRow,
} from '../lib/types'
import { makeTask } from '../test/makeTask'

const GB = 1024 ** 3
const MB = 1024 ** 2
const KB = 1024

function nowSec(): number {
  return Math.floor(Date.now() / 1000)
}

/** The test builder with sample-queue defaults: unknown size, added an hour ago, no source. */
function row(id: string, over: Partial<TaskRow>): TaskRow {
  return makeTask(id, {
    name: id,
    totalBytes: null,
    addedAt: nowSec() - 3600,
    source: '',
    savePath: '/Users/dev/Downloads',
    ...over,
  })
}

function progressing(id: string, total: number, progress: number, speed: number, over: Partial<TaskRow>): TaskRow {
  const done = Math.round(total * progress)
  return row(id, {
    status: 'Downloading',
    statusToken: 'downloading',
    totalBytes: total,
    doneBytes: done,
    progress,
    downSpeed: speed,
    etaSeconds: speed > 0 ? Math.round((total - done) / speed) : null,
    conns: 8,
    ...over,
  })
}

export function sampleTasks(): TaskRow[] {
  const t = nowSec()
  return [
    progressing('ubuntu', 4.7 * GB, 0.62, 12 * MB, {
      name: 'ubuntu-24.04.1-desktop-amd64.iso',
      source: 'https://releases.ubuntu.com/24.04.1/ubuntu-24.04.1-desktop-amd64.iso',
      tags: ['linux'],
      addedAt: t - 600,
      savePath: '/Users/dev/Downloads/Disc images',
    }),
    progressing('cosmos', 17 * GB, 0.41, 24 * MB, {
      name: 'Cosmos.S01E04.2160p.HDR.mkv',
      kind: 'torrent',
      source: 'magnet:?xt=urn:btih:a41f9c0277d3e8&dn=Cosmos.S01E04.2160p.HDR',
      upSpeed: 640 * KB,
      seeds: 112,
      conns: 38,
      multiFile: true,
      fileCount: 6,
      streamable: true,
      addedAt: t - 1500,
      tags: ['tv'],
    }),
    progressing('backup', 2.2 * GB, 0.78, 7.7 * MB, {
      name: 'project-backup-2026-07.tar.zst',
      kind: 'sftp',
      source: 'sftp://nas.home/backups/project-backup-2026-07.tar.zst',
      conns: 1,
      addedAt: t - 2400,
    }),
    row('magnet', {
      name: 'magnet:?xt=urn:btih:5c1a9d3e8f',
      status: 'Requesting info…',
      statusToken: 'metadata',
      kind: 'torrent',
      source: 'magnet:?xt=urn:btih:5c1a9d3e8f',
      addedAt: t - 3000,
    }),
    row('field', {
      name: 'Field Recordings Vol. 3.flac',
      totalBytes: 1.3 * GB,
      source: 'https://archive.org/download/field-recordings/Field%20Recordings%20Vol.%203.flac',
      queuePosition: 0,
      addedAt: t - 3300,
    }),
    row('figma', {
      name: 'Figma-126.4.dmg',
      totalBytes: 412 * MB,
      source: 'https://desktop.figma.com/mac/Figma-126.4.dmg',
      queuePosition: 1,
      addedAt: t - 3400,
      startAt: t + 6 * 3600,
    }),
    row('fedora', {
      name: 'Fedora-Workstation-40.iso',
      status: 'Failed',
      statusToken: 'failed',
      kind: 'ftp',
      totalBytes: 2.4 * GB,
      doneBytes: 120 * MB,
      progress: 0.05,
      error: 'FTP server closed the connection',
      source: 'ftp://download.fedoraproject.org/pub/fedora/linux/releases/40/Workstation/x86_64/iso/Fedora-Workstation-40.iso',
      addedAt: t - 20000,
    }),
    row('imagenet', {
      name: 'imagenet-mini-dataset.zip',
      status: 'Paused',
      statusToken: 'paused',
      totalBytes: 1.1 * GB,
      doneBytes: 0.34 * 1.1 * GB,
      progress: 0.34,
      source: 'https://data.example.org/imagenet-mini-dataset.zip',
      addedAt: t - 90000,
    }),
    row('bunny', {
      name: 'BigBuckBunny-1080p.mp4',
      status: 'Completed',
      statusToken: 'completed',
      kind: 'hls',
      totalBytes: 340 * MB,
      doneBytes: 340 * MB,
      progress: 1,
      streamable: true,
      source: 'https://test-streams.mux.dev/bbb/master.m3u8',
      addedAt: t - 5000,
      completedAt: t - 1200,
    }),
    row('q3', {
      name: 'Q3-board-pack.pdf',
      status: 'Completed',
      statusToken: 'completed',
      totalBytes: 8.4 * MB,
      doneBytes: 8.4 * MB,
      progress: 1,
      source: 'https://drive.company.com/files/Q3-board-pack.pdf',
      addedAt: t - 7000,
      completedAt: t - 2800,
    }),
    row('debian', {
      name: 'debian-12.6.0-amd64-DVD-1.iso',
      status: 'Seeding',
      statusToken: 'seeding',
      kind: 'torrent',
      totalBytes: 3.7 * GB,
      doneBytes: 3.7 * GB,
      progress: 1,
      upSpeed: 1.8 * MB,
      upBytes: 1.2 * 3.7 * GB,
      ratio: 1.2,
      seeds: 40,
      conns: 12,
      source: 'magnet:?xt=urn:btih:d3b1&dn=debian-12.6.0-amd64-DVD-1.iso',
      addedAt: t - 9000,
      completedAt: t - 4000,
      tags: ['linux'],
    }),
  ]
}

function files(id: string): FileRow[] {
  if (id !== 'cosmos') return []
  return [
    { id: 0, name: 'Cosmos.S01E04.2160p.HDR/Cosmos.S01E04.2160p.HDR.mkv', size: 16.4 * GB, done: 0.4 * 16.4 * GB, progress: 0.4, priority: 'high' },
    { id: 1, name: 'Cosmos.S01E04.2160p.HDR/Subs/English.srt', size: 84 * KB, done: 84 * KB, progress: 1, priority: 'normal' },
    { id: 2, name: 'Cosmos.S01E04.2160p.HDR/Subs/Español.srt', size: 86 * KB, done: 86 * KB, progress: 1, priority: 'normal' },
    { id: 3, name: 'Cosmos.S01E04.2160p.HDR/Subs/Français.srt', size: 85 * KB, done: 0, progress: 0, priority: 'skip' },
    { id: 4, name: 'Cosmos.S01E04.2160p.HDR/Featurettes/Making.Of.mkv', size: 930 * MB, done: 0, progress: 0, priority: 'skip' },
    { id: 5, name: 'Cosmos.S01E04.2160p.HDR/cosmos.nfo', size: 4 * KB, done: 4 * KB, progress: 1, priority: 'low' },
  ]
}

function trackers(task: TaskRow): TrackerRow[] {
  if (task.kind !== 'torrent') return []
  return [
    { url: 'udp://tracker.opentrackr.org:1337/announce', host: 'tracker.opentrackr.org', tier: 0, status: 'Working', seeds: 88, leeches: 41, message: '', state: 'working' },
    { url: 'udp://open.stealth.si:80/announce', host: 'open.stealth.si', tier: 0, status: 'Working', seeds: 24, leeches: 13, message: '', state: 'working' },
    { url: 'https://tracker.example.org/announce', host: 'tracker.example.org', tier: 1, status: 'Retrying', seeds: null, leeches: null, message: 'Connection timed out', state: 'error' },
  ]
}

function connections(task: TaskRow): ConnRow[] {
  if (task.statusToken !== 'downloading' && task.statusToken !== 'seeding') return []
  if (task.kind === 'torrent') {
    return [
      { id: 'p1', label: '185.21.xx.14', detail: 'qBittorrent 5.0', down: 4.1 * MB, up: 0, progress: 1, adapterId: 'en0', adapterLabel: 'Wi-Fi' },
      { id: 'p2', label: '91.134.xx.2', detail: 'Transmission 4.0', down: 3.6 * MB, up: 0, progress: 1, adapterId: 'en0', adapterLabel: 'Wi-Fi' },
      { id: 'p3', label: '2a01:4f8::7c', detail: 'libtorrent 2.0', down: 2.2 * MB, up: 210 * KB, progress: 0.72, adapterId: 'en5', adapterLabel: 'Ethernet' },
      { id: 'p4', label: '62.210.xx.88', detail: 'Deluge 2.1', down: 1.4 * MB, up: 180 * KB, progress: 0.55, adapterId: 'en0', adapterLabel: 'Wi-Fi' },
    ]
  }
  return Array.from({ length: 6 }, (_, i) => ({
    id: `s${i + 1}`,
    label: `Segment ${i + 1}`,
    detail: `bytes ${(i * 0.59).toFixed(2)}–${((i + 1) * 0.59).toFixed(2)} GB`,
    down: (2 - i * 0.2) * MB,
    up: 0,
    progress: Math.max(0.1, 1 - i * 0.16),
    adapterId: i % 2 ? 'en5' : 'en0',
    adapterLabel: i % 2 ? 'Ethernet' : 'Wi-Fi',
  }))
}

function pieces(task: TaskRow): number[] {
  if (task.kind !== 'torrent') return []
  let seed = 7
  const rnd = () => (seed = (seed * 9301 + 49297) % 233280) / 233280
  return Array.from({ length: 400 }, (_, i) => {
    const p = i / 400
    if (task.progress >= 1) return 1
    if (p < task.progress * 0.7 || rnd() < task.progress * 0.45) return 1
    return rnd() > 0.94 ? 0.5 : 0
  })
}

export function sampleDetail(task: TaskRow): TaskDetail {
  return {
    row: task,
    savePath: task.savePath ?? '/Users/dev/Downloads',
    sequential: task.id === 'cosmos',
    infoHash: task.kind === 'torrent' ? 'a41f9c02e1b7d3c09f8877d3e8' : null,
    files: files(task.id),
    trackers: trackers(task),
    connections: connections(task),
    pieces: pieces(task),
    server: task.kind === 'http' ? 'Apache' : null,
    mimeType: task.name.endsWith('.iso') ? 'application/x-iso9660-image' : null,
  }
}

export function sampleHistory(): HistoryRow[] {
  const t = nowSec()
  const h = (id: string, name: string, kind: HistoryRow['kind'], size: number | null, ago: number, source: string): HistoryRow => ({
    id,
    name,
    kind,
    totalBytes: size,
    savePath: '/Users/dev/Downloads',
    completedAt: t - ago,
    source,
  })
  return [
    h('h1', 'BigBuckBunny-1080p.mp4', 'hls', 340 * MB, 1200, 'https://test-streams.mux.dev/bbb/master.m3u8'),
    h('h2', 'Q3-board-pack.pdf', 'http', 8.4 * MB, 2800, 'https://drive.company.com/files/Q3-board-pack.pdf'),
    h('h3', 'debian-12.6.0-amd64-DVD-1.iso', 'torrent', 3.7 * GB, 4000, 'magnet:?xt=urn:btih:d3b1'),
    h('h4', 'Blender-4.2.3-macos-arm64.dmg', 'http', 398 * MB, 30 * 3600, 'https://download.blender.org/release/Blender4.2/blender-4.2.3-macos-arm64.dmg'),
    h('h5', 'Field Recordings Vol. 2.flac', 'http', 1.1 * GB, 33 * 3600, 'https://archive.org/download/field-recordings/vol2.flac'),
    h('h6', 'project-backup-2026-06.tar.zst', 'sftp', 2.1 * GB, 4 * 86400, 'sftp://nas.home/backups/project-backup-2026-06.tar.zst'),
    h('h7', 'Sprite.Fright.2021.4K.mkv', 'torrent', 4.4 * GB, 5 * 86400, 'magnet:?xt=urn:btih:5c1a'),
    h('h8', 'classroom.zip', 'ftp', 141 * MB, 40 * 86400, 'ftp://download.blender.org/demo/classroom.zip'),
  ]
}

export function sampleBandwidth(): BandwidthState {
  return {
    enabled: true,
    selected: 'Medium',
    profiles: [
      { name: 'Low', downBytesPerSec: 2 * MB, upBytesPerSec: 256 * KB },
      { name: 'Medium', downBytesPerSec: 20 * MB, upBytesPerSec: 2 * MB },
      { name: 'High', downBytesPerSec: null, upBytesPerSec: null },
    ],
    locked: [],
  }
}

export function sampleSchedule(): ScheduleState {
  return { enabled: true, startMinute: 23 * 60, endMinute: 7 * 60, days: [1, 2, 3, 4, 5, 6, 7], profile: 'High', profiles: ['Low', 'Medium', 'High'] }
}

export function sampleNetwork(): NetworkState {
  return {
    aggregation: true,
    streamsPerAdapter: 4,
    selected: [],
    reason: null,
    locked: false,
    adapters: [
      { name: 'en0', label: 'Wi-Fi', type: 'wifi', ipv4: '192.168.0.42', expensive: false, eligible: true },
      { name: 'en5', label: 'Ethernet', type: 'ethernet', ipv4: '192.168.0.43', expensive: false, eligible: true },
      { name: 'pdp_ip0', label: 'iPhone hotspot', type: 'cellular', ipv4: '172.20.10.2', expensive: true, eligible: false },
    ],
  }
}

export function sampleFolders(path?: string): FolderListing {
  const at = path || '/Users/dev/Downloads'
  const kids = ['Apps', 'Disc images', 'Music', 'Video', 'Work']
  return {
    path: at,
    parent: at === '/' ? null : at.split('/').slice(0, -1).join('/') || '/',
    folders: kids.map((name) => ({ name, path: `${at === '/' ? '' : at}/${name}`, readable: true, writable: name !== 'Work' })),
    writable: true,
    home: '/Users/dev',
    defaultFolder: '/Users/dev/Downloads',
    places: [
      { name: 'Home', path: '/Users/dev', readable: true, writable: true },
      { name: 'Downloads', path: '/Users/dev/Downloads', readable: true, writable: true },
      { name: 'Media', path: '/Volumes/Media', readable: true, writable: false },
    ],
  }
}

export function samplePreview(lines: readonly string[]): AddPreviewResult {
  return {
    freeBytes: 312 * GB,
    items: lines.map((line, index) => {
      const magnet = line.startsWith('magnet:')
      const supported = /^(https?|ftps?|sftp):\/\/|^magnet:\?/.test(line)
      const name = magnet ? (/dn=([^&]+)/.exec(line)?.[1] ?? null) : (line.split('/').pop() ?? null)
      const duplicate = line.includes('ubuntu-24.04.1-desktop')
      const credentials = line.includes('partner')
      return {
        index,
        status: !supported ? 'unsupported' : duplicate ? 'duplicate' : credentials ? 'credentials' : magnet ? 'unchecked' : 'ok',
        name,
        kind: !supported ? null : magnet ? 'torrent' : line.includes('.m3u8') ? 'hls' : 'http',
        totalBytes: magnet || !supported ? null : 600 * MB + index * 150 * MB,
        estimated: false,
        files: [],
        fileCount: 1,
        note: duplicate ? 'Already in your list' : null,
      }
    }),
  }
}
