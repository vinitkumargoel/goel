import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import en from '../locales/en.json'
import { renderWithI18n } from '../test/renderWithI18n'
import { ShortcutsDialog } from './ShortcutsDialog'

describe('ShortcutsDialog', () => {
  it('is a labelled modal with both columns and focus on Close', () => {
    renderWithI18n(<ShortcutsDialog onClose={vi.fn()} />)
    expect(screen.getByRole('dialog', { name: en.shortcuts.title })).toHaveAttribute('aria-modal', 'true')
    expect(screen.getByRole('heading', { name: en.shortcuts.navigation })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: en.shortcuts.actions })).toBeInTheDocument()
    expect(screen.getByText(en.shortcuts.toggle)).toBeInTheDocument()
    // Space alone pauses/resumes; with ⌘/Ctrl it adds or drops the focused row.
    expect(screen.getByText(en.shortcuts.toggleSelect)).toBeInTheDocument()
    const spaces = screen.getAllByText('Space')
    expect(spaces).toHaveLength(2)
    for (const kbd of spaces) expect(kbd.tagName).toBe('KBD')
    expect(screen.getByRole('button', { name: en.common.close })).toHaveFocus()
  })

  it('closes on Escape', async () => {
    const onClose = vi.fn()
    renderWithI18n(<ShortcutsDialog onClose={onClose} />)
    await userEvent.keyboard('{Escape}')
    expect(onClose).toHaveBeenCalled()
  })
})
