import { fireEvent, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import type { PaletteCommand } from '../lib/palette'
import { renderWithI18n } from '../test/renderWithI18n'
import { CommandPalette } from './CommandPalette'

const commands = (): PaletteCommand[] => [
  { id: 'add', group: 'add', label: 'Add download', keys: ['N'], run: vi.fn() },
  { id: 't1', group: 'downloads', label: 'ubuntu.iso', run: vi.fn() },
  { id: 'history', group: 'view', label: 'Go to History', keys: ['G', 'H'], run: vi.fn() },
]

describe('CommandPalette', () => {
  it('is a combobox over a grouped listbox, with the first option active', () => {
    renderWithI18n(<CommandPalette commands={commands()} onClose={() => {}} />)
    const box = screen.getByRole('combobox', { name: 'Command palette' })
    expect(box).toHaveFocus()
    expect(screen.getByRole('group', { name: 'Add' })).toBeInTheDocument()
    const first = screen.getByRole('option', { name: /Add download/ })
    expect(first).toHaveAttribute('aria-selected', 'true')
    expect(box).toHaveAttribute('aria-activedescendant', first.id)
    // Downloads only show once something is typed.
    expect(screen.queryByRole('option', { name: 'ubuntu.iso' })).toBeNull()
  })

  it('filters as you type, moves with the arrows and runs with Enter', async () => {
    const list = commands()
    const onClose = vi.fn()
    renderWithI18n(<CommandPalette commands={list} onClose={onClose} />)
    await userEvent.keyboard('o')
    expect(screen.getByRole('option', { name: 'ubuntu.iso' })).toBeInTheDocument()
    await userEvent.keyboard('{ArrowDown}{Enter}')
    expect(onClose).toHaveBeenCalled()
    await vi.waitFor(() => {
      const ran = list.filter((c) => (c.run as ReturnType<typeof vi.fn>).mock.calls.length > 0)
      expect(ran).toHaveLength(1)
    })
  })

  it('runs the command only after closing, so a layer it opens is not popped with the palette', async () => {
    const list = commands()
    const order: string[] = []
    const onClose = vi.fn(() => order.push('close'))
    ;(list[0]!.run as ReturnType<typeof vi.fn>).mockImplementation(() => order.push('run'))
    renderWithI18n(<CommandPalette commands={list} onClose={onClose} />)
    // A synchronous key event: the command must not run inside the same handler as the close.
    fireEvent.keyDown(screen.getByRole('combobox'), { key: 'Enter' })
    expect(order).toEqual(['close'])
    await vi.waitFor(() => expect(order).toEqual(['close', 'run']))
  })

  it('says when nothing matches', async () => {
    renderWithI18n(<CommandPalette commands={commands()} onClose={() => {}} />)
    await userEvent.keyboard('zzzz')
    expect(screen.getByText('Nothing matches “zzzz”')).toBeInTheDocument()
  })

  it('closes on Escape', async () => {
    const onClose = vi.fn()
    renderWithI18n(<CommandPalette commands={commands()} onClose={onClose} />)
    await userEvent.keyboard('{Escape}')
    expect(onClose).toHaveBeenCalled()
  })
})
