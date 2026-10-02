import { screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiError } from '../../lib/api'
import type { ServerSettings } from '../../lib/types'
import en from '../../locales/en.json'
import { renderWithI18n } from '../../test/renderWithI18n'
import { ServerSettingsCards } from './ServerSettingsCards'

const api = vi.hoisted(() => ({ serverSettings: vi.fn(), updateServerSettings: vi.fn() }))

vi.mock('../../lib/api', async (importOriginal) => {
  const real = await importOriginal<typeof import('../../lib/api')>()
  return { ...real, api }
})
vi.mock('../add/FolderPicker', () => ({ FolderPicker: () => null }))

const SETTINGS: ServerSettings = {
  general: {
    defaultSaveDirectory: '/srv/downloads',
    defaultFolderRule: 'fixed',
    existingFileReaction: 'rename',
    maxSimultaneousDownloads: 3,
    profile: 'Medium',
  },
  bittorrent: { encryptionMode: 'prefer', dht: true, pex: true, lpd: true, utp: true, autoDeleteTorrent: false },
}

function renderCards(canWrite = true) {
  const onToast = vi.fn()
  const onDirty = vi.fn()
  const view = renderWithI18n(<ServerSettingsCards canWrite={canWrite} onToast={onToast} onDirty={onDirty} />)
  return { onToast, onDirty, container: view.container }
}

beforeEach(() => {
  api.serverSettings.mockReset().mockResolvedValue(SETTINGS)
  api.updateServerSettings.mockReset().mockImplementation(async (body: { general?: object; bittorrent?: object }) => ({
    general: { ...SETTINGS.general, ...body.general },
    bittorrent: { ...SETTINGS.bittorrent, ...body.bittorrent },
  }))
})

describe('ServerSettingsCards', () => {
  it('renders nothing for a server without editable settings', async () => {
    api.serverSettings.mockRejectedValue(new ApiError('http', 'nope', 404))
    const { container } = renderCards()
    await waitFor(() => expect(api.serverSettings).toHaveBeenCalled())
    expect(container).toBeEmptyDOMElement()
  })

  it('never offers overwrite remotely, so an Add cannot replace the user\'s files', async () => {
    renderCards()
    const group = await screen.findByRole('radiogroup', { name: en.settings.general.exists })
    const overwrite = group.querySelector<HTMLButtonElement>('[data-value="overwrite"]')
    expect(overwrite).toBeDisabled()
  })

  it('saves only the changed fields of the card that was edited', async () => {
    const { onToast, onDirty } = renderCards()
    const toggle = await screen.findByRole('switch', { name: en.settings.bt.dht })
    await userEvent.click(toggle)
    expect(onDirty).toHaveBeenLastCalledWith(true)
    await userEvent.click(screen.getByRole('button', { name: en.common.save }))
    await waitFor(() => expect(api.updateServerSettings).toHaveBeenCalledWith({ bittorrent: { dht: false } }))
    expect(onToast).toHaveBeenCalledWith(en.settings.saved)
    await waitFor(() => expect(onDirty).toHaveBeenLastCalledWith(false))
  })

  it('refuses a bad folder or count before the round trip', async () => {
    renderCards()
    const folder = await screen.findByRole('textbox')
    await userEvent.clear(folder)
    await userEvent.type(folder, 'downloads')
    expect(screen.getByRole('alert')).toHaveTextContent(en.settings.general.folderInvalid)
    expect(screen.getByRole('button', { name: en.common.save })).toBeDisabled()
    await userEvent.clear(folder)
    await userEvent.type(folder, '/data')
    const count = screen.getByRole('spinbutton')
    await userEvent.clear(count)
    await userEvent.type(count, '99')
    expect(screen.getByRole('button', { name: en.common.save })).toBeDisabled()
    await userEvent.clear(count)
    await userEvent.type(count, '4')
    await userEvent.click(screen.getByRole('button', { name: en.common.save }))
    await waitFor(() =>
      expect(api.updateServerSettings).toHaveBeenCalledWith({
        general: { defaultSaveDirectory: '/data', maxSimultaneousDownloads: 4 },
      }),
    )
  })

  it('is read-only without write access', async () => {
    renderCards(false)
    expect(await screen.findByRole('switch', { name: en.settings.bt.dht })).toBeDisabled()
    expect(screen.queryByRole('button', { name: en.common.save })).toBeNull()
  })
})
