import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import en from '../locales/en.json'
import type { FilterCounts } from '../lib/filters'
import type { StatusToken, TaskRow } from '../lib/types'
import { renderWithI18n } from '../test/renderWithI18n'
import { QueueOverview } from './QueueOverview'

function row(id: string, statusToken: StatusToken, over: Partial<TaskRow> = {}): TaskRow {
  return {
    id,
    name: `${id}.iso`,
    status: statusToken,
    statusToken,
    kind: 'http',
    progress: 0,
    downSpeed: 0,
    upSpeed: 0,
    totalBytes: 1024 ** 3,
    doneBytes: 0,
    upBytes: 0,
    ratio: 0,
    seeds: null,
    conns: 0,
    addedAt: 0,
    etaSeconds: null,
    error: null,
    source: '',
    multiFile: false,
    fileCount: 1,
    streamable: false,
    ...over,
  }
}

const COUNTS: FilterCounts = {
  all: 4,
  active: 1,
  queued: 1,
  paused: 0,
  completed: 1,
  seeding: 0,
  failed: 1,
  video: 0,
  audio: 0,
  image: 0,
  iso: 4,
  archive: 0,
  app: 0,
  doc: 0,
  other: 0,
}

function renderOverview(tasks: TaskRow[], over: Partial<Parameters<typeof QueueOverview>[0]> = {}) {
  const props = {
    tasks,
    counts: COUNTS,
    down: 0,
    up: 0,
    bandwidth: null,
    autoHide: false,
    onAutoHide: vi.fn(),
    onFilter: vi.fn(),
    ...over,
  }
  renderWithI18n(<QueueOverview {...props} />)
}

describe('QueueOverview', () => {
  it('turns each tile into a shortcut to its filter, and flags failures', async () => {
    const onFilter = vi.fn()
    renderOverview([], { onFilter })
    const failed = screen.getByRole('button', { name: 'Show 1 failed download' })
    expect(failed).toHaveClass('bad')
    await userEvent.click(failed)
    await userEvent.click(screen.getByRole('button', { name: 'Show 1 queued download' }))
    expect(onFilter.mock.calls).toEqual([['failed'], ['queued']])
  })

  it('shows what is left and when it will be done, leaving out unknown sizes', () => {
    renderOverview([
      row('a', 'downloading', { downSpeed: 1024 ** 2, doneBytes: 512 * 1024 ** 2 }),
      row('b', 'queued'),
      row('c', 'metadata', { totalBytes: null }),
      row('d', 'paused'),
    ])
    expect(screen.getByText(/^1\.5 GB · done ≈ /)).toBeInTheDocument()
    expect(screen.getByText('1 download of unknown size isn’t counted yet.')).toBeInTheDocument()
  })

  it('says so when nothing is moving or nothing is left', () => {
    renderOverview([row('a', 'queued')])
    expect(screen.getByText(`1.0 GB · ${en.overview.stalled}`)).toBeInTheDocument()
  })

  it('says there is nothing left once the queue is empty', () => {
    renderOverview([row('a', 'completed')])
    expect(screen.getByText(en.overview.nothingLeft)).toBeInTheDocument()
  })

  it('reports the auto-hide toggle', async () => {
    const onAutoHide = vi.fn()
    renderOverview([], { onAutoHide })
    await userEvent.click(screen.getByRole('checkbox', { name: en.overview.autoHide }))
    expect(onAutoHide).toHaveBeenCalledWith(true)
  })
})
