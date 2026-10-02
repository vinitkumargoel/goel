import { fireEvent, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import en from '../../locales/en.json'
import { renderWithI18n } from '../../test/renderWithI18n'
import { ConfirmDialog } from './ConfirmDialog'

function renderConfirm() {
  const onConfirm = vi.fn()
  const onClose = vi.fn()
  renderWithI18n(
    <ConfirmDialog
      request={{
        title: en.confirm.removeDataTitle,
        body: en.library.confirmRemoveWithData,
        confirmLabel: en.menu.removeWithData,
        onConfirm,
      }}
      onClose={onClose}
    />,
  )
  return { onConfirm, onClose }
}

describe('ConfirmDialog', () => {
  it('renders nothing without a request', () => {
    renderWithI18n(<ConfirmDialog request={null} onClose={vi.fn()} />)
    expect(screen.queryByRole('alertdialog')).toBeNull()
  })

  it('is a labelled alert dialog that starts on Cancel', () => {
    renderConfirm()
    const dialog = screen.getByRole('alertdialog', { name: en.confirm.removeDataTitle })
    expect(dialog).toHaveAttribute('aria-modal', 'true')
    expect(dialog).toHaveAccessibleDescription(en.library.confirmRemoveWithData)
    expect(screen.getByRole('button', { name: en.common.cancel })).toHaveFocus()
  })

  it('confirms only from the destructive button, closing first', async () => {
    const { onConfirm, onClose } = renderConfirm()
    await userEvent.keyboard('{Enter}')
    expect(onConfirm).not.toHaveBeenCalled()
    expect(onClose).toHaveBeenCalledTimes(1)

    const order: string[] = []
    onClose.mockImplementation(() => order.push('close'))
    onConfirm.mockImplementation(() => order.push('confirm'))
    const destroy = screen.getByRole('button', { name: en.menu.removeWithData })
    // No option: the action is destructive as it stands.
    expect(destroy).toHaveClass('pri', 'dang')
    await userEvent.click(destroy)
    expect(onConfirm).toHaveBeenCalledWith(false)
    expect(order).toEqual(['close', 'confirm'])
  })

  it('closes on Escape', async () => {
    const { onClose, onConfirm } = renderConfirm()
    await userEvent.keyboard('{Escape}')
    expect(onClose).toHaveBeenCalled()
    expect(onConfirm).not.toHaveBeenCalled()
  })

  it('closes on a click outside', () => {
    const { onClose, onConfirm } = renderConfirm()
    fireEvent.mouseDown(screen.getByRole('alertdialog').parentElement!)
    expect(onClose).toHaveBeenCalled()
    expect(onConfirm).not.toHaveBeenCalled()
  })

  it('pulls Tab back into the dialog when focus has fallen to the page body', async () => {
    renderConfirm()
    ;(document.activeElement as HTMLElement | null)?.blur()
    expect(document.activeElement).toBe(document.body)
    await userEvent.tab()
    expect(screen.getByRole('alertdialog').contains(document.activeElement)).toBe(true)
  })

  it('closes on Escape even when focus is outside the dialog', async () => {
    const { onClose } = renderConfirm()
    ;(document.activeElement as HTMLElement | null)?.blur()
    await userEvent.keyboard('{Escape}')
    expect(onClose).toHaveBeenCalled()
  })

  it('lists names with sizes when known, and the option turns the confirm destructive', async () => {
    const onConfirm = vi.fn()
    renderWithI18n(
      <ConfirmDialog
        request={{
          title: 'Remove 7 downloads?',
          body: 'They leave the list.',
          items: ['a.mkv', { name: 'b.iso', bytes: 2048 }],
          footnote: 'and 5 more · 3 GB in all',
          confirmLabel: 'Remove 7',
          option: { label: 'Also delete files from disk', confirmLabel: 'Delete 7 · 3 GB' },
          onConfirm,
        }}
        onClose={() => {}}
      />,
    )
    expect(screen.getByText('a.mkv')).toBeInTheDocument()
    expect(screen.getByText('2.0 KB')).toBeInTheDocument()
    expect(screen.getByText('and 5 more · 3 GB in all')).toBeInTheDocument()
    const plain = screen.getByRole('button', { name: 'Remove 7' })
    expect(plain).toHaveClass('pri')
    expect(plain).not.toHaveClass('dang')
    await userEvent.click(screen.getByRole('checkbox', { name: 'Also delete files from disk' }))
    const destroy = screen.getByRole('button', { name: 'Delete 7 · 3 GB' })
    expect(destroy).toHaveClass('pri', 'dang')
    await userEvent.click(destroy)
    expect(onConfirm).toHaveBeenCalledWith(true)
  })
})
