import { screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiError } from '../lib/api'
import { memoryStorage } from '../test/memoryStorage'
import en from '../locales/en.json'
import { renderWithI18n } from '../test/renderWithI18n'
import { AddDialog } from './AddDialog'

const api = vi.hoisted(() => ({
  network: vi.fn(),
  add: vi.fn(),
  addTorrents: vi.fn(),
  addPreview: vi.fn(),
}))

vi.mock('../lib/api', async (importOriginal) => {
  const real = await importOriginal<typeof import('../lib/api')>()
  return { ...real, api }
})

beforeEach(() => {
  api.network.mockReset().mockRejectedValue(new Error('offline'))
  api.add.mockReset().mockResolvedValue({ added: 1, refused: 0 })
  api.addTorrents.mockReset().mockResolvedValue({ added: 1, errors: [] })
  // An older server: no review step, the dialog adds directly.
  api.addPreview.mockReset().mockRejectedValue(new ApiError('http', 'Not found', 404))
  vi.stubGlobal('localStorage', memoryStorage())
})

afterEach(() => vi.unstubAllGlobals())

function renderDialog(initialFiles: File[] = [], extra: { initialUrl?: string; pasted?: boolean } = {}) {
  const handlers = { onClose: vi.fn(), onAdded: vi.fn(), onWarn: vi.fn() }
  renderWithI18n(<AddDialog {...handlers} initialFiles={initialFiles} {...extra} />)
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
      expect(handlers.onAdded).toHaveBeenCalledWith({ added: 1, refused: 0, failures: [], ids: [] }),
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
      expect(handlers.onAdded).toHaveBeenCalledWith({ added: 1, refused: 0, failures: [], ids: [] }),
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

  describe('review step', () => {
    const preview = (freeBytes: number | null) => ({
      freeBytes,
      items: [
        { index: 0, status: 'ok', name: 'ubuntu.iso', kind: 'http', totalBytes: 3000, estimated: false, files: [], fileCount: 0, note: null },
        { index: 1, status: 'duplicate', name: null, kind: 'http', totalBytes: 10, estimated: false, files: [], fileCount: 0, note: null },
        {
          index: 2, status: 'ok', name: 'Pack', kind: 'torrent', totalBytes: 500, estimated: false,
          files: [{ name: 'a.mkv', size: 400 }, { name: 'b.srt', size: 100 }], fileCount: 2, note: null,
        },
      ],
    })

    async function toReview(freeBytes: number | null = 10_000) {
      api.addPreview.mockResolvedValue(preview(freeBytes))
      const handlers = renderDialog()
      await userEvent.type(
        screen.getByLabelText(en.addDialog.urlLabel),
        'https://e/ubuntu.iso{Enter}https://e/dup.bin{Enter}magnet:?xt=urn:btih:abc',
      )
      await userEvent.click(screen.getByRole('button', { name: en.workflow.add.review }))
      await screen.findByText('ubuntu.iso')
      return handlers
    }

    it('lists each line with its status, and adds only the ticked ones', async () => {
      const handlers = await toReview()
      expect(api.addPreview).toHaveBeenCalledWith({
        url: 'https://e/ubuntu.iso\nhttps://e/dup.bin\nmagnet:?xt=urn:btih:abc',
        folder: undefined,
      })
      expect(screen.getByText(en.workflow.add.status.duplicate)).toBeInTheDocument()
      expect(screen.getByRole('checkbox', { name: 'dup.bin' })).not.toBeChecked()
      expect(screen.getByRole('checkbox', { name: 'ubuntu.iso' })).toHaveFocus()
      await userEvent.click(screen.getByRole('checkbox', { name: 'ubuntu.iso' }))
      await userEvent.click(screen.getByRole('button', { name: en.addDialog.submit }))
      expect(api.add).toHaveBeenCalledWith(expect.objectContaining({ url: 'magnet:?xt=urn:btih:abc' }))
      await vi.waitFor(() => expect(handlers.onAdded).toHaveBeenCalled())
    })

    it('expands a torrent\'s file list', async () => {
      await toReview()
      const toggle = screen.getByRole('button', { name: 'Show the 2 files in Pack' })
      expect(toggle).toHaveAttribute('aria-expanded', 'false')
      await userEvent.click(toggle)
      expect(screen.getByText('a.mkv')).toBeInTheDocument()
    })

    it('flags a total bigger than the free space', async () => {
      await toReview(1000)
      expect(screen.getByRole('status')).toHaveClass('short')
      expect(screen.getByRole('status')).toHaveTextContent(/not enough space/)
    })

    it('warns and stays on the links when the server is busy checking others', async () => {
      api.addPreview.mockRejectedValue(new ApiError('http', 'Still checking other links', 429))
      const handlers = renderDialog()
      await userEvent.type(screen.getByLabelText(en.addDialog.urlLabel), 'https://e/a.iso')
      await userEvent.click(screen.getByRole('button', { name: en.workflow.add.review }))
      await vi.waitFor(() => expect(handlers.onWarn).toHaveBeenCalledWith('Still checking other links'))
      expect(api.add).not.toHaveBeenCalled()
    })

    it('goes back to the links with Back', async () => {
      await toReview()
      await userEvent.click(screen.getByRole('button', { name: en.workflow.add.back }))
      expect(screen.getByLabelText(en.addDialog.urlLabel)).toHaveValue(
        'https://e/ubuntu.iso\nhttps://e/dup.bin\nmagnet:?xt=urn:btih:abc',
      )
    })
  })

  it('remembers the folder and priority, and offers recent folders', async () => {
    localStorage.setItem(
      'goel.add.prefs',
      JSON.stringify({ folder: '/srv/films', priority: 'high', recent: ['/srv/films', '/srv/iso'] }),
    )
    renderDialog()
    expect(screen.getByLabelText(en.addDialog.priority)).toHaveValue('high')
    expect(screen.getByText('srv / films')).toBeInTheDocument()
    const chips = screen.getByRole('group', { name: en.workflow.add.recentFolders })
    // The current folder is not offered again.
    expect(within(chips).queryByRole('button', { name: 'srv / films' })).toBeNull()
    await userEvent.click(within(chips).getByRole('button', { name: 'srv / iso' }))
    expect(screen.getByText('srv / iso', { selector: '.pkval' })).toBeInTheDocument()
  })

  it('says when the links came from the clipboard', () => {
    renderDialog([], { initialUrl: 'https://e/a', pasted: true })
    expect(screen.getByText(en.workflow.add.pasted)).toBeInTheDocument()
    expect(screen.getByLabelText(new RegExp(en.addDialog.urlLabel))).toHaveValue('https://e/a')
  })
})
