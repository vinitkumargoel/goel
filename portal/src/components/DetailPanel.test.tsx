import { fireEvent, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { renderWithI18n } from '../test/renderWithI18n'
import en from '../locales/en.json'
import type { TaskDetail, TaskRow } from '../lib/types'
import type { SpeedSample } from '../lib/speedHistory'
import { DetailPanel } from './DetailPanel'
import type { DetailTab } from './DetailPanes'

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
  tab?: DetailTab
  samples?: SpeedSample[]
}

function renderPanel(detail: TaskDetail | null, { onClose = vi.fn(), tab = 'general', samples }: PanelOptions = {}) {
  return renderWithI18n(
    <DetailPanel
      detail={detail}
      open
      tab={tab}
      canWrite
      samples={samples}
      onTab={vi.fn()}
      onClose={onClose}
      onAction={vi.fn()}
      onRemove={vi.fn()}
      onMore={vi.fn()}
      onCopy={vi.fn()}
      onToggleFile={vi.fn()}
      onCyclePriority={vi.fn()}
    />,
  )
}

describe('DetailPanel', () => {
  it('renders the empty state from the catalogue', () => {
    renderPanel(null)
    expect(screen.getByText(en.detail.emptyTitle)).toBeInTheDocument()
    expect(screen.getByText(en.detail.emptyBody)).toBeInTheDocument()
  })

  it('renders every tab label from the catalogue, not a capitalized token', () => {
    renderPanel(DETAIL)
    for (const label of Object.values(en.detail.tabs)) {
      expect(screen.getByText(label)).toBeInTheDocument()
    }
  })

  it('exposes the sections as a tablist with the current tab selected', () => {
    renderPanel(DETAIL)
    expect(screen.getByRole('tablist', { name: en.detail.tabsLabel })).toBeInTheDocument()
    const tabs = screen.getAllByRole('tab')
    expect(tabs).toHaveLength(Object.keys(en.detail.tabs).length)
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
    expect(screen.getByText(en.detail.general.downloaded)).toBeInTheDocument()
    expect(screen.getByText(en.detail.general.protocol)).toBeInTheDocument()
  })

  it('keeps the two speed rates separated by non-breaking space', () => {
    const { container } = renderPanel(DETAIL)
    // U+00A0, not a plain space: HTML would collapse the latter and merge the rates.
    expect(container.textContent).toContain('\u00a0\u00a0')
  })

  it('draws the live speed chart atop the Progress tab', () => {
    renderPanel(DETAIL, { tab: 'progress', samples: [{ down: 2048, up: 0 }] })
    expect(screen.getByRole('img', { name: /download peak 2\.0 KB\/s/ })).toBeInTheDocument()
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
