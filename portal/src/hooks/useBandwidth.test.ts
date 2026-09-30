import { act, renderHook, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { api, ApiError } from '../lib/api'
import type { BandwidthState } from '../lib/bandwidth'
import { BANDWIDTH_POLL_MS, useBandwidth } from './useBandwidth'

const STATE: BandwidthState = {
  enabled: true,
  selected: 'Medium',
  profiles: [{ name: 'Medium', downBytesPerSec: 2_097_152, upBytesPerSec: null }],
}

afterEach(() => {
  vi.restoreAllMocks()
  vi.useRealTimers()
})

describe('useBandwidth', () => {
  it('loads the state on mount', async () => {
    vi.spyOn(api, 'bandwidth').mockResolvedValue(STATE)
    const { result } = renderHook(() => useBandwidth())
    await waitFor(() => expect(result.current.status).toBe('ready'))
    expect(result.current.state).toEqual(STATE)
  })

  it('treats a 404 as an older daemon: unsupported, and never polls again', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    const get = vi.spyOn(api, 'bandwidth').mockRejectedValue(new ApiError('http', 'Not found', 404))
    const { result } = renderHook(() => useBandwidth())
    await waitFor(() => expect(result.current.status).toBe('unsupported'))
    await act(async () => vi.advanceTimersByTime(BANDWIDTH_POLL_MS * 2))
    expect(get).toHaveBeenCalledTimes(1)
  })

  it('polls every 15 seconds while visible', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    const get = vi.spyOn(api, 'bandwidth').mockResolvedValue(STATE)
    renderHook(() => useBandwidth())
    await act(async () => vi.advanceTimersByTime(BANDWIDTH_POLL_MS))
    expect(get).toHaveBeenCalledTimes(2)
  })

  it('keeps the last good state through a failed poll', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    const get = vi.spyOn(api, 'bandwidth').mockResolvedValue(STATE)
    const { result } = renderHook(() => useBandwidth())
    await waitFor(() => expect(result.current.status).toBe('ready'))
    get.mockRejectedValue(new ApiError('network', 'down'))
    await act(async () => vi.advanceTimersByTime(BANDWIDTH_POLL_MS))
    expect(result.current.status).toBe('ready')
    expect(result.current.state).toEqual(STATE)
  })

  it('adopts the echo of an update, and reports failures', async () => {
    vi.spyOn(api, 'bandwidth').mockResolvedValue(STATE)
    const post = vi.spyOn(api, 'updateBandwidth').mockResolvedValue({ ...STATE, enabled: false })
    const { result } = renderHook(() => useBandwidth())
    await waitFor(() => expect(result.current.status).toBe('ready'))

    let outcome: string | null = 'unset'
    await act(async () => {
      outcome = await result.current.update({ enabled: false })
    })
    expect(outcome).toBeNull()
    expect(post).toHaveBeenCalledWith({ enabled: false })
    expect(result.current.state?.enabled).toBe(false)

    post.mockRejectedValue(new ApiError('http', 'Unknown profile', 400))
    await act(async () => {
      outcome = await result.current.update({ selected: 'Nope' })
    })
    expect(outcome).toBe('Unknown profile')
  })
})
