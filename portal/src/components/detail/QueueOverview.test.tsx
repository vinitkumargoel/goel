import { act, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { sampleBandwidth } from '../../dev/fixtures'
import en from '../../locales/en.json'
import sheet from '../../locales/en.json'
import { countFilters, type FilterCounts } from '../../lib/filters'
import { speedStore } from '../../lib/speedStore'
import type { StatusToken, TaskRow } from '../../lib/types'
import { makeTask } from '../../test/makeTask'
import { renderWithI18n } from '../../test/renderWithI18n'
import { QueueOverview, queueFraction } from './QueueOverview'

const GB = 1024 ** 3

function row(id: string, statusToken: StatusToken, over: Partial<TaskRow> = {}): TaskRow {
  return makeTask(id, { status: statusToken, statusToken, totalBytes: GB, ...over })
}

const COUNTS: FilterCounts = { ...countFilters([]), all: 4, active: 1, queued: 1, completed: 1, failed: 1, iso: 4 }

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
  return props
}

afterEach(() => speedStore.reset())

describe('QueueOverview', () => {
  it('names itself and states the combined rates', () => {
    renderOverview([], { down: 2048, up: 1024 })
    expect(screen.getByRole('region', { name: en.overview.title })).toBeInTheDocument()
    expect(screen.getByText('Download 2.0 KB/s, upload 1.0 KB/s')).toBeInTheDocument()
  })

  it('turns each tile into a shortcut to its filter, and flags failures', async () => {
    const onFilter = vi.fn()
    renderOverview([], { onFilter })
    const failed = screen.getByRole('button', { name: 'Show 1 failed download' })
    expect(failed).toHaveClass('bad')
    expect(failed).toHaveTextContent(`${sheet.sheet.overview.tile.failed} · ${sheet.sheet.overview.failedHint}`)
    await userEvent.click(failed)
    await userEvent.click(screen.getByRole('button', { name: 'Show 1 queued download' }))
    await userEvent.click(screen.getByRole('button', { name: 'Show 1 active download' }))
    await userEvent.click(screen.getByRole('button', { name: 'Show 1 completed download' }))
    expect(onFilter.mock.calls).toEqual([['failed'], ['queued'], ['active'], ['completed']])
  })

  it('does not flag the failed tile when nothing failed', () => {
    renderOverview([], { counts: { ...COUNTS, failed: 0 } })
    const failed = screen.getByRole('button', { name: 'Show 0 failed downloads' })
    expect(failed).not.toHaveClass('bad')
    expect(failed).not.toHaveTextContent(sheet.sheet.overview.failedHint)
  })

  it('shows what is left and when it will be done, leaving out unknown sizes', () => {
    renderOverview([
      row('a', 'downloading', { downSpeed: 1024 ** 2, doneBytes: 512 * 1024 ** 2 }),
      row('b', 'queued'),
      row('c', 'metadata', { totalBytes: null }),
      row('d', 'paused'),
    ])
    expect(screen.getByText('1.5 GB')).toBeInTheDocument()
    expect(screen.getByText(/^done ≈ /)).toBeInTheDocument()
    expect(screen.getByText('1 download of unknown size isn’t counted yet.')).toBeInTheDocument()
    expect(screen.getByRole('progressbar', { name: '25% of what’s queued is downloaded' })).toHaveAttribute(
      'aria-valuenow',
      '25',
    )
  })

  it('says so when nothing is moving', () => {
    renderOverview([row('a', 'queued')])
    expect(screen.getByText('1.0 GB')).toBeInTheDocument()
    expect(screen.getByText(en.overview.stalled)).toBeInTheDocument()
  })

  it('says there is nothing left once the queue is empty, with no arc', () => {
    renderOverview([row('a', 'completed')])
    expect(screen.getByText(en.overview.nothingLeft)).toBeInTheDocument()
    expect(screen.queryByRole('progressbar')).toBeNull()
  })

  it('draws the last minute of the whole queue', () => {
    renderOverview([])
    expect(screen.getByText(sheet.sheet.overview.chart)).toBeInTheDocument()
    act(() => speedStore.record([row('a', 'downloading', { downSpeed: 4096 })]))
    expect(screen.getByRole('img', { name: /download peak 4\.0 KB\/s/ })).toBeInTheDocument()
  })

  it('names the bandwidth profile in force', () => {
    renderOverview([], { bandwidth: sampleBandwidth() })
    expect(screen.getByText(en.overview.bandwidth).nextElementSibling).toHaveTextContent(/^Medium · /)
  })

  it('says there is no limit while limits are off', () => {
    renderOverview([], { bandwidth: { ...sampleBandwidth(), enabled: false } })
    expect(screen.getByText(en.overview.bandwidth).nextElementSibling).toHaveTextContent(en.statusbar.unlimited)
  })

  it('reports the auto-hide switch', async () => {
    const onAutoHide = vi.fn()
    renderOverview([], { onAutoHide })
    const toggle = screen.getByRole('switch', { name: en.overview.autoHide })
    expect(toggle).toHaveAttribute('aria-checked', 'false')
    await userEvent.click(toggle)
    expect(onAutoHide).toHaveBeenCalledWith(true)
  })
})

describe('queueFraction', () => {
  it('measures done over total across pending downloads of known size', () => {
    expect(queueFraction([])).toBeNull()
    expect(queueFraction([row('a', 'completed', { doneBytes: GB })])).toBeNull()
    expect(
      queueFraction([
        row('a', 'downloading', { doneBytes: GB / 2 }),
        row('b', 'queued'),
        row('c', 'metadata', { totalBytes: null }),
        row('d', 'failed', { doneBytes: GB }),
      ]),
    ).toBe(0.25)
  })
})
