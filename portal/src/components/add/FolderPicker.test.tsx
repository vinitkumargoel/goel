import { screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiError } from '../../lib/api'
import type { FolderListing } from '../../lib/types'
import en from '../../locales/en.json'
import { renderWithI18n } from '../../test/renderWithI18n'
import { FolderPicker, folderLabel } from './FolderPicker'

const api = vi.hoisted(() => ({ folders: vi.fn(), createFolder: vi.fn() }))

vi.mock('../../lib/api', async (importOriginal) => {
  const real = await importOriginal<typeof import('../../lib/api')>()
  return { ...real, api }
})

const listing = (over: Partial<FolderListing> = {}): FolderListing => ({
  path: '/home/me/Downloads',
  parent: '/home/me',
  folders: [
    { name: 'Films', path: '/home/me/Downloads/Films', readable: true, writable: true },
    { name: 'Locked', path: '/home/me/Downloads/Locked', readable: false, writable: false },
  ],
  writable: true,
  home: '/home/me',
  defaultFolder: '/home/me/Downloads',
  places: [
    { name: 'Home', path: '/home/me', readable: true, writable: true },
    { name: 'Downloads', path: '/home/me/Downloads', readable: true, writable: true },
    { name: 'Root', path: '/root', readable: false, writable: false },
  ],
  ...over,
})

beforeEach(() => {
  api.folders.mockReset().mockResolvedValue(listing())
  api.createFolder.mockReset()
})

function renderPicker(over: Partial<Parameters<typeof FolderPicker>[0]> = {}) {
  const props = { initialPath: '', canCreate: true, onPick: vi.fn(), onClose: vi.fn(), onWarn: vi.fn(), ...over }
  renderWithI18n(<FolderPicker {...props} />)
  return props
}

describe('FolderPicker', () => {
  it('lists the folders, greyed exactly where the server says they cannot be read', async () => {
    renderPicker()
    const dialog = screen.getByRole('dialog', { name: en.folderPicker.title })
    expect(within(dialog).getByText(en.common.loading)).toBeInTheDocument()
    expect(await screen.findByText('Home / Downloads')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Films/ })).toBeEnabled()
    const locked = screen.getByRole('button', { name: /Locked/ })
    expect(locked).toBeDisabled()
    expect(locked).toHaveTextContent(en.folderPicker.noAccess)
    expect(locked).toHaveAttribute('title', '/home/me/Downloads/Locked — no permission to open')
    expect(screen.getByRole('button', { name: 'Root' })).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Downloads' })).toHaveAttribute('aria-pressed', 'true')
    expect(api.folders).toHaveBeenCalledWith(undefined)
  })

  it('opens folders, goes up, and picks the one shown', async () => {
    api.folders.mockImplementation((path?: string) =>
      Promise.resolve(
        path === '/home/me/Downloads/Films'
          ? listing({ path, parent: '/home/me/Downloads', folders: [] })
          : path === '/home/me'
            ? listing({ path, parent: '/home', folders: [] })
            : listing(),
      ),
    )
    const props = renderPicker({ initialPath: '/home/me/Downloads' })
    await userEvent.click(await screen.findByRole('button', { name: /Films/ }))
    expect(await screen.findByText(`${en.folderPicker.noSubfolders} ${en.folderPicker.useOrCreate}`)).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: en.folderPicker.usePick }))
    expect(props.onPick).toHaveBeenCalledWith('/home/me/Downloads/Films', expect.objectContaining({ home: '/home/me' }))

    await userEvent.click(screen.getAllByRole('button', { name: en.folderPicker.upOneLevel })[0]!)
    expect(api.folders).toHaveBeenLastCalledWith('/home/me/Downloads')
  })

  it('will not use a folder the server cannot write to', async () => {
    api.folders.mockResolvedValue(listing({ writable: false, folders: [] }))
    renderPicker()
    const use = await screen.findByRole('button', { name: en.folderPicker.usePick })
    await vi.waitFor(() => expect(use).toHaveAttribute('title', en.folderPicker.noWritePermission))
    expect(use).toBeDisabled()
    expect(screen.queryByRole('button', { name: en.folderPicker.newFolder })).toBeNull()
    expect(screen.getByText(`${en.folderPicker.noSubfolders} ${en.folderPicker.useThis}`)).toBeInTheDocument()
  })

  it('offers no new folder in a read-only session', async () => {
    renderPicker({ canCreate: false })
    await screen.findByText('Home / Downloads')
    expect(screen.queryByRole('button', { name: en.folderPicker.newFolder })).toBeNull()
  })

  it('ignores a slow answer that a newer one overtook', async () => {
    let slow: (l: FolderListing) => void = () => {}
    api.folders
      .mockResolvedValueOnce(listing())
      .mockReturnValueOnce(new Promise<FolderListing>((r) => (slow = r)))
      .mockResolvedValueOnce(listing({ path: '/home/me/Downloads/Films', folders: [] }))
    renderPicker()
    await userEvent.click(await screen.findByRole('button', { name: 'Home' }))
    await userEvent.click(screen.getByRole('button', { name: /Films/ }))
    await screen.findByText('Home / Downloads / Films')
    slow(listing({ path: '/home/me', folders: [] }))
    await new Promise((r) => setTimeout(r, 0))
    expect(screen.getByText('Home / Downloads / Films')).toBeInTheDocument()
  })

  it('falls back to the default folder when the start path cannot be opened', async () => {
    api.folders.mockRejectedValueOnce(new ApiError('http', 'No such folder', 404)).mockResolvedValue(listing())
    const props = renderPicker({ initialPath: '/gone' })
    expect(await screen.findByText('Home / Downloads')).toBeInTheDocument()
    expect(api.folders).toHaveBeenNthCalledWith(1, '/gone')
    expect(api.folders).toHaveBeenNthCalledWith(2, undefined)
    expect(props.onWarn).toHaveBeenCalledWith('No such folder')
  })

  it('says when nothing could be listed', async () => {
    api.folders.mockRejectedValue('boom')
    const props = renderPicker()
    expect(await screen.findByText(en.folderPicker.readError)).toBeInTheDocument()
    expect(props.onWarn).toHaveBeenCalledWith(en.folderPicker.listError)
    expect(screen.getByRole('button', { name: en.folderPicker.usePick })).toBeDisabled()
  })

  it('makes a new folder and opens it; Escape leaves the name field first', async () => {
    api.createFolder.mockResolvedValue({ path: '/home/me/Downloads/New' })
    const props = renderPicker()
    await userEvent.click(await screen.findByRole('button', { name: en.folderPicker.newFolder }))
    const name = screen.getByRole('textbox', { name: en.folderPicker.newFolderPlaceholder })
    expect(name).toHaveFocus()
    await userEvent.click(screen.getByRole('button', { name: en.common.create }))
    expect(props.onWarn).toHaveBeenCalledWith(en.folderPicker.nameFirst)
    await userEvent.type(name, 'New{Enter}')
    expect(api.createFolder).toHaveBeenCalledWith({ name: 'New', parent: '/home/me/Downloads' })
    await vi.waitFor(() => expect(api.folders).toHaveBeenLastCalledWith('/home/me/Downloads/New'))

    await userEvent.click(screen.getByRole('button', { name: en.folderPicker.newFolder }))
    await userEvent.keyboard('{Escape}')
    expect(screen.queryByRole('textbox', { name: en.folderPicker.newFolderPlaceholder })).toBeNull()
    expect(props.onClose).not.toHaveBeenCalled()
    await userEvent.keyboard('{Escape}')
    expect(props.onClose).toHaveBeenCalled()
  })

  it('does not report a refused folder twice', async () => {
    api.createFolder.mockRejectedValue(new ApiError('refused', 'Read-only', 403))
    const props = renderPicker()
    await userEvent.click(await screen.findByRole('button', { name: en.folderPicker.newFolder }))
    await userEvent.type(screen.getByRole('textbox', { name: en.folderPicker.newFolderPlaceholder }), 'x{Enter}')
    await new Promise((r) => setTimeout(r, 0))
    expect(props.onWarn).not.toHaveBeenCalled()
  })
})

describe('folderLabel', () => {
  it('reads paths from home and the computer', () => {
    expect(folderLabel('/', null)).toBe(en.folderPicker.computer)
    expect(folderLabel('/home/me', '/home/me/')).toBe(en.folderPicker.home)
    expect(folderLabel('/home/me/a/b', '/home/me')).toBe('Home / a / b')
    expect(folderLabel('/srv/films', '/home/me')).toBe('srv / films')
  })
})
