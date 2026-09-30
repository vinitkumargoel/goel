import { describe, expect, it } from 'vitest'
import { capSummary, fromField, isBandwidthState, toField } from './bandwidth'

describe('capSummary', () => {
  it('shows both directions, with the no-cap word for unlimited', () => {
    expect(
      capSummary({ name: 'M', downBytesPerSec: 2 * 1024 * 1024, upBytesPerSec: 500 * 1024 }, 'no cap'),
    ).toBe('↓ 2.0 MB/s · ↑ 500 KB/s')
    expect(capSummary({ name: 'U', downBytesPerSec: null, upBytesPerSec: null }, 'no cap')).toBe(
      '↓ no cap · ↑ no cap',
    )
  })
})

describe('cap fields', () => {
  it('round-trips through the editable form', () => {
    expect(toField(null)).toEqual({ value: '', unit: 'MB' })
    expect(toField(2 * 1024 * 1024)).toEqual({ value: '2', unit: 'MB' })
    expect(toField(500 * 1024)).toEqual({ value: '500', unit: 'KB' })
    expect(fromField(toField(1536 * 1024))).toBe(1536 * 1024)
  })

  it('reads blank as unlimited and rejects nonsense', () => {
    expect(fromField({ value: ' ', unit: 'KB' })).toBeNull()
    expect(fromField({ value: '1.5', unit: 'MB' })).toBe(1572864)
    expect(fromField({ value: '-1', unit: 'KB' })).toBeUndefined()
    expect(fromField({ value: 'fast', unit: 'KB' })).toBeUndefined()
  })
})

describe('isBandwidthState', () => {
  it('accepts the documented shape only', () => {
    expect(
      isBandwidthState({
        enabled: true,
        selected: 'Medium',
        profiles: [{ name: 'Medium', downBytesPerSec: 1, upBytesPerSec: null }],
      }),
    ).toBe(true)
    expect(isBandwidthState({ enabled: 'yes', selected: '', profiles: [] })).toBe(false)
    expect(isBandwidthState({ enabled: true, selected: 'x', profiles: [{ name: 1 }] })).toBe(false)
    expect(isBandwidthState(null)).toBe(false)
  })
})
