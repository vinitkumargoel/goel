import { screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import en from '../../locales/en.json'
import type { NetworkState } from '../../lib/types'
import { renderWithI18n } from '../../test/renderWithI18n'
import { NetworkCard } from './NetworkCard'

const api = vi.hoisted(() => ({ network: vi.fn(), updateNetwork: vi.fn() }))

vi.mock('../../lib/api', async (importOriginal) => {
  const real = await importOriginal<typeof import('../../lib/api')>()
  return { ...real, api }
})

const NET: NetworkState = {
  aggregation: true,
  streamsPerAdapter: 2,
  selected: [],
  reason: null,
  locked: false,
  adapters: [
    { name: 'en0', label: 'Wi-Fi', type: 'wifi', ipv4: '10.0.0.2', expensive: false, eligible: true },
    { name: 'en5', label: 'Ethernet', type: 'wired', ipv4: null, expensive: false, eligible: true },
    { name: 'pdp_ip0', label: 'Cellular', type: 'cellular', ipv4: '172.20.1.4', expensive: true, eligible: false },
  ],
}

function renderCard(net: Partial<NetworkState> = {}, canWrite = true) {
  api.network.mockResolvedValue({ ...NET, ...net })
  const onToast = vi.fn()
  const onDirty = vi.fn()
  renderWithI18n(<NetworkCard canWrite={canWrite} onToast={onToast} onDirty={onDirty} />)
  return { onToast, onDirty }
}

beforeEach(() => {
  api.network.mockReset()
  api.updateNetwork
    .mockReset()
    .mockImplementation(async ({ adapters, streams, ...rest }: { adapters?: string[]; streams?: number }) => ({
      ...NET,
      ...rest,
      selected: adapters ?? NET.selected,
      streamsPerAdapter: streams ?? NET.streamsPerAdapter,
    }))
})

describe('NetworkCard', () => {
  it('says while it loads and when it cannot read the configuration', async () => {
    api.network.mockReturnValue(new Promise(() => {}))
    renderWithI18n(<NetworkCard canWrite onToast={vi.fn()} />)
    expect(screen.getByRole('status')).toHaveTextContent(en.settings.network.loading)
  })

  it('shows the read error', async () => {
    api.network.mockRejectedValue(new Error('down'))
    renderWithI18n(<NetworkCard canWrite onToast={vi.fn()} />)
    expect(await screen.findByRole('alert')).toHaveTextContent(en.settings.network.readError)
  })

  it('lists the interfaces with their address, metered and unavailable ones marked', async () => {
    renderCard()
    expect(await screen.findByRole('checkbox', { name: /Wi-Fi/ })).toBeChecked()
    expect(screen.getByText('10.0.0.2')).toBeInTheDocument()
    expect(screen.getByText(en.adapter.noAddress)).toBeInTheDocument()
    expect(screen.getByText(en.adapter.metered)).toBeInTheDocument()
    expect(screen.getByText(en.settings.network.unavailable)).toBeInTheDocument()
    expect(screen.getByRole('checkbox', { name: /Cellular/ })).toBeDisabled()
  })

  it('switches splitting at once, adopting what the server echoes', async () => {
    renderCard()
    const sw = await screen.findByRole('switch', { name: en.settings.network.splitName })
    expect(sw).toHaveAttribute('aria-checked', 'true')
    await userEvent.click(sw)
    expect(api.updateNetwork).toHaveBeenCalledWith({ aggregation: false })
    await waitFor(() => expect(sw).toHaveAttribute('aria-checked', 'false'))
    expect(screen.getByText(en.settings.saved)).toBeInTheDocument()
  })

  it('offers no switch with one usable interface, and says why', async () => {
    renderCard({ adapters: [NET.adapters[0]!], aggregation: false })
    expect(await screen.findByText(en.settings.network.splitDescSingle)).toBeInTheDocument()
    expect(screen.queryByRole('switch')).toBeNull()
    expect(screen.getByText(en.common.off)).toBeInTheDocument()
  })

  it('shows why splitting is not happening, and a config lock', async () => {
    renderCard({ reason: 'only one route', locked: true })
    expect(await screen.findByText(/Not splitting right now — only one route/)).toBeInTheDocument()
    expect(screen.getByText('/etc/goel/config')).toBeInTheDocument()
  })

  it('sends only the ticked interfaces when not all are ticked', async () => {
    const { onDirty } = renderCard()
    await userEvent.click(await screen.findByRole('checkbox', { name: /Ethernet/ }))
    expect(onDirty).toHaveBeenLastCalledWith(true)
    await userEvent.click(screen.getByRole('button', { name: en.common.save }))
    expect(api.updateNetwork).toHaveBeenCalledWith({ adapters: ['en0'], streams: 2 })
  })

  it('will not save with nothing ticked', async () => {
    renderCard()
    await userEvent.click(await screen.findByRole('checkbox', { name: /Wi-Fi/ }))
    await userEvent.click(screen.getByRole('checkbox', { name: /Ethernet/ }))
    const save = screen.getByRole('button', { name: en.common.save })
    expect(save).toBeDisabled()
    expect(save).toHaveAttribute('title', en.settings.network.tickAtLeastOne)
  })

  it('warns when the server refuses, and keeps the edits', async () => {
    api.updateNetwork.mockRejectedValue(new Error('Refused'))
    const { onToast } = renderCard()
    await userEvent.selectOptions(await screen.findByDisplayValue('2'), '5')
    await userEvent.click(screen.getByRole('button', { name: en.common.save }))
    await waitFor(() => expect(onToast).toHaveBeenCalledWith(expect.any(String), 'warn'))
    expect(screen.getByText(en.settings.unsaved)).toBeInTheDocument()
  })

  it('is view-only for a read-only session', async () => {
    renderCard({}, false)
    expect(await screen.findByRole('checkbox', { name: /Wi-Fi/ })).toBeDisabled()
    expect(screen.getByDisplayValue('2')).toBeDisabled()
    expect(screen.queryByRole('switch')).toBeNull()
    expect(screen.queryByText(en.settings.network.applyDesc)).toBeNull()
  })
})
