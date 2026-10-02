import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import { countFilters } from '../../lib/filters'
import en from '../../locales/en.json'
import boardEn from '../../locales/en.json'
import { makeTask } from '../../test/makeTask'
import { renderWithI18n } from '../../test/renderWithI18n'
import type { MenuItem, MenuState } from '../ui/Menu'
import { FilterChips } from './FilterChips'

const tasks = [
  makeTask('a', { statusToken: 'failed', name: 'a.mkv' }),
  makeTask('b', { statusToken: 'downloading', name: 'b.iso' }),
  makeTask('c', { statusToken: 'completed', name: 'c.iso' }),
]
const counts = countFilters(tasks)

describe('FilterChips', () => {
  it('shows the non-empty filters with counts, the current one pressed', async () => {
    const onFilter = vi.fn()
    renderWithI18n(<FilterChips filter="all" counts={counts} onFilter={onFilter} />)
    expect(screen.getByRole('group', { name: en.workflow.chips.label })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'All 3' })).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByRole('button', { name: 'Failed 1' })).toHaveAttribute('aria-pressed', 'false')
    expect(screen.getByRole('button', { name: 'Failed 1' })).toHaveClass('bad')
    expect(screen.getByRole('button', { name: `${en.workflow.chips.done} 1` })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Paused/ })).toBeNull()
    await userEvent.click(screen.getByRole('button', { name: 'Active 1' }))
    expect(onFilter).toHaveBeenCalledWith('active')
  })

  it('keeps the current filter even when it is empty', () => {
    renderWithI18n(<FilterChips filter="paused" counts={counts} onFilter={vi.fn()} />)
    expect(screen.getByRole('button', { name: 'Paused 0' })).toHaveAttribute('aria-pressed', 'true')
  })

  it('opens a Type menu of the types present, the current one checked', async () => {
    const openMenu = vi.fn<(m: MenuState) => void>()
    const onFilter = vi.fn()
    renderWithI18n(<FilterChips filter="iso" counts={counts} onFilter={onFilter} openMenu={openMenu} />)
    const chip = screen.getByRole('button', { name: en.fileType.iso })
    expect(chip).toHaveAttribute('aria-haspopup', 'menu')
    expect(chip).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByRole('button', { name: 'All 3' })).toHaveAttribute('aria-pressed', 'false')
    await userEvent.click(chip)
    const menu = openMenu.mock.calls[0]![0]
    const items = menu.entries.filter((e): e is MenuItem => 'action' in e)
    expect(items.map((i) => i.label)).toEqual([boardEn.board.chips.allTypes, en.fileType.video, en.fileType.iso])
    expect(items.find((i) => i.checked)?.label).toBe(en.fileType.iso)
    items[1]!.action()
    expect(onFilter).toHaveBeenCalledWith('video')
    items[0]!.action()
    expect(onFilter).toHaveBeenLastCalledWith('all')
  })

  it('offers a Tags menu only when there are tags', async () => {
    const openMenu = vi.fn<(m: MenuState) => void>()
    const onTag = vi.fn()
    const { rerender } = renderWithI18n(<FilterChips filter="all" counts={counts} onFilter={vi.fn()} openMenu={openMenu} />)
    expect(screen.queryByRole('button', { name: boardEn.board.chips.tags })).toBeNull()
    rerender(
      <FilterChips
        filter="all"
        counts={counts}
        onFilter={vi.fn()}
        openMenu={openMenu}
        tags={[{ tag: 'linux', count: 2 }, { tag: 'work', count: 1 }]}
        activeTag="linux"
        onTag={onTag}
      />,
    )
    const chip = screen.getByRole('button', { name: 'linux' })
    expect(chip).toHaveAttribute('aria-pressed', 'true')
    // A tag narrows "All", so All is no longer the pressed chip.
    expect(screen.getByRole('button', { name: 'All 3' })).toHaveAttribute('aria-pressed', 'false')
    await userEvent.click(chip)
    const items = openMenu.mock.calls[0]![0].entries as MenuItem[]
    expect(items.map((i) => [i.label, i.checked])).toEqual([
      ['linux', true],
      ['work', false],
    ])
    items[1]!.action()
    expect(onTag).toHaveBeenCalledWith('work')
  })
})
