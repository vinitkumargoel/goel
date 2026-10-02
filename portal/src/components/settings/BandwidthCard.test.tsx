import { screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import type { Bandwidth } from '../../hooks/useBandwidth'
import en from '../../locales/en.json'
import type { BandwidthState } from '../../lib/bandwidth'
import { renderWithI18n } from '../../test/renderWithI18n'
import { BandwidthCard } from './BandwidthCard'

const STATE: BandwidthState = {
  enabled: true,
  selected: 'Medium',
  profiles: [
    { name: 'Low', downBytesPerSec: 512 * 1024, upBytesPerSec: null },
    { name: 'Medium', downBytesPerSec: 2 * 1024 * 1024, upBytesPerSec: 500 * 1024 },
  ],
}

function renderCard(over: Partial<Bandwidth> = {}, canWrite = true) {
  const bandwidth: Bandwidth = {
    status: 'ready',
    state: STATE,
    update: vi.fn(async () => null),
    ...over,
  }
  const onToast = vi.fn()
  const onDirty = vi.fn()
  const view = renderWithI18n(
    <BandwidthCard bandwidth={bandwidth} canWrite={canWrite} onToast={onToast} onDirty={onDirty} />,
  )
  return { ...view, bandwidth, onToast, onDirty }
}

/** The caps editor shows one profile at a time; this picks which. */
async function edit(name: string) {
  const which = screen.getByRole('radiogroup', { name: 'Profile to edit' })
  await userEvent.click(within(which).getByRole('radio', { name }))
}

describe('BandwidthCard', () => {
  it('renders nothing for a daemon without the feature', () => {
    const { container } = renderCard({ status: 'unsupported', state: null })
    expect(container).toBeEmptyDOMElement()
  })

  it('says while it loads and when it cannot read the settings', () => {
    const { unmount } = renderCard({ status: 'loading', state: null })
    expect(screen.getByRole('status')).toHaveTextContent(en.settings.bandwidth.loading)
    unmount()
    renderCard({ status: 'error', state: null })
    expect(screen.getByRole('alert')).toHaveTextContent(en.settings.bandwidth.readError)
  })

  it('shows each profile as a card with its caps, the one in use marked', () => {
    renderCard()
    const profiles = screen.getByRole('group', { name: en.settings.bandwidth.profileName })
    const medium = within(profiles).getByRole('button', { name: /Medium/ })
    expect(medium).toHaveAttribute('aria-pressed', 'true')
    expect(medium).toHaveTextContent('In use')
    expect(within(profiles).getByRole('button', { name: /Low/ })).toHaveTextContent('↓ 512 KB/s · ↑ no cap')
  })

  it('shows caps in editable units, blank for no cap, starting on the profile in use', async () => {
    renderCard()
    expect(screen.getByLabelText('Download cap for Medium')).toHaveValue('2')
    expect(screen.getByLabelText('Unit for Download cap for Medium')).toHaveValue('MB')
    await edit('Low')
    expect(screen.getByLabelText('Download cap for Low')).toHaveValue('512')
    expect(screen.getByLabelText('Unit for Download cap for Low')).toHaveValue('KB')
    expect(screen.getByLabelText('Upload cap for Low')).toHaveValue('')
  })

  it('switches limits and the profile at once, confirming beside the control', async () => {
    const { bandwidth, onToast } = renderCard()
    await userEvent.click(screen.getByRole('switch', { name: new RegExp(en.settings.bandwidth.enabledName) }))
    expect(bandwidth.update).toHaveBeenCalledWith({ enabled: false })
    await userEvent.click(screen.getByRole('button', { name: /Low/ }))
    expect(bandwidth.update).toHaveBeenCalledWith({ selected: 'Low' })
    expect(screen.getAllByText(en.settings.saved).length).toBeGreaterThan(0)
    expect(onToast).not.toHaveBeenCalled()
    // Picking a profile also opens its caps.
    expect(screen.getByLabelText('Download cap for Low')).toBeInTheDocument()
  })

  it('does not re-send the profile already in use', async () => {
    const { bandwidth } = renderCard()
    await userEvent.click(screen.getByRole('button', { name: /Medium/ }))
    expect(bandwidth.update).not.toHaveBeenCalled()
  })

  it('warns with the message the update failed with', async () => {
    const { onToast } = renderCard({ update: vi.fn(async () => 'Nope') })
    await userEvent.click(screen.getByRole('button', { name: /Low/ }))
    expect(onToast).toHaveBeenCalledWith('Nope', 'warn')
  })

  it('stays quiet about a failure the api layer already reported', async () => {
    const { onToast } = renderCard({ update: vi.fn(async () => '') })
    await userEvent.click(screen.getByRole('button', { name: /Low/ }))
    expect(onToast).not.toHaveBeenCalled()
  })

  it('saves edited caps of every profile as bytes per second, blank as unlimited', async () => {
    const { bandwidth, onDirty } = renderCard()
    // No edits, no strip: Save only exists while something is pending.
    expect(screen.queryByRole('button', { name: en.common.save })).toBeNull()
    await edit('Low')
    await userEvent.clear(screen.getByLabelText('Download cap for Low'))
    expect(screen.getByText(en.settings.unsaved)).toBeInTheDocument()
    expect(onDirty).toHaveBeenLastCalledWith(true)
    await userEvent.type(screen.getByLabelText('Upload cap for Low'), '1.5')
    await userEvent.selectOptions(screen.getByLabelText('Unit for Upload cap for Low'), 'MB')
    await userEvent.click(screen.getByRole('button', { name: en.common.save }))
    expect(bandwidth.update).toHaveBeenCalledWith({
      profiles: [
        { name: 'Low', downBytesPerSec: null, upBytesPerSec: 1572864 },
        { name: 'Medium', downBytesPerSec: 2097152, upBytesPerSec: 512000 },
      ],
    })
    expect(onDirty).toHaveBeenLastCalledWith(false)
    expect(screen.queryByText(en.settings.unsaved)).toBeNull()
  })

  it('keeps edits to one profile while another is shown', async () => {
    renderCard()
    await edit('Low')
    await userEvent.clear(screen.getByLabelText('Download cap for Low'))
    await userEvent.type(screen.getByLabelText('Download cap for Low'), '7')
    await edit('Medium')
    await edit('Low')
    expect(screen.getByLabelText('Download cap for Low')).toHaveValue('7')
  })

  it('discards pending edits back to the saved caps', async () => {
    const { bandwidth, onDirty } = renderCard()
    await edit('Low')
    const field = screen.getByLabelText('Download cap for Low')
    await userEvent.clear(field)
    await userEvent.type(field, '9')
    await userEvent.click(screen.getByRole('button', { name: en.settings.discard }))
    expect(field).toHaveValue('512')
    expect(onDirty).toHaveBeenLastCalledWith(false)
    expect(bandwidth.update).not.toHaveBeenCalled()
  })

  it('refuses a negative cap without posting, and shows the profile it is in', async () => {
    const { bandwidth, onToast } = renderCard()
    await edit('Low')
    const field = screen.getByLabelText('Download cap for Low')
    await userEvent.clear(field)
    await userEvent.type(field, '-3')
    expect(field).toHaveAttribute('aria-invalid', 'true')
    await edit('Medium')
    await userEvent.click(screen.getByRole('button', { name: en.common.save }))
    expect(bandwidth.update).not.toHaveBeenCalled()
    expect(onToast).toHaveBeenCalledWith(en.settings.bandwidth.invalid, 'warn')
    expect(screen.getByLabelText('Download cap for Low')).toHaveAttribute('aria-invalid', 'true')
  })

  it('disables what a policy locks, and says why', () => {
    renderCard({ state: { ...STATE, locked: ['enabled', 'selected'] } })
    expect(screen.getByRole('switch', { name: new RegExp(en.settings.bandwidth.enabledName) })).toBeDisabled()
    expect(screen.getByRole('button', { name: /Low/ })).toBeDisabled()
    expect(screen.getByRole('button', { name: /Low/ })).toHaveAttribute('title', en.settings.bandwidth.managed)
    expect(screen.getAllByText(en.settings.bandwidth.managed).length).toBe(2)
  })

  it('is view-only for a read-only session', async () => {
    renderCard({}, false)
    expect(screen.queryByRole('button', { name: en.common.save })).toBeNull()
    expect(screen.getByRole('switch', { name: new RegExp(en.settings.bandwidth.enabledName) })).toBeDisabled()
    expect(screen.getByRole('button', { name: /Low/ })).toBeDisabled()
    expect(screen.getByLabelText('Download cap for Medium')).toBeDisabled()
    // Still able to look at another profile's caps.
    await edit('Low')
    expect(screen.getByLabelText('Download cap for Low')).toBeDisabled()
  })
})
