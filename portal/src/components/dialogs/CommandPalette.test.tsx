import { fireEvent, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import type { PaletteCommand } from '../../lib/palette'
import { renderWithI18n } from '../../test/renderWithI18n'
import { CommandPalette } from './CommandPalette'
import { commandIcon, highlight } from './paletteParts'

const commands = (): PaletteCommand[] => [
  { id: 'add', group: 'add', label: 'Add download', keys: ['N'], run: vi.fn() },
  { id: 't1', group: 'downloads', label: 'ubuntu.iso', run: vi.fn() },
  { id: 'history', group: 'view', label: 'Go to History', keys: ['G', 'H'], run: vi.fn() },
]

const ran = (list: PaletteCommand[]) => list.filter((c) => (c.run as ReturnType<typeof vi.fn>).mock.calls.length > 0)

describe('CommandPalette', () => {
  it('is a combobox over a grouped listbox, with the first option active', () => {
    renderWithI18n(<CommandPalette commands={commands()} onClose={() => {}} />)
    expect(screen.getByRole('dialog', { name: 'Command palette' })).toHaveAttribute('aria-modal', 'true')
    const box = screen.getByRole('combobox', { name: 'Command palette' })
    expect(box).toHaveFocus()
    expect(box).toHaveAttribute('aria-controls', screen.getByRole('listbox').id)
    expect(screen.getByRole('group', { name: 'Add' })).toBeInTheDocument()
    const first = screen.getByRole('option', { name: /Add download/ })
    expect(first).toHaveAttribute('aria-selected', 'true')
    expect(box).toHaveAttribute('aria-activedescendant', first.id)
    // Shortcuts show on the right, as kbd chips.
    expect(within(first).getByText('N').tagName).toBe('KBD')
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
    await vi.waitFor(() => expect(ran(list)).toHaveLength(1))
  })

  it('wraps around with the arrows and jumps with Ctrl+Home / Ctrl+End', async () => {
    renderWithI18n(<CommandPalette commands={commands()} onClose={() => {}} />)
    const box = screen.getByRole('combobox')
    await userEvent.keyboard('{ArrowUp}')
    expect(box).toHaveAttribute('aria-activedescendant', screen.getByRole('option', { name: /Go to History/ }).id)
    await userEvent.keyboard('{Control>}{Home}{/Control}')
    expect(box).toHaveAttribute('aria-activedescendant', screen.getByRole('option', { name: /Add download/ }).id)
    await userEvent.keyboard('{Control>}{End}{/Control}')
    expect(box).toHaveAttribute('aria-activedescendant', screen.getByRole('option', { name: /Go to History/ }).id)
  })

  it('marks what was typed inside the matching label', async () => {
    renderWithI18n(<CommandPalette commands={commands()} onClose={() => {}} />)
    await userEvent.keyboard('hist')
    const option = screen.getByRole('option', { name: /Go to History/ })
    expect(within(option).getByText('Hist').tagName).toBe('B')
  })

  it('runs a clicked option and follows the pointer', async () => {
    const list = commands()
    const onClose = vi.fn()
    renderWithI18n(<CommandPalette commands={list} onClose={onClose} />)
    const history = screen.getByRole('option', { name: /Go to History/ })
    fireEvent.mouseMove(history)
    expect(history).toHaveAttribute('aria-selected', 'true')
    await userEvent.click(history)
    expect(onClose).toHaveBeenCalled()
    await vi.waitFor(() => expect(list[2]!.run).toHaveBeenCalled())
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

  it('says when nothing matches, and Enter then does nothing', async () => {
    const list = commands()
    const onClose = vi.fn()
    renderWithI18n(<CommandPalette commands={list} onClose={onClose} />)
    await userEvent.keyboard('zzzz')
    expect(screen.getByText('Nothing matches “zzzz”')).toBeInTheDocument()
    expect(screen.getByRole('combobox')).not.toHaveAttribute('aria-activedescendant')
    await userEvent.keyboard('{Enter}')
    expect(onClose).not.toHaveBeenCalled()
  })

  it('closes on Escape, on the esc key chip and on the scrim', async () => {
    const onClose = vi.fn()
    const { container } = renderWithI18n(<CommandPalette commands={commands()} onClose={onClose} />)
    await userEvent.keyboard('{Escape}')
    expect(onClose).toHaveBeenCalledTimes(1)
    await userEvent.click(screen.getByRole('button', { name: 'Close' }))
    expect(onClose).toHaveBeenCalledTimes(2)
    fireEvent.mouseDown(container.querySelector('.cpal-scrim')!)
    expect(onClose).toHaveBeenCalledTimes(3)
  })
})

describe('paletteParts', () => {
  it('picks a glyph by command, then by kind, then by group', () => {
    expect(commandIcon({ id: 'pauseAll', group: 'actions' })).toBe('pause')
    expect(commandIcon({ id: 'task:42', group: 'downloads' })).toBe('down')
    expect(commandIcon({ id: 'f:video', group: 'view' })).toBe('filter')
    expect(commandIcon({ id: 'something', group: 'settings' })).toBe('settings')
  })

  it('splits a label around the first typed word it contains', () => {
    expect(highlight('Pause all', 'pa')).toEqual({ before: '', hit: 'Pa', after: 'use all' })
    expect(highlight('Go to History', 'zz hist')).toEqual({ before: 'Go to ', hit: 'Hist', after: 'ory' })
    expect(highlight('Pause all', 'pl')).toBeNull()
    expect(highlight('Pause all', '  ')).toBeNull()
  })
})
