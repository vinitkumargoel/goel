import { screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import { renderWithI18n } from '../test/renderWithI18n'
import en from '../locales/en.json'
import type { TaskDetail, TaskRow } from '../lib/types'
import { DetailPanel } from './DetailPanel'

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

function renderPanel(detail: TaskDetail | null) {
  return renderWithI18n(
    <DetailPanel
      detail={detail}
      open
      tab="general"
      canWrite
      onTab={vi.fn()}
      onClose={vi.fn()}
      onAction={vi.fn()}
      onRemove={vi.fn()}
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
})
