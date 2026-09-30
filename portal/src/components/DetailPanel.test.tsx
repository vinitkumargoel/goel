import { act, fireEvent, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { renderWithI18n } from '../test/renderWithI18n'
import en from '../locales/en.json'
import type { TaskDetail, TaskRow } from '../lib/types'
import type { SpeedSample } from '../lib/speedHistory'
import { speedStore } from '../lib/speedStore'
import { DetailPanel } from './DetailPanel'
import { DETAIL_TABS, type DetailTab } from './DetailPanes'

const ROW: TaskRow = {
  id: 't1',
  name: 'debian-13.iso',
  status: 'Paused',
  statusToken: 'paused',
  kind: 'torrent',
  progress: 0.5,
  downSpeed: 0,
  upSpeed: 0,
  totalBytes: 4_000_000_000,
  doneBytes: 2_000_000_000,
  upBytes: 100_000,
  ratio: 0.05,
  seeds: 12,
  conns: 30,
  addedAt: 1_700_000_000,
  etaSeconds: null,
  error: null,
  source: 'magnet:?xt=urn:btih:abc',
  multiFile: true,
  fileCount: 3,
  streamable: false,
}

const DETAIL: TaskDetail = {
  row: ROW,
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

afterEach(() => {
  vi.unstubAllGlobals()
  speedStore.reset()
})

/** Pretends the viewport is a phone (≤680px). */
function phoneViewport() {
  vi.stubGlobal('matchMedia', (query: string) => ({
    matches: query.includes('max-width: 680px'),
    media: query,
    addEventListener: () => {},
    removeEventListener: () => {},
  }))
}

interface PanelOptions {
  onClose?: () => void
  onAction?: () => void
  tab?: DetailTab
  samples?: SpeedSample[]
}

/** `samples` go through the app's speed store, where the Progress chart reads them. */
function renderPanel(
  detail: TaskDetail | null,
  { onClose = vi.fn(), onAction = vi.fn(), tab = 'general', samples = [] }: PanelOptions = {},
) {
  for (const s of samples) {
    speedStore.record([{ ...ROW, downSpeed: s.down, upSpeed: s.up }])
  }
  return renderWithI18n(
    <DetailPanel
      detail={detail}
      open
      tab={tab}
      canWrite
      onTab={vi.fn()}
      onClose={onClose}
      onAction={onAction}
      onRemove={vi.fn()}
      onMore={vi.fn()}
      onCopy={vi.fn()}
      onToggleFile={vi.fn()}
      onCyclePriority={vi.fn()}
    />,
  )
}

const HTTP: TaskDetail = {
  ...DETAIL,
  row: { ...ROW, kind: 'http', multiFile: false, fileCount: 1, statusToken: 'downloading', status: 'Downloading' },
  connections: [
    { id: 's1', label: 'Segment 1', detail: '0–1 GB', down: 1, up: 0, progress: 0.5, adapterId: null, adapterLabel: null },
    { id: 's2', label: 'Segment 2', detail: '1–2 GB', down: 1, up: 0, progress: 0.5, adapterId: null, adapterLabel: null },
  ],
}

describe('DetailPanel', () => {
  it('renders the empty state from the catalogue', () => {
    renderPanel(null)
    expect(screen.getByText(en.detail.emptyTitle)).toBeInTheDocument()
    expect(screen.getByText(en.detail.emptyBody)).toBeInTheDocument()
  })

  it('renders every tab label from the catalogue, not a capitalized token', () => {
    renderPanel(DETAIL)
    for (const tab of DETAIL_TABS) {
      expect(screen.getByRole('tab', { name: en.detail.tabs[tab] })).toBeInTheDocument()
    }
  })

  it('names the last tab Connections unless the download is a torrent', () => {
    renderPanel(HTTP)
    expect(screen.getByRole('tab', { name: en.detail.tabs.connections })).toBeInTheDocument()
    expect(screen.queryByRole('tab', { name: en.detail.tabs.peers })).toBeNull()
  })

  it('exposes the sections as a tablist with the current tab selected', () => {
    renderPanel(DETAIL)
    expect(screen.getByRole('tablist', { name: en.detail.tabsLabel })).toBeInTheDocument()
    const tabs = screen.getAllByRole('tab')
    expect(tabs).toHaveLength(DETAIL_TABS.length)
    const general = screen.getByRole('tab', { name: en.detail.tabs.general })
    expect(general).toHaveAttribute('aria-selected', 'true')
    expect(general).toHaveAttribute('tabindex', '0')
    expect(screen.getByRole('tabpanel')).toHaveAttribute('aria-labelledby', general.id)
  })

  it('moves to the next tab with ArrowRight', async () => {
    const onTab = vi.fn()
    renderWithI18n(
      <DetailPanel
        detail={DETAIL}
        open
        tab="general"
        canWrite
        onTab={onTab}
        onClose={vi.fn()}
        onAction={vi.fn()}
        onRemove={vi.fn()}
        onMore={vi.fn()}
        onCopy={vi.fn()}
        onToggleFile={vi.fn()}
        onCyclePriority={vi.fn()}
      />,
    )
    screen.getByRole('tab', { name: en.detail.tabs.general }).focus()
    await userEvent.keyboard('{ArrowRight}')
    expect(onTab).toHaveBeenCalledWith('details')
  })

  it('offers a More button that opens the row menu', async () => {
    const onMore = vi.fn()
    renderWithI18n(
      <DetailPanel
        detail={DETAIL}
        open
        tab="general"
        canWrite
        onTab={vi.fn()}
        onClose={vi.fn()}
        onAction={vi.fn()}
        onRemove={vi.fn()}
        onMore={onMore}
        onCopy={vi.fn()}
        onToggleFile={vi.fn()}
        onCyclePriority={vi.fn()}
      />,
    )
    const more = screen.getByRole('button', { name: en.detail.moreActions })
    expect(more).toHaveAttribute('aria-haspopup', 'menu')
    await userEvent.click(more)
    expect(onMore).toHaveBeenCalledWith('t1', expect.objectContaining({ x: expect.any(Number) }))
  })

  it('translates the close-panel accessible name', () => {
    renderPanel(DETAIL)
    expect(screen.getByRole('button', { name: en.detail.closePanel })).toBeInTheDocument()
  })

  it('offers Resume for a paused task', () => {
    renderPanel(DETAIL)
    expect(screen.getByRole('button', { name: en.common.resume })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: en.common.copyLink })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: en.common.remove })).toBeInTheDocument()
  })

  it('renders the general pane key labels from the catalogue', () => {
    renderPanel(DETAIL)
    expect(screen.getByText(en.detail.general.savePath)).toBeInTheDocument()
    expect(screen.getByText(en.detail.general.added)).toBeInTheDocument()
    expect(screen.getByText(en.detail.general.protocol)).toBeInTheDocument()
    expect(screen.getByText('12 seeds · 30 peers')).toBeInTheDocument()
  })

  it('leads General with live rates and a compact chart only while the download moves', () => {
    renderPanel({ ...DETAIL, row: { ...ROW, statusToken: 'downloading', downSpeed: 2048, upSpeed: 1024 } })
    expect(screen.getByText('2.0 KB/s')).toBeInTheDocument()
    expect(screen.getByText('1.0 KB/s')).toBeInTheDocument()
    expect(screen.getByRole('img', { name: /download peak/ })).toBeInTheDocument()
  })

  it('shows no rates for a paused download', () => {
    renderPanel(DETAIL)
    expect(screen.queryByRole('img', { name: /download peak/ })).toBeNull()
  })

  it('explains a failure and retries it from the card', async () => {
    const onAction = vi.fn()
    renderPanel(
      { ...DETAIL, row: { ...ROW, statusToken: 'failed', status: 'Failed', error: '421 too many users' } },
      { onAction },
    )
    const card = screen.getByRole('group', { name: en.detail.general.failedTitle })
    expect(card).toHaveTextContent('421 too many users')
    const retries = screen.getAllByRole('button', { name: en.common.retry })
    await userEvent.click(retries[retries.length - 1]!)
    expect(onAction).toHaveBeenCalledWith('t1', 'retry')
  })

  it('counts segments from the segment list, not the connection count', () => {
    renderPanel({ ...HTTP, row: { ...HTTP.row, conns: 8 } }, { tab: 'details' })
    const segments = screen.getByText(en.detail.details.segments).parentElement!
    expect(segments).toHaveTextContent('2')
    expect(segments).not.toHaveTextContent('8')
  })

  it('offers a zip of the finished files and a save link per finished file', () => {
    renderPanel(
      {
        ...DETAIL,
        files: [
          { id: 0, name: 'Show/a.mkv', size: 10, done: 10, progress: 1, priority: 'normal' },
          { id: 1, name: 'Show/b.mkv', size: 10, done: 2, progress: 0.2, priority: 'normal' },
        ],
      },
      { tab: 'files' },
    )
    expect(screen.getByRole('link', { name: en.detail.downloadAll })).toHaveAttribute('href', '/stream?id=t1&zip=1')
    const save = screen.getByRole('link', { name: 'Save Show/a.mkv to this device' })
    expect(save).toHaveAttribute('href', '/stream?id=t1&file=0')
    expect(save).toHaveAttribute('download', 'a.mkv')
    expect(screen.queryByRole('link', { name: 'Save Show/b.mkv to this device' })).toBeNull()
  })

  it('draws the live speed chart atop the Progress tab', () => {
    renderPanel(DETAIL, { tab: 'progress', samples: [{ down: 2048, up: 0 }] })
    expect(screen.getByRole('img', { name: /download peak 2\.0 KB\/s/ })).toBeInTheDocument()
  })

  it('redraws the chart from the store as samples arrive', () => {
    renderPanel(DETAIL, { tab: 'progress' })
    expect(screen.getByRole('img', { name: /download peak 0 B\/s/ })).toBeInTheDocument()
    act(() => speedStore.record([{ ...ROW, downSpeed: 4096 }]))
    expect(screen.getByRole('img', { name: /download peak 4\.0 KB\/s/ })).toBeInTheDocument()
  })

  it('stays a plain complementary panel on wide screens', () => {
    renderPanel(DETAIL)
    expect(screen.queryByRole('dialog')).toBeNull()
  })

  it('becomes a modal bottom sheet on phones: focus inside, Escape closes', async () => {
    phoneViewport()
    const onClose = vi.fn()
    renderPanel(DETAIL, { onClose })
    const sheet = screen.getByRole('dialog', { name: en.detail.label })
    expect(sheet).toHaveAttribute('aria-modal', 'true')
    expect(screen.getByRole('button', { name: en.detail.closePanel })).toHaveFocus()
    await userEvent.keyboard('{Escape}')
    expect(onClose).toHaveBeenCalled()
  })

  it('dismisses the sheet when its grabber is dragged down far enough', () => {
    phoneViewport()
    const onClose = vi.fn()
    const { container } = renderPanel(DETAIL, { onClose })
    const grabber = container.querySelector<HTMLElement>('.grabber')!
    fireEvent.pointerDown(grabber, { clientY: 100, pointerId: 1 })
    fireEvent.pointerMove(grabber, { clientY: 140, pointerId: 1 })
    fireEvent.pointerUp(grabber, { clientY: 140, pointerId: 1 })
    expect(onClose).not.toHaveBeenCalled()
    fireEvent.pointerDown(grabber, { clientY: 100, pointerId: 1 })
    fireEvent.pointerUp(grabber, { clientY: 260, pointerId: 1 })
    expect(onClose).toHaveBeenCalled()
  })
})
