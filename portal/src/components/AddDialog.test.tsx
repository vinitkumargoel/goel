import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import en from '../locales/en.json'
import { renderWithI18n } from '../test/renderWithI18n'
import { AddDialog } from './AddDialog'

const api = vi.hoisted(() => ({
  network: vi.fn(),
  add: vi.fn(),
}))

vi.mock('../lib/api', () => ({ api }))

beforeEach(() => {
  api.network.mockReset().mockRejectedValue(new Error('offline'))
  api.add.mockReset().mockResolvedValue({ added: 1, refused: 0 })
})

function renderDialog() {
  const handlers = { onClose: vi.fn(), onAdded: vi.fn(), onWarn: vi.fn() }
  renderWithI18n(<AddDialog {...handlers} />)
  return handlers
}

describe('AddDialog', () => {
  it('is a labelled modal dialog with the URL field focused', () => {
    renderDialog()
    const dialog = screen.getByRole('dialog', { name: en.addDialog.title })
    expect(dialog).toHaveAttribute('aria-modal', 'true')
    expect(screen.getByLabelText(en.addDialog.urlLabel)).toHaveFocus()
    expect(screen.getByLabelText(en.addDialog.priority)).toBeInTheDocument()
  })

  it('shows an empty URL as an inline error, not a toast', async () => {
    const handlers = renderDialog()
    await userEvent.click(screen.getByRole('button', { name: en.addDialog.submit }))
    expect(screen.getByRole('alert')).toHaveTextContent(en.addDialog.enterUrl)
    expect(screen.getByLabelText(en.addDialog.urlLabel)).toHaveAttribute('aria-invalid', 'true')
    expect(handlers.onWarn).not.toHaveBeenCalled()
    expect(api.add).not.toHaveBeenCalled()
  })

  it('counts links live and flags lines it does not recognise', async () => {
    renderDialog()
    await userEvent.type(
      screen.getByLabelText(en.addDialog.urlLabel),
      'https://a.example/x.iso{Enter}magnet:?xt=urn:btih:abc{Enter}notalink',
    )
    expect(screen.getByText('2 links detected')).toBeInTheDocument()
    expect(screen.getByText(/1 line isn’t an http\(s\), ftp, sftp or magnet link: notalink/)).toBeInTheDocument()
  })

  it('submits with Ctrl+Enter', async () => {
    const handlers = renderDialog()
    await userEvent.type(screen.getByLabelText(en.addDialog.urlLabel), 'https://a.example/x.iso')
    await userEvent.keyboard('{Control>}{Enter}{/Control}')
    expect(api.add).toHaveBeenCalledWith(expect.objectContaining({ url: 'https://a.example/x.iso' }))
    await vi.waitFor(() => expect(handlers.onAdded).toHaveBeenCalledWith(1, 0))
  })

  it('keeps Tab inside the dialog', async () => {
    renderDialog()
    const submit = screen.getByRole('button', { name: en.addDialog.submit })
    submit.focus()
    await userEvent.tab()
    expect(screen.getByLabelText(en.addDialog.urlLabel)).toHaveFocus()
    await userEvent.tab({ shift: true })
    expect(submit).toHaveFocus()
  })
})
