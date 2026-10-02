import { fireEvent, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiError } from '../../lib/api'
import type { FolderListing, NetworkState } from '../../lib/types'
import en from '../../locales/en.json'
import adding from '../../locales/en.json'
import { memoryStorage } from '../../test/memoryStorage'
import { renderWithI18n } from '../../test/renderWithI18n'
import { AddDialog } from './AddDialog'

const api = vi.hoisted(() => ({
  network: vi.fn(),
  add: vi.fn(),
  addTorrents: vi.fn(),
  addPreview: vi.fn(),
  folders: vi.fn(),
  createFolder: vi.fn(),
}))

vi.mock('../../lib/api', async (importOriginal) => {
  const real = await importOriginal<typeof import('../../lib/api')>()
  return { ...real, api }
})

beforeEach(() => {
  api.network.mockReset().mockRejectedValue(new Error('offline'))
  api.add.mockReset().mockResolvedValue({ added: 1, refused: 0 })
  api.addTorrents.mockReset().mockResolvedValue({ added: 1, errors: [] })
  // An older server: no review step, the dialog adds directly.
  api.addPreview.mockReset().mockRejectedValue(new ApiError('http', 'Not found', 404))
  api.folders.mockReset()
  api.createFolder.mockReset()
  vi.stubGlobal('localStorage', memoryStorage())
  vi.stubGlobal('sessionStorage', memoryStorage())
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

const urlField = () => screen.getByLabelText(en.addDialog.urlLabel)
const primary = (name: string | RegExp) => screen.getByRole('button', { name })

describe('AddDialog', () => {
  it('is a labelled modal sheet with the URL field focused', () => {
    renderDialog()
    const dialog = screen.getByRole('dialog', { name: en.addDialog.title })
    expect(dialog).toHaveAttribute('aria-modal', 'true')
    expect(dialog).toHaveClass('sheet')
    expect(urlField()).toHaveFocus()
    expect(screen.getByRole('radiogroup', { name: en.addDialog.priority })).toBeInTheDocument()
    expect(screen.getByRole('radio', { name: en.task.priority.normal })).toBeChecked()
  })

  it('shows an empty URL as an inline error, not a toast', async () => {
    const handlers = renderDialog()
    await userEvent.click(primary(en.addDialog.submit))
    expect(screen.getByRole('alert')).toHaveTextContent(en.addDialog.enterUrl)
    expect(urlField()).toHaveAttribute('aria-invalid', 'true')
    expect(urlField()).toHaveFocus()
    expect(handlers.onWarn).not.toHaveBeenCalled()
    expect(api.add).not.toHaveBeenCalled()
    await userEvent.type(urlField(), 'x')
    expect(screen.queryByRole('alert')).toBeNull()
  })

  it('lists what it recognised in each line and flags the rest', async () => {
    renderDialog()
    await userEvent.type(urlField(), 'https://a.example/x.iso{Enter}magnet:?xt=urn:btih:abc&dn=Pack{Enter}notalink')
    expect(screen.getByText('2 links detected')).toBeInTheDocument()
    expect(screen.getByText('x.iso')).toBeInTheDocument()
    expect(screen.getByText('a.example')).toBeInTheDocument()
    expect(screen.getByText('Pack')).toBeInTheDocument()
    expect(screen.getByText('BT')).toBeInTheDocument()
    expect(screen.getByText(/1 line isn’t an http\(s\), ftp\(s\), sftp or magnet link/)).toBeInTheDocument()
    expect(screen.getByText('notalink')).toBeInTheDocument()
    // Links mean a review step comes next.
    expect(screen.getByText('Step 1 of 2')).toBeInTheDocument()
    expect(primary(new RegExp(`^${adding.adding.continue}`))).toBeInTheDocument()
  })

  it('removes a flagged line with its ✕', async () => {
    renderDialog()
    await userEvent.type(urlField(), 'https://a.example/x.iso{Enter}notalink')
    await userEvent.click(screen.getByRole('button', { name: 'Remove line notalink' }))
    expect(urlField()).toHaveValue('https://a.example/x.iso')
    expect(screen.queryByText('notalink')).toBeNull()
  })

  it('lists dropped torrents as removable chips and uploads them on submit', async () => {
    const handlers = renderDialog([torrent('ubuntu.torrent')])
    expect(screen.getByText('ubuntu.torrent')).toBeInTheDocument()
    expect(screen.getByText('· 2.0 KB')).toBeInTheDocument()
    await userEvent.click(primary(new RegExp(`^${en.addDialog.submit}`)))
    expect(api.add).not.toHaveBeenCalled()
    expect(api.addTorrents).toHaveBeenCalledWith(
      [expect.objectContaining({ name: 'ubuntu.torrent' })],
      expect.objectContaining({ dir: undefined, priority: 'normal', paused: false }),
    )
    await vi.waitFor(() => expect(handlers.onAdded).toHaveBeenCalledWith({ added: 1, refused: 0, failures: [], ids: [] }))
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
    // Removing clears the old rejections too.
    expect(screen.queryByText('notes.txt isn’t a .torrent file')).toBeNull()
  })

  it('takes a .torrent dropped anywhere on the dialog', () => {
    renderDialog()
    const files = [torrent('drop.torrent')]
    fireEvent.drop(urlField(), { dataTransfer: { types: ['Files'], files } })
    expect(screen.getByText('drop.torrent')).toBeInTheDocument()
  })

  it('stays open and warns when every torrent is refused', async () => {
    api.addTorrents.mockResolvedValue({ added: 0, errors: [{ file: 'bad.torrent', error: 'Not a torrent' }] })
    const handlers = renderDialog([torrent('bad.torrent')])
    await userEvent.click(primary(new RegExp(`^${en.addDialog.submit}`)))
    await vi.waitFor(() => expect(handlers.onWarn).toHaveBeenCalledWith('bad.torrent: Not a torrent'))
    expect(handlers.onAdded).not.toHaveBeenCalled()
    expect(primary(new RegExp(`^${en.addDialog.submit}`))).toBeEnabled()
  })

  it('reports a failed add and keeps the links', async () => {
    api.add.mockRejectedValue(new ApiError('http', 'Server unhappy', 500))
    const handlers = renderDialog()
    await userEvent.type(urlField(), 'https://a.example/x.iso')
    await userEvent.keyboard('{Control>}{Enter}{/Control}')
    await vi.waitFor(() => expect(handlers.onWarn).toHaveBeenCalledWith('Server unhappy'))
    expect(handlers.onAdded).not.toHaveBeenCalled()
    expect(urlField()).toHaveValue('https://a.example/x.iso')
  })

  it('submits with Ctrl+Enter, falling back to a direct add without the review endpoint', async () => {
    const handlers = renderDialog()
    await userEvent.type(urlField(), 'https://a.example/x.iso')
    await userEvent.keyboard('{Control>}{Enter}{/Control}')
    await vi.waitFor(() => expect(api.add).toHaveBeenCalledWith(expect.objectContaining({ url: 'https://a.example/x.iso' })))
    await vi.waitFor(() => expect(handlers.onAdded).toHaveBeenCalledWith({ added: 1, refused: 0, failures: [], ids: [] }))
  })

  it('sends the chosen priority and a paused start, then remembers them', async () => {
    const handlers = renderDialog()
    await userEvent.type(urlField(), 'notalink')
    await userEvent.click(screen.getByRole('radio', { name: en.task.priority.high }))
    await userEvent.click(screen.getByRole('radio', { name: adding.adding.paused }))
    await userEvent.click(primary(new RegExp(`^${en.addDialog.submit}`)))
    expect(api.add).toHaveBeenCalledWith(expect.objectContaining({ url: 'notalink', priority: 'high', paused: true }))
    await vi.waitFor(() => expect(handlers.onAdded).toHaveBeenCalled())
    expect(JSON.parse(localStorage.getItem('goel.add.prefs') ?? '{}')).toMatchObject({ priority: 'high' })
  })

  it('keeps Tab inside the dialog', async () => {
    renderDialog()
    const submit = primary(new RegExp(`^${en.addDialog.submit}`))
    submit.focus()
    await userEvent.tab()
    expect(urlField()).toHaveFocus()
    await userEvent.tab({ shift: true })
    expect(submit).toHaveFocus()
  })

  it('closes on Escape and Cancel; a click outside closes only while nothing is typed', async () => {
    const handlers = renderDialog()
    const scrim = screen.getByRole('dialog').parentElement!
    await userEvent.type(urlField(), 'https://a.example/x.iso')
    fireEvent.mouseDown(scrim)
    expect(handlers.onClose).not.toHaveBeenCalled()
    await userEvent.keyboard('{Escape}')
    expect(handlers.onClose).toHaveBeenCalledTimes(1)
    await userEvent.click(screen.getByRole('button', { name: en.common.cancel }))
    expect(handlers.onClose).toHaveBeenCalledTimes(2)
  })

  it('closes on a click outside when empty', () => {
    const handlers = renderDialog()
    fireEvent.mouseDown(screen.getByRole('dialog').parentElement!)
    expect(handlers.onClose).toHaveBeenCalled()
  })

  it('keeps a draft of the links while open', async () => {
    renderDialog()
    await userEvent.type(urlField(), 'https://a.example/x.iso')
    expect(JSON.parse(sessionStorage.getItem('goel.addDraft') ?? '{}')).toMatchObject({ url: 'https://a.example/x.iso' })
  })

  describe('review step', () => {
    const preview = (freeBytes: number | null) => ({
      freeBytes,
      items: [
        { index: 0, status: 'ok', name: 'ubuntu.iso', kind: 'http', totalBytes: 3000, estimated: false, files: [], fileCount: 0, note: null },
        { index: 1, status: 'duplicate', name: null, kind: 'http', totalBytes: 10, estimated: false, files: [], fileCount: 0, note: null },
        {
          index: 2, status: 'ok', name: 'Pack', kind: 'torrent', totalBytes: 500, estimated: false,
          files: [{ name: 'a.mkv', size: 400 }, { name: 'b.srt', size: 100 }], fileCount: 3, note: null,
        },
        { index: 3, status: 'credentials', name: 'secret.zip', kind: 'http', totalBytes: null, estimated: false, files: [], fileCount: 0, note: null },
      ],
    })

    const LINKS = 'https://e/ubuntu.iso\nhttps://e/dup.bin\nmagnet:?xt=urn:btih:abc\nhttps://u:p@e/secret.zip'

    async function toReview(freeBytes: number | null = 10_000) {
      api.addPreview.mockResolvedValue(preview(freeBytes))
      const handlers = renderDialog()
      await userEvent.type(urlField(), LINKS.replaceAll('\n', '{Enter}'))
      await userEvent.click(primary(new RegExp(`^${adding.adding.continue}`)))
      await screen.findByText('ubuntu.iso')
      return handlers
    }

    it('lists each line with its status, and adds only the ticked ones', async () => {
      const handlers = await toReview()
      expect(api.addPreview).toHaveBeenCalledWith({ url: LINKS, folder: undefined })
      expect(screen.getByRole('dialog', { name: 'Review 4 links' })).toBeInTheDocument()
      expect(screen.getByText(en.workflow.add.status.duplicate)).toBeInTheDocument()
      expect(screen.getByText(en.workflow.add.status.credentials)).toHaveClass('pill', 'warn')
      expect(screen.getByRole('checkbox', { name: 'dup.bin' })).not.toBeChecked()
      expect(screen.getByRole('checkbox', { name: 'secret.zip' })).toBeDisabled()
      expect(screen.getByText('2 of 4 selected')).toBeInTheDocument()
      expect(screen.getByRole('checkbox', { name: 'ubuntu.iso' })).toHaveFocus()
      await userEvent.click(screen.getByRole('checkbox', { name: 'ubuntu.iso' }))
      await userEvent.click(primary(new RegExp(`^${en.addDialog.submit}`)))
      expect(api.add).toHaveBeenCalledWith(expect.objectContaining({ url: 'magnet:?xt=urn:btih:abc' }))
      await vi.waitFor(() => expect(handlers.onAdded).toHaveBeenCalled())
    })

    it('selects all or none of what the type filter shows', async () => {
      await toReview()
      await userEvent.click(screen.getByRole('button', { name: adding.adding.selectNone }))
      expect(screen.getByText('0 of 4 selected')).toBeInTheDocument()
      expect(primary(new RegExp(`^${en.addDialog.submit}`))).toBeDisabled()
      await userEvent.click(screen.getByRole('button', { name: /^Video/ }))
      expect(screen.queryByText('ubuntu.iso')).toBeNull()
      await userEvent.click(screen.getByRole('button', { name: adding.adding.selectAll }))
      expect(screen.getByText('1 of 4 selected')).toBeInTheDocument()
      await userEvent.click(screen.getByRole('button', { name: /^All/ }))
      await userEvent.click(screen.getByRole('button', { name: adding.adding.selectAll }))
      // The duplicate can be ticked by hand or by Select all; the password line never.
      expect(screen.getByText('3 of 4 selected')).toBeInTheDocument()
      expect(primary('Add 3 downloads')).toBeEnabled()
    })

    it("expands a torrent's file list", async () => {
      await toReview()
      const toggle = screen.getByRole('button', { name: 'Show the 3 files in Pack' })
      expect(toggle).toHaveAttribute('aria-expanded', 'false')
      await userEvent.click(toggle)
      expect(toggle).toHaveAttribute('aria-expanded', 'true')
      expect(screen.getByText('a.mkv')).toBeInTheDocument()
      expect(screen.getByText('and 1 more')).toBeInTheDocument()
    })

    it('checks the total against the free space', async () => {
      await toReview()
      expect(screen.getByRole('status')).not.toHaveClass('short')
      expect(screen.getByRole('status')).toHaveTextContent(/Total 3.4 KB · 9.8 KB free in Default downloads folder/)
    })

    it('flags a total bigger than the free space', async () => {
      await toReview(1000)
      expect(screen.getByRole('status')).toHaveClass('short')
      expect(screen.getByRole('status')).toHaveTextContent(/not enough space/)
    })

    it('says only the total when the server cannot tell the free space', async () => {
      await toReview(null)
      expect(screen.getByRole('status')).toHaveTextContent('2 downloads · 3.4 KB in total')
    })

    it('warns and stays on the links when the server is busy checking others', async () => {
      api.addPreview.mockRejectedValue(new ApiError('http', 'Still checking other links', 429))
      const handlers = renderDialog()
      await userEvent.type(urlField(), 'https://e/a.iso')
      await userEvent.click(primary(new RegExp(`^${adding.adding.continue}`)))
      await vi.waitFor(() => expect(handlers.onWarn).toHaveBeenCalledWith('Still checking other links'))
      expect(api.add).not.toHaveBeenCalled()
      expect(urlField()).toBeInTheDocument()
    })

    it('stays put when the server refused the folder', async () => {
      api.addPreview.mockRejectedValue(new ApiError('refused', 'Outside the allowed folders', 403))
      const handlers = renderDialog()
      await userEvent.type(urlField(), 'https://e/a.iso')
      await userEvent.click(primary(new RegExp(`^${adding.adding.continue}`)))
      await vi.waitFor(() => expect(primary(new RegExp(`^${adding.adding.continue}`))).toBeEnabled())
      expect(api.add).not.toHaveBeenCalled()
      expect(handlers.onWarn).not.toHaveBeenCalled()
    })

    it('goes back to the links with Back', async () => {
      await toReview()
      await userEvent.click(screen.getByRole('button', { name: en.workflow.add.back }))
      expect(urlField()).toHaveValue(LINKS)
      expect(urlField()).toHaveFocus()
    })
  })

  it('remembers the folder and priority, and offers recent folders', async () => {
    localStorage.setItem('goel.add.prefs', JSON.stringify({ folder: '/srv/films', priority: 'high', recent: ['/srv/films', '/srv/iso'] }))
    renderDialog()
    expect(screen.getByRole('radio', { name: en.task.priority.high })).toBeChecked()
    expect(screen.getByText('srv / films')).toBeInTheDocument()
    const chips = screen.getByRole('group', { name: en.workflow.add.recentFolders })
    // The current folder is not offered again.
    expect(within(chips).queryByRole('button', { name: 'srv / films' })).toBeNull()
    await userEvent.click(within(chips).getByRole('button', { name: 'srv / iso' }))
    expect(screen.getByText('srv / iso', { selector: '.add-folder-val' })).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: en.addDialog.useDefaultFolder }))
    expect(screen.getByText(en.addDialog.defaultFolder)).toBeInTheDocument()
  })

  it('says when the links came from the clipboard', () => {
    renderDialog([], { initialUrl: 'https://e/a', pasted: true })
    expect(screen.getByText(en.workflow.add.pasted)).toBeInTheDocument()
    expect(urlField()).toHaveValue('https://e/a')
  })

  describe('folder picker', () => {
    const listing = (over: Partial<FolderListing> = {}): FolderListing => ({
      path: '/home/me/Downloads',
      parent: '/home/me',
      folders: [{ name: 'Films', path: '/home/me/Downloads/Films', readable: true, writable: true }],
      writable: true,
      home: '/home/me',
      defaultFolder: '/home/me/Downloads',
      places: [],
      ...over,
    })

    it('stacks over the dialog, hands Escape back, and fills the folder on pick', async () => {
      api.folders.mockImplementation((path?: string) =>
        Promise.resolve(path === '/home/me/Downloads/Films' ? listing({ path, parent: '/home/me/Downloads', folders: [] }) : listing()),
      )
      const handlers = renderDialog()
      await userEvent.click(screen.getByRole('button', { name: en.addDialog.browse }))
      const picker = await screen.findByRole('dialog', { name: en.folderPicker.title })
      await userEvent.click(await within(picker).findByRole('button', { name: /Films/ }))
      await within(picker).findByText('Home / Downloads / Films')
      await userEvent.click(within(picker).getByRole('button', { name: en.folderPicker.usePick }))
      expect(screen.queryByRole('dialog', { name: en.folderPicker.title })).toBeNull()
      expect(screen.getByText('Home / Downloads / Films', { selector: '.add-folder-val' })).toBeInTheDocument()

      await userEvent.click(screen.getByRole('button', { name: en.addDialog.browse }))
      await screen.findByRole('dialog', { name: en.folderPicker.title })
      await userEvent.keyboard('{Escape}')
      expect(screen.queryByRole('dialog', { name: en.folderPicker.title })).toBeNull()
      expect(handlers.onClose).not.toHaveBeenCalled()
    })

    it('stores the default folder as blank', async () => {
      api.folders.mockResolvedValue(listing())
      renderDialog()
      await userEvent.click(screen.getByRole('button', { name: en.addDialog.browse }))
      const picker = await screen.findByRole('dialog', { name: en.folderPicker.title })
      await within(picker).findByText('Home / Downloads')
      await userEvent.click(within(picker).getByRole('button', { name: en.folderPicker.usePick }))
      expect(screen.getByText(en.addDialog.defaultFolder)).toBeInTheDocument()
    })
  })

  describe('network', () => {
    const net: NetworkState = {
      aggregation: false,
      streamsPerAdapter: 4,
      selected: [],
      reason: null,
      locked: false,
      adapters: [
        { name: 'en0', label: 'Wi-Fi', type: 'wifi', ipv4: '10.0.0.2', expensive: false, eligible: true },
        { name: 'en1', label: 'Phone', type: 'cell', ipv4: null, expensive: true, eligible: true },
      ],
    }

    async function openMore() {
      await userEvent.click(screen.getByRole('button', { name: adding.adding.moreOptions }))
    }

    it('offers a split across interfaces and warns when none is picked', async () => {
      api.network.mockResolvedValue(net)
      const handlers = renderDialog()
      await openMore()
      const mode = await screen.findByLabelText(en.addDialog.network)
      expect(screen.getByRole('option', { name: en.addDialog.modeAutoDefault })).toBeInTheDocument()
      await userEvent.selectOptions(mode, 'split')
      expect(screen.getByText(en.adapter.metered)).toBeInTheDocument()
      expect(screen.getByText(en.adapter.noAddress)).toBeInTheDocument()
      await userEvent.click(screen.getByRole('checkbox', { name: /Wi-Fi/ }))
      await userEvent.click(screen.getByRole('checkbox', { name: /Phone/ }))
      await userEvent.type(urlField(), 'https://e/a.iso')
      await userEvent.click(primary(new RegExp(`^${adding.adding.continue}`)))
      expect(handlers.onWarn).toHaveBeenCalledWith(en.addDialog.pickInterface)
      expect(api.addPreview).not.toHaveBeenCalled()
    })

    it('sends one interface, or the subset to split across', async () => {
      api.network.mockResolvedValue(net)
      renderDialog()
      await openMore()
      await userEvent.selectOptions(await screen.findByLabelText(en.addDialog.network), 'single')
      await userEvent.selectOptions(screen.getByRole('combobox', { name: en.addDialog.modeSingle }), 'en1')
      await userEvent.type(urlField(), 'https://e/a.iso')
      await userEvent.click(primary(new RegExp(`^${adding.adding.continue}`)))
      await vi.waitFor(() => expect(api.add).toHaveBeenCalledWith(expect.objectContaining({ network: 'single:en1' })))
    })

    it('hides the choice with fewer than two usable interfaces', async () => {
      api.network.mockResolvedValue({ ...net, adapters: [net.adapters[0]!] })
      renderDialog()
      await openMore()
      await vi.waitFor(() => expect(api.network).toHaveBeenCalled())
      expect(screen.queryByLabelText(en.addDialog.network)).toBeNull()
    })
  })

  describe('more options', () => {
    it('sends a sequential download and a start time', async () => {
      renderDialog()
      await userEvent.click(screen.getByRole('button', { name: adding.adding.moreOptions }))
      await userEvent.click(screen.getByRole('switch', { name: en.queue.sequential }))
      await userEvent.click(screen.getByRole('radio', { name: 'Tonight 01:00' }))
      await userEvent.type(urlField(), 'notalink')
      await userEvent.click(primary(new RegExp(`^${en.addDialog.submit}`)))
      expect(api.add).toHaveBeenCalledWith(expect.objectContaining({ sequential: true, startAt: expect.any(Number) }))
    })

    it('blocks the add while a custom start is in the past', async () => {
      renderDialog()
      await userEvent.click(screen.getByRole('button', { name: adding.adding.moreOptions }))
      await userEvent.click(screen.getByRole('radio', { name: en.queue.startCustom }))
      fireEvent.change(screen.getByLabelText(en.queue.startCustom, { selector: 'input' }), {
        target: { value: '2001-01-01T10:00' },
      })
      await userEvent.type(urlField(), 'notalink')
      expect(primary(new RegExp(`^${en.addDialog.submit}`))).toBeDisabled()
    })
  })
})
