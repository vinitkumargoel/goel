import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import en from '../../locales/en.json'
import type { NetworkState } from '../../lib/types'
import { renderWithI18n } from '../../test/renderWithI18n'
import { SettingsView } from './SettingsView'

const api = vi.hoisted(() => ({
  network: vi.fn(),
  updateNetwork: vi.fn(),
  logout: vi.fn(),
  // The schedule card has its own tests; here it stays loading, so it renders nothing.
  schedule: vi.fn(() => new Promise(() => {})),
  updateSchedule: vi.fn(),
  // The server-settings cards have their own tests; here they stay loading and render nothing.
  serverSettings: vi.fn(() => new Promise(() => {})),
  rules: vi.fn(() => new Promise(() => {})),
  updateServerSettings: vi.fn(),
}))
const boot = vi.hoisted(() => ({ host: 'mac' as 'mac' | 'linux', hostname: 'studio', readOnly: false, username: 'vinit' }))
const theme = vi.hoisted(() => ({ applyTheme: vi.fn() }))

vi.mock('../../lib/api', async (importOriginal) => {
  const real = await importOriginal<typeof import('../../lib/api')>()
  return { ...real, api }
})

vi.mock('../../lib/boot', async (importOriginal) => {
  const real = await importOriginal<typeof import('../../lib/boot')>()
  return {
    ...real,
    get BOOT() {
      return { ...real.BOOT, ...boot }
    },
  }
})

vi.mock('../../lib/theme', async (importOriginal) => {
  const real = await importOriginal<typeof import('../../lib/theme')>()
  return { ...real, applyTheme: theme.applyTheme }
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

function renderView(over: Partial<Parameters<typeof SettingsView>[0]> = {}) {
  const props = {
    theme: 'auto' as const,
    onTheme: vi.fn(),
    canWrite: true,
    onToast: vi.fn(),
    onDirtyChange: vi.fn(),
    ...over,
  }
  const view = renderWithI18n(<SettingsView {...props} />)
  return { ...props, ...view }
}

beforeEach(() => {
  boot.host = 'mac'
  boot.hostname = 'studio'
  boot.readOnly = false
  theme.applyTheme.mockReset()
  api.logout.mockReset()
  api.schedule.mockClear()
  api.network.mockReset().mockResolvedValue(NET)
  api.updateNetwork.mockReset().mockImplementation(async (body: { streams?: number; aggregation?: boolean }) => ({
    ...NET,
    streamsPerAdapter: body.streams ?? NET.streamsPerAdapter,
    aggregation: body.aggregation ?? NET.aggregation,
  }))
})

describe('SettingsView', () => {
  it('groups browser-only settings apart from the server ones, named by host', async () => {
    renderView()
    expect(screen.getByRole('heading', { name: en.settings.group.browser })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: /Server · studio/ })).toHaveTextContent(en.settings.group.everyClient)
    expect(screen.getByText(en.settings.subtitle)).toBeInTheDocument()
    expect(screen.getByText(en.settings.desktop.desc)).toBeInTheDocument()
    await screen.findByText(en.settings.network.interfaces)
  })

  it('names the server group plainly when the host has no name', async () => {
    boot.hostname = ''
    renderView()
    expect(screen.getByRole('heading', { name: /^Server/ })).not.toHaveTextContent('·')
    await screen.findByText(en.settings.network.interfaces)
  })

  it('points a Linux server at goel config instead of a desktop app', async () => {
    boot.host = 'linux'
    renderView()
    expect(screen.getByText(en.settings.subtitleLinux)).toBeInTheDocument()
    expect(screen.getByText('/etc/goel/config')).toBeInTheDocument()
    expect(screen.queryByText(en.settings.desktop.desc)).toBeNull()
    await screen.findByText(en.settings.network.interfaces)
    // The Linux daemon runs the same scheduler as the desktop app, so the card is asked for there too.
    expect(api.schedule).toHaveBeenCalled()
  })

  it('picks a theme from the tiles, persists it and says so', async () => {
    const { onTheme, onToast } = renderView({ theme: 'light' })
    const tiles = screen.getByRole('radiogroup', { name: en.settings.theme.name })
    expect(within(tiles).getByRole('radio', { name: en.settings.theme.light })).toHaveAttribute('aria-checked', 'true')
    await userEvent.click(within(tiles).getByRole('radio', { name: en.settings.theme.dark }))
    expect(theme.applyTheme).toHaveBeenCalledWith('dark', true)
    expect(onTheme).toHaveBeenCalledWith('dark')
    expect(onToast).toHaveBeenCalledWith('Theme: Dark')
    await screen.findByText(en.settings.network.interfaces)
  })

  it('moves between theme tiles with the arrow keys', async () => {
    const { onTheme } = renderView({ theme: 'light' })
    const light = screen.getByRole('radio', { name: en.settings.theme.light })
    expect(light).toHaveAttribute('tabindex', '0')
    expect(screen.getByRole('radio', { name: 'Match system' })).toHaveAttribute('tabindex', '-1')
    light.focus()
    await userEvent.keyboard('{ArrowLeft}')
    expect(onTheme).toHaveBeenCalledWith('auto')
    await screen.findByText(en.settings.network.interfaces)
  })

  it('offers the panel auto-hide switch only when App handles it', async () => {
    const onPanelAutoHide = vi.fn()
    renderView({ panelAutoHide: false, onPanelAutoHide })
    const sw = screen.getByRole('switch', { name: en.settings.panel.name })
    expect(sw).toHaveAttribute('aria-checked', 'false')
    await userEvent.click(sw)
    expect(onPanelAutoHide).toHaveBeenCalledWith(true)
    await screen.findByText(en.settings.network.interfaces)
  })

  it('has no panel switch without the handler', async () => {
    renderView()
    expect(screen.queryByRole('switch', { name: en.settings.panel.name })).toBeNull()
    await screen.findByText(en.settings.network.interfaces)
  })

  it('shows who is signed in with what access, and signs out', async () => {
    renderView()
    expect(screen.getByText(en.settings.access.fullControl)).toBeInTheDocument()
    expect(screen.getByText('vinit')).toBeInTheDocument()
    expect(screen.getByText(en.settings.access.descFull)).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: en.common.signOut }))
    expect(api.logout).toHaveBeenCalled()
    await screen.findByText(en.settings.network.interfaces)
  })

  it('says a read-only session is read-only', async () => {
    boot.readOnly = true
    renderView({ canWrite: false })
    expect(screen.getByText(en.settings.access.readOnly)).toBeInTheDocument()
    expect(screen.getByText(en.settings.access.descReadOnly)).toBeInTheDocument()
    // Nothing on the server can change: no Save strip can appear, the streams select is locked.
    expect(await screen.findByDisplayValue('2')).toBeDisabled()
  })

  it('reports unsaved network edits, and clears them on Save', async () => {
    const { onDirtyChange } = renderView()
    // By value: the Language select in This browser is a combobox too.
    const streams = await screen.findByDisplayValue('2')
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

  it('reports nothing pending once it unmounts', async () => {
    const { onDirtyChange, unmount } = renderView()
    await userEvent.selectOptions(await screen.findByDisplayValue('2'), '3')
    expect(onDirtyChange).toHaveBeenLastCalledWith(true)
    unmount()
    expect(onDirtyChange).toHaveBeenLastCalledWith(false)
  })
})
