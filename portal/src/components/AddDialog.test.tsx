import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import en from '../locales/en.json'
import { renderWithI18n } from '../test/renderWithI18n'
import { AddDialog } from './AddDialog'

const api = vi.hoisted(() => ({
  network: vi.fn(),
  add: vi.fn(),
  addTorrents: vi.fn(),
}))

vi.mock('../lib/api', async (importOriginal) => {
  const real = await importOriginal<typeof import('../lib/api')>()
  return { ...real, api }
})

beforeEach(() => {
  api.network.mockReset().mockRejectedValue(new Error('offline'))
  api.add.mockReset().mockResolvedValue({ added: 1, refused: 0 })
  api.addTorrents.mockReset().mockResolvedValue({ added: 1, errors: [] })
})

function renderDialog(initialFiles: File[] = []) {
  const handlers = { onClose: vi.fn(), onAdded: vi.fn(), onWarn: vi.fn() }
  renderWithI18n(<AddDialog {...handlers} initialFiles={initialFiles} />)
  return handlers
}

const torrent = (name: string, size = 2048) => {
  const f = new File(['d8:announce'], name, { type: 'application/x-bittorrent' })
  Object.defineProperty(f, 'size', { value: size })
  return f
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
    expect(screen.getByText(/1 line isn’t an http\(s\), ftp\(s\), sftp or magnet link/)).toBeInTheDocument()
    expect(screen.getByText('notalink')).toBeInTheDocument()
  })

  it('removes a flagged line with its ✕', async () => {
    renderDialog()
    const field = screen.getByLabelText(en.addDialog.urlLabel)
    await userEvent.type(field, 'https://a.example/x.iso{Enter}notalink')
    await userEvent.click(screen.getByRole('button', { name: 'Remove line notalink' }))
    expect(field).toHaveValue('https://a.example/x.iso')
    expect(screen.queryByText('notalink')).toBeNull()
  })

  it('lists dropped torrents as removable chips and uploads them on submit', async () => {
    const handlers = renderDialog([torrent('ubuntu.torrent')])
    expect(screen.getByText('ubuntu.torrent')).toBeInTheDocument()
    expect(screen.getByText('· 2.0 KB')).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: en.addDialog.submit }))
    expect(api.add).not.toHaveBeenCalled()
    expect(api.addTorrents).toHaveBeenCalledWith(
      [expect.objectContaining({ name: 'ubuntu.torrent' })],
      expect.objectContaining({ dir: undefined, priority: 'normal', paused: false }),
    )
    await vi.waitFor(() =>
      expect(handlers.onAdded).toHaveBeenCalledWith({ added: 1, refused: 0, failures: [] }),
    )
  })

  it('adds files chosen through browse and refuses non-torrents', async () => {
    renderDialog()
    const input = screen.getByLabelText(en.addDialog.torrentFiles, { selector: 'input' })
    await userEvent.upload(input, [torrent('a.torrent')], { applyAccept: false })
    await userEvent.upload(input, [new File(['x'], 'notes.txt')], { applyAccept: false })
    expect(screen.getByText('a.torrent')).toBeInTheDocument()
    expect(screen.getByText('notes.txt isn’t a .torrent file')).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Remove a.torrent' }))
    expect(screen.queryByText('a.torrent')).toBeNull()
  })

  it('stays open and warns when every torrent is refused', async () => {
    api.addTorrents.mockResolvedValue({ added: 0, errors: [{ file: 'bad.torrent', error: 'Not a torrent' }] })
    const handlers = renderDialog([torrent('bad.torrent')])
    await userEvent.click(screen.getByRole('button', { name: en.addDialog.submit }))
    await vi.waitFor(() => expect(handlers.onWarn).toHaveBeenCalledWith('bad.torrent: Not a torrent'))
    expect(handlers.onAdded).not.toHaveBeenCalled()
  })

  it('submits with Ctrl+Enter', async () => {
    const handlers = renderDialog()
    await userEvent.type(screen.getByLabelText(en.addDialog.urlLabel), 'https://a.example/x.iso')
    await userEvent.keyboard('{Control>}{Enter}{/Control}')
    expect(api.add).toHaveBeenCalledWith(expect.objectContaining({ url: 'https://a.example/x.iso' }))
    await vi.waitFor(() =>
      expect(handlers.onAdded).toHaveBeenCalledWith({ added: 1, refused: 0, failures: [] }),
    )
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
