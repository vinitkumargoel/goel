import { act, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ComponentProps } from 'react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { sampleDetail, sampleTasks } from '../../dev/fixtures'
import type { QueueControls } from '../../hooks/useQueueControls'
import en from '../../locales/en.json'
import sheet from '../../locales/en.json'
import { speedStore } from '../../lib/speedStore'
import type { TaskDetail, TaskRow } from '../../lib/types'
import { makeTask } from '../../test/makeTask'
import { renderWithI18n } from '../../test/renderWithI18n'
import { DetailPanel } from './DetailPanel'
import { shownTab, tabsFor } from './DetailPanes'

const S = sheet.sheet

const TORRENT: TaskDetail = {
  row: makeTask('t1', {
    name: 'debian-13.iso',
    status: 'Paused',
    statusToken: 'paused',
    kind: 'torrent',
    progress: 0.5,
    totalBytes: 4_000_000_000,
    doneBytes: 2_000_000_000,
    upBytes: 100_000,
    ratio: 0.05,
    seeds: 12,
    conns: 30,
    addedAt: 1_700_000_000,
    source: 'magnet:?xt=urn:btih:abc',
    multiFile: false,
  }),
  savePath: '/srv/downloads/debian-13.iso',
  sequential: true,
  infoHash: 'abc123',
  files: [],
  trackers: [],
  connections: [],
  pieces: [],
  server: null,
  mimeType: null,
}

const HTTP: TaskDetail = {
  ...TORRENT,
  row: { ...TORRENT.row, kind: 'http', statusToken: 'downloading', status: 'Downloading', conns: 8, source: 'https://example.org/a.iso' },
  infoHash: null,
  server: 'Apache',
  mimeType: 'application/x-iso9660-image',
  connections: [
    { id: 's1', label: 'Segment 1', detail: '0–1 GB', down: 1024, up: 0, progress: 1, adapterId: null, adapterLabel: null },
    { id: 's2', label: 'Segment 2', detail: '1–2 GB', down: 2048, up: 0, progress: 0.5, adapterId: null, adapterLabel: null },
  ],
}

afterEach(() => {
  vi.unstubAllGlobals()
  speedStore.reset()
})

function queueControls() {
  return {
    edit: vi.fn(),
    move: vi.fn(),
    setSequential: vi.fn(),
    setTags: vi.fn(),
    setStartAt: vi.fn(),
    editTrackers: vi.fn(() => Promise.resolve(true)),
  } satisfies QueueControls
}

type Props = ComponentProps<typeof DetailPanel>

function renderPane(detail: TaskDetail, over: Partial<Props> = {}) {
  const props: Props = {
    detail,
    open: true,
    tab: 'overview',
    canWrite: true,
    onTab: vi.fn(),
    onClose: vi.fn(),
    onAction: vi.fn(),
    onRemove: vi.fn(),
    onMore: vi.fn(),
    onCopy: vi.fn(),
    onSetFiles: vi.fn(() => Promise.resolve()),
    onCyclePriority: vi.fn(),
    ...over,
  }
  renderWithI18n(<DetailPanel {...props} />)
  return { props, panel: screen.getByRole('tabpanel') }
}

function withRow(detail: TaskDetail, over: Partial<TaskRow>): TaskDetail {
  return { ...detail, row: { ...detail.row, ...over } }
}

describe('tab helpers', () => {
  it('gives only torrents a Peers tab, and falls back to Overview', () => {
    expect(tabsFor('torrent')).toEqual(['overview', 'files', 'peers', 'network'])
    expect(tabsFor('http')).toEqual(['overview', 'files', 'network'])
    expect(shownTab('peers', 'ftp')).toBe('overview')
    expect(shownTab('files', 'ftp')).toBe('files')
  })
})

describe('Overview', () => {
  it('leads with the percentage, bytes and an arc in the state’s tone', () => {
    const { panel } = renderPane(TORRENT)
    expect(panel.querySelector('.bignum')).toHaveTextContent('50%')
    expect(within(panel).getByText('1.9 GB of 3.7 GB')).toBeInTheDocument()
    const ring = within(panel).getByRole('progressbar', { name: en.library.progress })
    expect(ring).toHaveAttribute('aria-valuenow', '50')
    expect(ring.querySelector('.ring')).toHaveClass('paused')
  })

  it('never rounds an unfinished download up to 100%', () => {
    const { panel } = renderPane(withRow(TORRENT, { progress: 0.996 }))
    expect(panel.querySelector('.bignum')).toHaveTextContent('99%')
  })

  it('renders the facts from the catalogue, with the swarm for a torrent', () => {
    const { panel } = renderPane(TORRENT)
    for (const key of [en.detail.general.savePath, en.detail.general.added, en.detail.general.protocol, en.detail.general.shareRatio]) {
      expect(within(panel).getByText(key)).toBeInTheDocument()
    }
    expect(within(panel).getByText('12 seeds · 30 peers')).toBeInTheDocument()
    expect(within(panel).getByText('BitTorrent')).toBeInTheDocument()
    expect(within(panel).getByText(S.priority).nextElementSibling).toHaveTextContent(en.task.priority.normal)
  })

  it('copies the save path and the source', async () => {
    const { props, panel } = renderPane(TORRENT)
    const copies = within(panel).getAllByRole('button', { name: en.common.copy })
    await userEvent.click(copies[0]!)
    await userEvent.click(copies[1]!)
    expect(props.onCopy).toHaveBeenNthCalledWith(1, '/srv/downloads/debian-13.iso')
    expect(props.onCopy).toHaveBeenNthCalledWith(2, 'magnet:?xt=urn:btih:abc')
  })

  it('shows live rates, time left and the throughput chart only while the download moves', () => {
    renderPane(withRow(TORRENT, { statusToken: 'downloading', downSpeed: 2048, upSpeed: 1024, etaSeconds: 90 }))
    expect(screen.getByText('2.0 KB/s', { selector: 'b' })).toBeInTheDocument()
    expect(screen.getByText('1.0 KB/s', { selector: 'b' })).toBeInTheDocument()
    expect(screen.getByText(S.throughput)).toBeInTheDocument()
    expect(screen.getByRole('img', { name: /download peak/ })).toBeInTheDocument()
  })

  it('shows no rates and no chart for a paused download', () => {
    renderPane(TORRENT)
    expect(screen.queryByRole('img', { name: /download peak/ })).toBeNull()
    expect(screen.queryByText(S.throughput)).toBeNull()
  })

  it('leaves ↑ out for an HTTP download that sends nothing, and counts its connections', () => {
    const { panel } = renderPane(withRow(HTTP, { downSpeed: 2048 }))
    expect(within(panel).queryByText(en.chart.up, { exact: false })).toBeNull()
    expect(within(panel).getByText(en.detail.details.connections).nextElementSibling).toHaveTextContent('8')
  })

  it('redraws the chart and its peak from the store as samples arrive', () => {
    renderPane(withRow(TORRENT, { statusToken: 'downloading' }))
    expect(screen.getByRole('img', { name: /download peak 0 B\/s/ })).toBeInTheDocument()
    act(() => speedStore.record([{ ...TORRENT.row, downSpeed: 4096 }]))
    expect(screen.getByRole('img', { name: /download peak 4\.0 KB\/s/ })).toBeInTheDocument()
    expect(screen.getByText('Peak 4.0 KB/s')).toBeInTheDocument()
  })

  it('explains a failure in the daemon’s words, and retries, copies or opens more from it', async () => {
    const failed = withRow(TORRENT, { statusToken: 'failed', status: 'Failed', error: '421 too many users' })
    const { props } = renderPane(failed)
    const card = screen.getByRole('group', { name: en.detail.general.failedTitle })
    expect(card).toHaveTextContent('421 too many users')
    await userEvent.click(within(card).getByRole('button', { name: en.common.retry }))
    expect(props.onAction).toHaveBeenCalledWith('t1', 'retry')
    await userEvent.click(within(card).getByRole('button', { name: S.failed.copyDetails }))
    expect(props.onCopy).toHaveBeenCalledWith(expect.stringContaining('421 too many users'))
    await userEvent.click(within(card).getByRole('button', { name: en.detail.moreActions }))
    expect(props.onMore).toHaveBeenCalledWith('t1', expect.objectContaining({ y: expect.any(Number) }))
    expect(screen.getByText(en.detail.general.downloaded)).toBeInTheDocument()
  })

  it('says the server gave no reason, and offers no Retry to a read-only session', () => {
    renderPane(withRow(TORRENT, { statusToken: 'failed', status: 'Failed', error: null }), { canWrite: false })
    const card = screen.getByRole('group', { name: en.detail.general.failedTitle })
    expect(card).toHaveTextContent(en.detail.general.failedNoReason)
    expect(within(card).queryByRole('button', { name: en.common.retry })).toBeNull()
  })

  it('shows a finished download’s size and when, with Play for something streamable', async () => {
    const onStream = vi.fn()
    const done = withRow(TORRENT, { statusToken: 'completed', status: 'Completed', streamable: true, completedAt: 1_700_000_500 })
    const { panel } = renderPane(done, { onStream })
    expect(within(panel).getByText(/^3\.7 GB · finished /)).toBeInTheDocument()
    await userEvent.click(within(panel).getByRole('button', { name: 'Play debian-13.iso' }))
    await userEvent.click(within(panel).getByRole('button', { name: S.finished.play }))
    expect(onStream).toHaveBeenCalledTimes(2)
    expect(within(panel).getByText(en.detail.general.finished)).toBeInTheDocument()
  })

  it('offers no Play for a finished file the browser cannot stream', () => {
    const { panel } = renderPane(withRow(TORRENT, { statusToken: 'completed', status: 'Completed' }))
    expect(within(panel).queryByRole('button', { name: S.finished.play })).toBeNull()
  })

  it('says it is asking for a magnet’s metadata instead of showing 0%', () => {
    const { panel } = renderPane(withRow(TORRENT, { statusToken: 'metadata', status: 'Fetching metadata', totalBytes: null }))
    expect(within(panel).getByRole('status')).toHaveTextContent(S.metadata.title)
    expect(panel.querySelector('.bignum')).toBeNull()
  })
})

describe('Overview · queue controls', () => {
  it('edits the cap, start time and tags, and moves a waiting download', async () => {
    const queue = queueControls()
    const row = { ...TORRENT.row, statusToken: 'queued' as const, status: 'Queued', queuePosition: 2, tags: ['linux'], speedLimit: 1024 * 1024 }
    renderPane({ ...TORRENT, row }, { queue })
    expect(screen.getByText(en.queue.speedLabel).nextElementSibling).toHaveTextContent('1.0 MB/s')
    expect(screen.getByText('#3')).toBeInTheDocument()
    expect(screen.getByText('linux')).toHaveClass('tag')
    const edits = screen.getAllByRole('button', { name: en.queue.edit })
    expect(edits).toHaveLength(3)
    for (const edit of edits) await userEvent.click(edit)
    expect(queue.edit.mock.calls.map(([e]) => e.kind)).toEqual(['speed', 'start', 'tags'])
    await userEvent.click(screen.getByRole('button', { name: en.queue.top }))
    await userEvent.click(screen.getByRole('button', { name: en.queue.bottom }))
    expect(queue.move.mock.calls).toEqual([
      [['t1'], 'top'],
      [['t1'], 'bottom'],
    ])
  })

  it('shows a read-only session the values and no controls', () => {
    renderPane(withRow(TORRENT, { speedLimit: 2048, startAt: 1_800_000_000 }), { canWrite: false, queue: queueControls() })
    expect(screen.getByText(en.queue.speedLabel)).toBeInTheDocument()
    expect(screen.getByText(en.queue.startLabel)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: en.queue.edit })).toBeNull()
  })

  it('leaves the section out when there is nothing to show or change', () => {
    renderPane(TORRENT, { canWrite: false })
    expect(screen.queryByText(en.queue.speedLabel)).toBeNull()
  })
})

describe('Network', () => {
  it('lists an HTTP download’s server facts and counts segments from the list, not connections', async () => {
    const { panel, props } = renderPane(HTTP, { tab: 'network' })
    expect(within(panel).getByText(en.detail.details.server).nextElementSibling).toHaveTextContent('Apache')
    expect(within(panel).getByText(en.detail.details.mime).nextElementSibling).toHaveTextContent('application/x-iso9660-image')
    const segments = within(panel).getByText(en.detail.details.segments).nextElementSibling!
    expect(segments).toHaveTextContent('2')
    expect(segments).not.toHaveTextContent('8')
    await userEvent.click(within(panel).getByRole('button', { name: en.common.copy }))
    expect(props.onCopy).toHaveBeenCalledWith('https://example.org/a.iso')
  })

  it('draws each segment as a bar and lists the connections', () => {
    const { panel } = renderPane(HTTP, { tab: 'network' })
    expect(within(panel).getByRole('progressbar', { name: 'Segment 2' })).toHaveAttribute('aria-valuenow', '50')
    const table = within(panel).getByRole('table')
    expect(within(table).getAllByRole('row')).toHaveLength(3)
    expect(within(table).getByText('1–2 GB')).toBeInTheDocument()
    expect(within(table).queryByText(en.queue.colAdapter)).toBeNull()
    expect(within(panel).getByText('8 connections')).toBeInTheDocument()
  })

  it('adds the Adapter column only when aggregation spreads segments over interfaces', () => {
    const spread: TaskDetail = {
      ...HTTP,
      connections: HTTP.connections.map((c, i) => ({ ...c, adapterLabel: i ? 'Ethernet' : 'Wi-Fi' })),
    }
    const { panel } = renderPane(spread, { tab: 'network' })
    expect(within(panel).getByRole('columnheader', { name: en.queue.colAdapter })).toBeInTheDocument()
    expect(within(panel).getByText('Wi-Fi')).toBeInTheDocument()
  })

  it('says segments appear while downloading when there are none', () => {
    const { panel } = renderPane({ ...HTTP, connections: [] }, { tab: 'network' })
    expect(within(panel).getByText(en.detail.peers.segmentHint)).toBeInTheDocument()
  })

  it('shows a torrent’s hash, swarm and piece map with its legend', () => {
    const pieces = [1, 1, 0.5, 0, 0]
    const { panel } = renderPane({ ...TORRENT, pieces }, { tab: 'network' })
    expect(within(panel).getByText('abc123')).toBeInTheDocument()
    expect(within(panel).getByText('30 connected')).toBeInTheDocument()
    const map = within(panel).getByRole('img', { name: '2 of 5 pieces complete' })
    expect(map.querySelectorAll('rect.have')).toHaveLength(2)
    expect(map.querySelectorAll('rect.partial')).toHaveLength(1)
    expect(map.querySelectorAll('rect.missing')).toHaveLength(2)
    expect(within(panel).getByText('2 complete')).toBeInTheDocument()
  })

  it('switches "download in order" for a single-file torrent', async () => {
    const queue = queueControls()
    const { panel } = renderPane(TORRENT, { tab: 'network', queue })
    const toggle = within(panel).getByRole('switch', { name: en.queue.sequential })
    expect(toggle).toHaveAttribute('aria-checked', 'true')
    expect(toggle).toHaveAccessibleDescription(en.queue.sequentialHint)
    await userEvent.click(toggle)
    expect(queue.setSequential).toHaveBeenCalledWith('t1', false)
  })

  it('states "download in order" as text for a read-only session or a multi-file torrent', () => {
    const { panel } = renderPane(withRow(TORRENT, { multiFile: true }), { tab: 'network', queue: queueControls() })
    expect(within(panel).queryByRole('switch')).toBeNull()
    expect(within(panel).getByText(en.detail.details.sequential).nextElementSibling).toHaveTextContent(en.common.on)
  })

  it('renders the fixture torrent’s trackers', () => {
    const cosmos = sampleTasks().find((t) => t.kind === 'torrent' && t.statusToken === 'downloading')!
    const { panel } = renderPane(sampleDetail(cosmos), { tab: 'network', canWrite: false })
    expect(within(panel).getByText(/^Trackers · \d+$/)).toBeInTheDocument()
    expect(within(panel).getByText(en.queue.trackerError)).toHaveClass('pill', 'bad')
  })
})

describe('Peers', () => {
  const PEERS: TaskDetail = {
    ...TORRENT,
    connections: [
      { id: 'p1', label: '185.21.0.14', detail: 'qBittorrent 5.0', down: 4096, up: 0, progress: 1, adapterId: null, adapterLabel: null },
      { id: 'p2', label: '91.134.0.2', detail: 'peer', down: 0, up: 1024, progress: 0.72, adapterId: null, adapterLabel: null },
    ],
  }

  it('tabulates each peer’s client, share, rates', () => {
    const { panel } = renderPane(PEERS, { tab: 'peers' })
    expect(within(panel).getByText('12 seeds · 30 peers')).toBeInTheDocument()
    const rows = within(panel).getAllByRole('row')
    expect(rows).toHaveLength(3)
    expect(rows[1]).toHaveTextContent('qBittorrent 5.0')
    expect(rows[1]).toHaveTextContent('100%')
    // A client that announced nothing shows a dash, not "peer".
    expect(rows[2]).toHaveTextContent('—')
    expect(rows[2]).toHaveTextContent('72%')
    expect(within(panel).queryByRole('columnheader', { name: en.queue.colAdapter })).toBeNull()
  })

  it('adds the Adapter column when peers are spread over interfaces', () => {
    const spread = { ...PEERS, connections: PEERS.connections.map((c) => ({ ...c, adapterLabel: 'Wi-Fi' })) }
    const { panel } = renderPane(spread, { tab: 'peers' })
    expect(within(panel).getByRole('columnheader', { name: en.queue.colAdapter })).toBeInTheDocument()
  })

  it('says when no peers are connected', () => {
    const { panel } = renderPane(TORRENT, { tab: 'peers' })
    expect(within(panel).getByText(en.detail.peers.none)).toBeInTheDocument()
  })
})

describe('Files', () => {
  it('offers a zip of the finished files and a save link per finished file', () => {
    const detail: TaskDetail = {
      ...withRow(TORRENT, { multiFile: true }),
      files: [
        { id: 0, name: 'Show/a.mkv', size: 10, done: 10, progress: 1, priority: 'normal' },
        { id: 1, name: 'Show/b.mkv', size: 10, done: 2, progress: 0.2, priority: 'normal' },
      ],
    }
    renderPane(detail, { tab: 'files' })
    expect(screen.getByRole('link', { name: en.detail.files.saveFinished_one })).toHaveAttribute('href', '/stream?id=t1&zip=1')
    const save = screen.getByRole('link', { name: 'Save Show/a.mkv to this device' })
    expect(save).toHaveAttribute('href', '/stream?id=t1&file=0')
    expect(save).toHaveAttribute('download', 'a.mkv')
    expect(screen.queryByRole('link', { name: 'Save Show/b.mkv to this device' })).toBeNull()
  })

  it('explains a single-file download, with a save link once it is finished', () => {
    const { panel, } = renderPane(withRow(HTTP, { statusToken: 'completed', status: 'Completed', progress: 1 }), { tab: 'files' })
    expect(within(panel).getByText(en.detail.files.singleFile)).toBeInTheDocument()
    expect(within(panel).getByRole('link', { name: 'Save debian-13.iso to this device' })).toHaveAttribute(
      'href',
      '/stream?id=t1&dl=1',
    )
  })

  it('has no save link for an unfinished single file', () => {
    const { panel } = renderPane(HTTP, { tab: 'files' })
    expect(within(panel).queryByRole('link')).toBeNull()
  })

  it('says the file list waits for a magnet’s metadata', () => {
    const { panel } = renderPane(withRow(TORRENT, { statusToken: 'metadata', status: 'Fetching metadata' }), { tab: 'files' })
    expect(within(panel).getByText(S.files.beforeMetadata)).toBeInTheDocument()
  })
})
