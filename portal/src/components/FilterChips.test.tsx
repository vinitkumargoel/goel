import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import { countFilters } from '../lib/filters'
import type { TaskRow } from '../lib/types'
import { renderWithI18n } from '../test/renderWithI18n'
import { FilterChips } from './FilterChips'

const tasks = [{ statusToken: 'failed', name: 'a', kind: 'http' }, { statusToken: 'downloading', name: 'b', kind: 'http' }] as TaskRow[]

describe('FilterChips', () => {
  it('shows the non-empty filters with counts, the current one pressed', async () => {
    const onFilter = vi.fn()
    renderWithI18n(<FilterChips filter="all" counts={countFilters(tasks)} onFilter={onFilter} />)
    expect(screen.getByRole('button', { name: 'All 2' })).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByRole('button', { name: 'Failed 1' })).toHaveAttribute('aria-pressed', 'false')
    expect(screen.queryByRole('button', { name: /Paused/ })).toBeNull()
    await userEvent.click(screen.getByRole('button', { name: 'Active 1' }))
    expect(onFilter).toHaveBeenCalledWith('active')
  })
})
