import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import type { StatusToken, TaskRow } from '../../lib/types'
import en from '../../locales/en.json'
import { makeTask } from '../../test/makeTask'
import { renderWithI18n } from '../../test/renderWithI18n'
import { BulkBar, eligibleFor } from './BulkBar'

function row(id: string, statusToken: StatusToken): TaskRow {
  return makeTask(id, { statusToken, source: `https://example.com/${id}` })
}

const SELECTED = [row('a', 'downloading'), row('b', 'paused'), row('c', 'failed'), row('d', 'downloading')]

function renderBar(canWrite = true, extra: { onDone?: () => void } = {}) {
  const handlers = { onAction: vi.fn(), onCopyLinks: vi.fn(), onRemove: vi.fn(), onClear: vi.fn() }
  renderWithI18n(<BulkBar selected={SELECTED} canWrite={canWrite} {...handlers} {...extra} />)
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
  it('is a labelled toolbar that counts the selection politely', () => {
    renderBar()
    expect(screen.getByRole('toolbar', { name: en.bulk.toolbar })).toBeInTheDocument()
    expect(screen.getByText('4 selected')).toHaveAttribute('aria-live', 'polite')
  })

  it('fans actions out to eligible rows only', async () => {
    const handlers = renderBar()
    await userEvent.click(screen.getByRole('button', { name: 'Pause 2' }))
    expect(handlers.onAction).toHaveBeenCalledWith('pause', ['a', 'd'])
    await userEvent.click(screen.getByRole('button', { name: en.bulk.resume_one }))
    expect(handlers.onAction).toHaveBeenCalledWith('resume', ['b'])
    await userEvent.click(screen.getByRole('button', { name: en.bulk.retry_one }))
    expect(handlers.onAction).toHaveBeenCalledWith('retry', ['c'])
    await userEvent.click(screen.getByRole('button', { name: en.common.remove }))
    expect(handlers.onRemove).toHaveBeenCalledWith(['a', 'b', 'c', 'd'])
    await userEvent.click(screen.getByRole('button', { name: en.bulk.clear }))
    expect(handlers.onClear).toHaveBeenCalled()
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

  it('ends select mode with Done instead of the clear button', async () => {
    const onDone = vi.fn()
    renderBar(true, { onDone })
    expect(screen.queryByRole('button', { name: en.bulk.clear })).toBeNull()
    await userEvent.click(screen.getByRole('button', { name: en.workflow.library.done }))
    expect(onDone).toHaveBeenCalled()
  })

  it('works for a single selected row too, where it is the accessible home of the row actions', () => {
    const handlers = { onAction: vi.fn(), onCopyLinks: vi.fn(), onRemove: vi.fn(), onClear: vi.fn() }
    renderWithI18n(<BulkBar selected={[row('a', 'downloading')]} canWrite {...handlers} />)
    expect(screen.getByText('1 selected')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: en.common.pause })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: en.common.copyLink })).toBeInTheDocument()
  })
})
