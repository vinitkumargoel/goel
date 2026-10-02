import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ComponentProps } from 'react'
import { describe, expect, it, vi } from 'vitest'
import { UNSORTED } from '../../lib/sort'
import en from '../../locales/en.json'
import boardEn from '../../locales/en.json'
import { renderWithI18n } from '../../test/renderWithI18n'
import { LibraryTools } from './LibraryTools'

function renderTools(over: Partial<ComponentProps<typeof LibraryTools>> = {}) {
  const h = { onGroup: vi.fn(), onDensity: vi.fn(), onLayout: vi.fn(), onSort: vi.fn() }
  renderWithI18n(
    <LibraryTools count={3} group="none" density="comfortable" layout="board" sort={UNSORTED} {...h} {...over} />,
  )
  return h
}

async function openView() {
  await userEvent.click(screen.getByRole('button', { name: boardEn.board.tools.viewOptions }))
}

describe('LibraryTools', () => {
  it('counts what shows', () => {
    renderTools()
    expect(screen.getByText('3 downloads')).toBeInTheDocument()
  })

  it('switches between Board and Table', async () => {
    const h = renderTools()
    const layout = screen.getByRole('radiogroup', { name: en.workflow.library.layout })
    expect(screen.getByRole('radio', { name: en.workflow.library.board })).toHaveAttribute('aria-checked', 'true')
    await userEvent.click(screen.getByRole('radio', { name: en.workflow.library.table }))
    expect(h.onLayout).toHaveBeenCalledWith('table')
    expect(layout).toBeInTheDocument()
  })

  it('groups and sets the density from the View popover', async () => {
    const h = renderTools()
    await openView()
    await userEvent.selectOptions(screen.getByRole('combobox', { name: en.workflow.library.groupBy }), 'host')
    expect(h.onGroup).toHaveBeenCalledWith('host')
    await userEvent.click(screen.getByRole('radio', { name: en.workflow.library.compact }))
    expect(h.onDensity).toHaveBeenCalledWith('compact')
  })

  it('sorts from the View popover, the unsorted state a disabled placeholder', async () => {
    const h = renderTools()
    await openView()
    const picker = screen.getByRole('combobox', { name: en.library.sortBy })
    expect(picker).toHaveValue('')
    expect(screen.getByRole('option', { name: en.library.sortNone })).toBeDisabled()
    await userEvent.selectOptions(picker, 'size')
    expect(h.onSort).toHaveBeenCalledWith('size')
  })

  it('flips a stored sort from the button named by its state', async () => {
    const h = renderTools({ sort: { key: 'eta', dir: 'asc' } })
    await openView()
    expect(screen.getByRole('combobox', { name: en.library.sortBy })).toHaveValue('eta')
    await userEvent.click(screen.getByRole('button', { name: 'ETA, sorted ascending' }))
    expect(h.onSort).toHaveBeenLastCalledWith('eta')
  })
})
