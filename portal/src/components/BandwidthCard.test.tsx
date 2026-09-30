import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import type { Bandwidth } from '../hooks/useBandwidth'
import en from '../locales/en.json'
import type { BandwidthState } from '../lib/bandwidth'
import { renderWithI18n } from '../test/renderWithI18n'
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

describe('BandwidthCard', () => {
  it('renders nothing for a daemon without the feature', () => {
    const { container } = renderCard({ status: 'unsupported', state: null })
    expect(container).toBeEmptyDOMElement()
  })

  it('shows caps in editable units, blank for no cap', () => {
    renderCard()
    expect(screen.getByLabelText('Download cap for Low')).toHaveValue('512')
    expect(screen.getByLabelText('Unit for Download cap for Low')).toHaveValue('KB')
    expect(screen.getByLabelText('Download cap for Medium')).toHaveValue('2')
    expect(screen.getByLabelText('Unit for Download cap for Medium')).toHaveValue('MB')
    expect(screen.getByLabelText('Upload cap for Low')).toHaveValue('')
  })

  it('switches limits and the profile at once, confirming beside the control', async () => {
    const { bandwidth, onToast } = renderCard()
    await userEvent.click(screen.getByRole('button', { name: en.common.turnOff }))
    expect(bandwidth.update).toHaveBeenCalledWith({ enabled: false })
    await userEvent.selectOptions(screen.getByLabelText(en.settings.bandwidth.profileName), 'Low')
    expect(bandwidth.update).toHaveBeenCalledWith({ selected: 'Low' })
    expect(screen.getAllByText(en.settings.saved).length).toBeGreaterThan(0)
    expect(onToast).not.toHaveBeenCalled()
  })

  it('saves edited caps as bytes per second, blank as unlimited', async () => {
    const { bandwidth, onDirty } = renderCard()
    // No edits, no strip: Save only exists while something is pending.
    expect(screen.queryByRole('button', { name: en.common.save })).toBeNull()
    await userEvent.clear(screen.getByLabelText('Download cap for Low'))
    expect(screen.getByText(en.settings.unsaved)).toBeInTheDocument()
    expect(onDirty).toHaveBeenLastCalledWith(true)
    const save = screen.getByRole('button', { name: en.common.save })
    await userEvent.type(screen.getByLabelText('Upload cap for Low'), '1.5')
    await userEvent.selectOptions(screen.getByLabelText('Unit for Upload cap for Low'), 'MB')
    await userEvent.click(save)
    expect(bandwidth.update).toHaveBeenCalledWith({
      profiles: [
        { name: 'Low', downBytesPerSec: null, upBytesPerSec: 1572864 },
        { name: 'Medium', downBytesPerSec: 2097152, upBytesPerSec: 512000 },
      ],
    })
    expect(onDirty).toHaveBeenLastCalledWith(false)
    expect(screen.queryByText(en.settings.unsaved)).toBeNull()
  })

  it('discards pending edits back to the saved caps', async () => {
    const { bandwidth, onDirty } = renderCard()
    const field = screen.getByLabelText('Download cap for Low')
    await userEvent.clear(field)
    await userEvent.type(field, '9')
    await userEvent.click(screen.getByRole('button', { name: en.settings.discard }))
    expect(field).toHaveValue('512')
    expect(onDirty).toHaveBeenLastCalledWith(false)
    expect(bandwidth.update).not.toHaveBeenCalled()
  })

  it('refuses a negative cap without posting', async () => {
    const { bandwidth, onToast } = renderCard()
    const field = screen.getByLabelText('Download cap for Low')
    await userEvent.clear(field)
    await userEvent.type(field, '-3')
    expect(field).toHaveAttribute('aria-invalid', 'true')
    await userEvent.click(screen.getByRole('button', { name: en.common.save }))
    expect(bandwidth.update).not.toHaveBeenCalled()
    expect(onToast).toHaveBeenCalledWith(en.settings.bandwidth.invalid, 'warn')
  })

  it('disables what a policy locks, and says why', () => {
    renderCard({ state: { ...STATE, locked: ['enabled', 'selected'] } })
    expect(screen.getByRole('button', { name: en.common.turnOff })).toBeDisabled()
    expect(screen.getByLabelText(new RegExp(en.settings.bandwidth.profileName))).toBeDisabled()
    expect(screen.getAllByText(en.settings.bandwidth.managed).length).toBeGreaterThan(0)
  })

  it('is view-only for a read-only session', () => {
    renderCard({}, false)
    expect(screen.queryByRole('button', { name: en.common.save })).toBeNull()
    expect(screen.getByLabelText('Download cap for Low')).toBeDisabled()
  })
})
