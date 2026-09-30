import { screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import en from '../locales/en.json'
import type { NetworkState } from '../lib/types'
import { renderWithI18n } from '../test/renderWithI18n'
import { SettingsView } from './SettingsView'

const api = vi.hoisted(() => ({ network: vi.fn(), updateNetwork: vi.fn(), logout: vi.fn() }))
const boot = vi.hoisted(() => ({ host: 'mac' as 'mac' | 'linux', hostname: 'studio' }))

vi.mock('../lib/api', async (importOriginal) => {
  const real = await importOriginal<typeof import('../lib/api')>()
  return { ...real, api }
})

vi.mock('../lib/boot', async (importOriginal) => {
  const real = await importOriginal<typeof import('../lib/boot')>()
  return {
    ...real,
    get BOOT() {
      return { ...real.BOOT, ...boot }
    },
  }
})

const NET: NetworkState = {
  aggregation: false,
  streamsPerAdapter: 2,
  selected: [],
  reason: null,
  locked: false,
  adapters: [
    { name: 'en0', label: 'Wi-Fi', type: 'wifi', ipv4: '10.0.0.2', expensive: false, eligible: true },
    { name: 'en1', label: 'Ethernet', type: 'wired', ipv4: '10.0.1.2', expensive: false, eligible: true },
  ],
}

function renderView() {
  const onDirtyChange = vi.fn()
  renderWithI18n(
    <SettingsView theme="auto" onTheme={vi.fn()} canWrite onToast={vi.fn()} onDirtyChange={onDirtyChange} />,
  )
  return { onDirtyChange }
}

beforeEach(() => {
  boot.host = 'mac'
  boot.hostname = 'studio'
  api.network.mockReset().mockResolvedValue(NET)
  api.updateNetwork.mockReset().mockImplementation(async (body: { streams?: number }) => ({
    ...NET,
    streamsPerAdapter: body.streams ?? NET.streamsPerAdapter,
  }))
})

describe('SettingsView', () => {
  it('groups browser-only settings apart from the server ones, named by host', async () => {
    renderView()
    expect(screen.getByRole('heading', { name: en.settings.group.browser })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: /Server · studio/ })).toHaveTextContent(
      en.settings.group.everyClient,
    )
    expect(screen.getByText(en.settings.desktop.desc)).toBeInTheDocument()
    await screen.findByText(en.settings.network.interfaces)
  })

  it('points a Linux server at goel config instead of a desktop app', async () => {
    boot.host = 'linux'
    renderView()
    expect(screen.getByText(en.settings.subtitleLinux)).toBeInTheDocument()
    expect(screen.getByText('/etc/goel/config')).toBeInTheDocument()
    expect(screen.queryByText(en.settings.desktop.desc)).toBeNull()
    await screen.findByText(en.settings.network.interfaces)
  })

  it('reports unsaved network edits, and clears them on Save', async () => {
    const { onDirtyChange } = renderView()
    const streams = await screen.findByRole('combobox')
    expect(screen.queryByText(en.settings.unsaved)).toBeNull()
    await userEvent.selectOptions(streams, '4')
    expect(screen.getByText(en.settings.unsaved)).toBeInTheDocument()
    expect(onDirtyChange).toHaveBeenLastCalledWith(true)
    await userEvent.click(screen.getByRole('button', { name: en.common.save }))
    expect(api.updateNetwork).toHaveBeenCalledWith({ adapters: [], streams: 4 })
    await waitFor(() => expect(onDirtyChange).toHaveBeenLastCalledWith(false))
    expect(screen.getByText(en.settings.saved)).toBeInTheDocument()
  })

  it('Discard puts the interface ticks back', async () => {
    renderView()
    const wifi = await screen.findByRole('checkbox', { name: /Wi-Fi/ })
    await userEvent.click(wifi)
    expect(wifi).not.toBeChecked()
    await userEvent.click(screen.getByRole('button', { name: en.settings.discard }))
    expect(wifi).toBeChecked()
    expect(api.updateNetwork).not.toHaveBeenCalled()
  })
})
