import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import en from '../locales/en.json'
import { renderWithI18n } from '../test/renderWithI18n'
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
    expect(dialog).toHaveAccessibleDescription(en.library.confirmRemoveWithData)
    expect(screen.getByRole('button', { name: en.common.cancel })).toHaveFocus()
  })

  it('confirms only from the destructive button', async () => {
    const { onConfirm, onClose } = renderConfirm()
    await userEvent.keyboard('{Enter}')
    expect(onConfirm).not.toHaveBeenCalled()
    expect(onClose).toHaveBeenCalledTimes(1)

    await userEvent.click(screen.getByRole('button', { name: en.menu.removeWithData }))
    expect(onConfirm).toHaveBeenCalledTimes(1)
  })

  it('closes on Escape', async () => {
    const { onClose, onConfirm } = renderConfirm()
    await userEvent.keyboard('{Escape}')
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
})
