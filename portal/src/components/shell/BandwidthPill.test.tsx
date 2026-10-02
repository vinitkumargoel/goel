import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import i18n from '../../i18n'
import type { BandwidthState } from '../../lib/bandwidth'
import { renderWithI18n } from '../../test/renderWithI18n'
import type { MenuItem } from '../ui/Menu'
import { BandwidthPill, bandwidthMenuEntries } from './BandwidthPill'

const STATE: BandwidthState = {
  enabled: true,
  selected: 'Medium',
  profiles: [
    { name: 'Low', downBytesPerSec: 512 * 1024, upBytesPerSec: 64 * 1024 },
    { name: 'Medium', downBytesPerSec: 2 * 1024 * 1024, upBytesPerSec: null },
  ],
}

const items = (state: BandwidthState, onSelect = vi.fn(), onUnlimited = vi.fn()) =>
  bandwidthMenuEntries(state, i18n.t, onSelect, onUnlimited).filter(
    (e): e is MenuItem => !('separator' in e) && !('heading' in e),
  )

describe('BandwidthPill', () => {
  it('names the profile, or the short name when compact, and opens the menu', async () => {
    const onOpen = vi.fn()
    const { rerender } = renderWithI18n(<BandwidthPill state={STATE} canWrite menuOpen={false} onOpen={onOpen} />)
    const pill = screen.getByRole('button', { name: /Profile: Medium/ })
    expect(pill).toHaveClass('lim')
    await userEvent.click(pill)
    expect(onOpen).toHaveBeenCalled()
    rerender(<BandwidthPill state={STATE} canWrite compact menuOpen onOpen={onOpen} />)
    const compact = screen.getByRole('button', { name: 'Medium' })
    expect(compact).toHaveAttribute('aria-expanded', 'true')
    expect(compact).toHaveAttribute('title', 'Profile: Medium')
  })
})

describe('bandwidthMenuEntries', () => {
  it('lists each profile with its caps and checks the active one', () => {
    const [low, medium, unlimited] = items(STATE)
    expect(low?.detail).toBe('↓ 512 KB/s · ↑ 64 KB/s')
    expect(medium?.detail).toBe('↓ 2.0 MB/s · ↑ no cap')
    expect(medium?.checked).toBe(true)
    expect(low?.checked).toBe(false)
    expect(unlimited?.checked).toBe(false)
  })

  it('checks Unlimited, and no profile, while limits are off', () => {
    const all = items({ ...STATE, enabled: false })
    expect(all.filter((e) => e.checked).map((e) => e.key)).toEqual(['unlimited'])
  })

  it('wires picks to the callbacks', () => {
    const onSelect = vi.fn()
    const onUnlimited = vi.fn()
    const [low, , unlimited] = items(STATE, onSelect, onUnlimited)
    low?.action()
    unlimited?.action()
    expect(onSelect).toHaveBeenCalledWith('Low')
    expect(onUnlimited).toHaveBeenCalled()
  })

  it('disables what a policy has locked', () => {
    const locked = items({ ...STATE, locked: ['selected'] })
    expect(locked.slice(0, 2).every((e) => e.disabled)).toBe(true)
    expect(locked[2]?.disabled).toBe(false)
    expect(locked[0]?.detail).toContain('Managed by your organization')
    const toggle = items({ ...STATE, locked: ['enabled'] })
    expect(toggle[2]?.disabled).toBe(true)
    expect(toggle[0]?.disabled).toBe(false)
  })
})
