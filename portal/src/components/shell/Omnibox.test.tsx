import { fireEvent, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { createRef, useState } from 'react'
import { describe, expect, it, vi } from 'vitest'
import { i18n, renderWithI18n } from '../../test/renderWithI18n'
import { Omnibox } from './Omnibox'

function Harness({
  initial = '',
  canWrite = true,
  handlers,
}: {
  initial?: string
  canWrite?: boolean
  handlers: Record<'onChange' | 'onAdd' | 'onAddLinks' | 'onQuickAdd' | 'onPalette', ReturnType<typeof vi.fn>>
}) {
  const [value, setValue] = useState(initial)
  return (
    <Omnibox
      value={value}
      onChange={(v) => {
        setValue(v)
        handlers.onChange(v)
      }}
      inputRef={createRef()}
      canWrite={canWrite}
      onAdd={handlers.onAdd}
      onAddLinks={handlers.onAddLinks}
      onQuickAdd={handlers.onQuickAdd}
      onPalette={handlers.onPalette}
    />
  )
}

function setup(initial = '', canWrite = true) {
  const handlers = { onChange: vi.fn(), onAdd: vi.fn(), onAddLinks: vi.fn(), onQuickAdd: vi.fn(), onPalette: vi.fn() }
  renderWithI18n(<Harness initial={initial} canWrite={canWrite} handlers={handlers} />)
  const input = screen.getByRole('searchbox')
  return { handlers, input }
}

describe('Omnibox', () => {
  it('is a labelled search box that advertises its shortcuts', () => {
    const { input } = setup()
    expect(screen.getByRole('search')).toBeInTheDocument()
    expect(input).toHaveAccessibleName(i18n.t('shell.omnibox.label'))
    expect(input).toHaveAttribute('aria-keyshortcuts', '/')
    const add = screen.getByRole('button', { name: i18n.t('common.add') })
    expect(add).toHaveAttribute('aria-keyshortcuts', 'N')
    expect(add).toHaveAttribute('title', 'Add download (N)')
  })

  it('searches as you type, and Escape clears', async () => {
    const { input, handlers } = setup()
    await userEvent.type(input, 'iso')
    expect(handlers.onChange).toHaveBeenLastCalledWith('iso')
    await userEvent.keyboard('{Escape}')
    expect(handlers.onChange).toHaveBeenLastCalledWith('')
    expect(input).toHaveValue('')
  })

  it('turns finished search tokens into removable chips, and Backspace takes the last one back', async () => {
    const { input, handlers } = setup('is:failed host:example.com ubu')
    expect(input).toHaveValue('ubu')
    expect(screen.getByRole('button', { name: /Remove.*is:failed/ })).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: /Remove.*is:failed/ }))
    expect(handlers.onChange).toHaveBeenLastCalledWith('host:example.com ubu')
    input.focus()
    ;(input as HTMLInputElement).setSelectionRange(0, 0)
    await userEvent.keyboard('{Backspace}')
    expect(handlers.onChange).toHaveBeenLastCalledWith('host:example.comubu')
  })

  it('opens Add with links pasted into an empty box', () => {
    const { input, handlers } = setup()
    fireEvent.paste(input, { clipboardData: { getData: () => 'https://example.com/a.iso\nhttps://example.com/b.iso' } })
    expect(handlers.onAddLinks).toHaveBeenCalledWith('https://example.com/a.iso\nhttps://example.com/b.iso', true)
  })

  it('offers typed links as a suggestion: Enter adds them, Options opens Add', async () => {
    const { input, handlers } = setup()
    await userEvent.type(input, 'https://example.com/ubuntu.iso')
    const sug = screen.getByRole('status')
    expect(sug).toHaveTextContent(i18n.t('shell.omnibox.found', { count: 1 }))
    expect(sug).toHaveTextContent('ubuntu.iso')
    await userEvent.click(screen.getByRole('button', { name: i18n.t('shell.omnibox.options') }))
    expect(handlers.onAddLinks).toHaveBeenCalledWith('https://example.com/ubuntu.iso', false)
    expect(input).toHaveValue('')
    await userEvent.type(input, 'magnet:?xt=urn:btih:abc&dn=Big+Buck+Bunny{Enter}')
    expect(handlers.onQuickAdd).toHaveBeenCalledWith('magnet:?xt=urn:btih:abc&dn=Big+Buck+Bunny')
  })

  it('opens Add empty and the palette from its buttons', async () => {
    const { handlers } = setup()
    await userEvent.click(screen.getByRole('button', { name: i18n.t('common.add') }))
    await userEvent.click(screen.getByRole('button', { name: i18n.t('workflow.palette.label') }))
    expect(handlers.onAdd).toHaveBeenCalled()
    expect(handlers.onPalette).toHaveBeenCalled()
  })

  it('only searches in a read-only session', async () => {
    const { input, handlers } = setup('', false)
    expect(input).toHaveAccessibleName(i18n.t('topbar.searchDownloads'))
    expect(screen.queryByRole('button', { name: i18n.t('common.add') })).toBeNull()
    fireEvent.paste(input, { clipboardData: { getData: () => 'https://example.com/a.iso' } })
    expect(handlers.onAddLinks).not.toHaveBeenCalled()
    await userEvent.type(input, 'https://example.com/a.iso')
    expect(screen.queryByRole('status')).toBeNull()
  })
})
