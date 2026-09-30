import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import en from '../locales/en.json'
import type { StatusToken, TaskRow } from '../lib/types'
import { renderWithI18n } from '../test/renderWithI18n'
import { BulkBar, eligibleFor } from './BulkBar'

function row(id: string, statusToken: StatusToken): TaskRow {
  return { id, statusToken, source: `https://example.com/${id}` } as TaskRow
}

const SELECTED = [row('a', 'downloading'), row('b', 'paused'), row('c', 'failed'), row('d', 'downloading')]

function renderBar(canWrite = true) {
  const handlers = { onAction: vi.fn(), onCopyLinks: vi.fn(), onRemove: vi.fn(), onClear: vi.fn() }
  renderWithI18n(<BulkBar selected={SELECTED} canWrite={canWrite} {...handlers} />)
  return handlers
}

describe('eligibleFor', () => {
  it('picks the rows the per-row action applies to', () => {
    expect(eligibleFor(SELECTED, 'pause')).toEqual(['a', 'd'])
    expect(eligibleFor(SELECTED, 'resume')).toEqual(['b'])
    expect(eligibleFor(SELECTED, 'retry')).toEqual(['c'])
  })
})

describe('BulkBar', () => {
  it('counts the selection and fans actions out to eligible rows only', async () => {
    const handlers = renderBar()
    expect(screen.getByText('4 selected')).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Pause 2' }))
    expect(handlers.onAction).toHaveBeenCalledWith('pause', ['a', 'd'])
    await userEvent.click(screen.getByRole('button', { name: en.common.remove }))
    expect(handlers.onRemove).toHaveBeenCalledWith(['a', 'b', 'c', 'd'])
  })

  it('copies every selected source link', async () => {
    const handlers = renderBar()
    await userEvent.click(screen.getByRole('button', { name: en.bulk.copyLinks }))
    expect(handlers.onCopyLinks).toHaveBeenCalledWith(SELECTED.map((t) => t.source))
  })

  it('offers a read-only session only Copy links and Clear', () => {
    renderBar(false)
    const names = screen.getAllByRole('button').map((b) => b.getAttribute('aria-label') ?? b.textContent)
    expect(names).toEqual([en.bulk.copyLinks, en.bulk.clear])
  })

  it('works for a single selected row too, where it is the accessible home of the row actions', () => {
    const handlers = { onAction: vi.fn(), onCopyLinks: vi.fn(), onRemove: vi.fn(), onClear: vi.fn() }
    renderWithI18n(<BulkBar selected={[row('a', 'downloading')]} canWrite {...handlers} />)
    expect(screen.getByText('1 selected')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: en.common.pause })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: en.common.copyLink })).toBeInTheDocument()
  })
})
