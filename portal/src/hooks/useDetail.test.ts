import { act, renderHook, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { api, ApiError } from '../lib/api'
import { createLatest } from '../lib/latest'
import type { TaskDetail, TaskRow } from '../lib/types'
import { DETAIL_POLL_MS, useDetail } from './useDetail'

function detail(id: string, name = `${id}.iso`): TaskDetail {
  return { row: { id, name } as TaskRow, files: [], trackers: [], connections: [], pieces: [] } as unknown as TaskDetail
}

function deferred<T>() {
  let resolve!: (v: T) => void
  let reject!: (e: unknown) => void
  const promise = new Promise<T>((res, rej) => {
    resolve = res
    reject = rej
  })
  return { promise, resolve, reject }
}

const noop = () => {}

afterEach(() => {
  vi.restoreAllMocks()
})

describe('createLatest', () => {
  it('treats only the most recent stamp as current', () => {
    const latest = createLatest()
    const a = latest.begin()
    const b = latest.begin()
    expect(latest.isCurrent(a)).toBe(false)
    expect(latest.isCurrent(b)).toBe(true)
    latest.invalidate()
    expect(latest.isCurrent(b)).toBe(false)
  })
})

describe('useDetail', () => {
  it('drops a slow response for a row that is no longer selected', async () => {
    const slowA = deferred<TaskDetail>()
    const fastB = deferred<TaskDetail>()
    vi.spyOn(api, 'task').mockImplementation((id) => (id === 'a' ? slowA.promise : fastB.promise))

    const { result, rerender } = renderHook(({ id }) => useDetail(id, [], false, noop), {
      initialProps: { id: 'a' as string | null },
    })
    rerender({ id: 'b' })
    await act(async () => fastB.resolve(detail('b')))
    expect(result.current.detail?.row.id).toBe('b')

    await act(async () => slowA.resolve(detail('a')))
    expect(result.current.detail?.row.id).toBe('b')
  })

  it('keeps the shown detail when a refetch fails', async () => {
    const spy = vi.spyOn(api, 'task').mockResolvedValueOnce(detail('a', 'first'))
    const { result } = renderHook(() => useDetail('a', [], false, noop))
    await waitFor(() => expect(result.current.detail?.row.name).toBe('first'))

    spy.mockRejectedValueOnce(new ApiError('network', 'down'))
    await act(async () => {
      await result.current.reload()
    })
    expect(result.current.detail?.row.name).toBe('first')
  })

  it('clears the panel when the first load of a new row fails', async () => {
    const spy = vi.spyOn(api, 'task').mockResolvedValueOnce(detail('a'))
    const { result, rerender } = renderHook(({ id }) => useDetail(id, [], false, noop), {
      initialProps: { id: 'a' as string | null },
    })
    await waitFor(() => expect(result.current.detail?.row.id).toBe('a'))

    spy.mockRejectedValueOnce(new ApiError('http', 'gone', 404))
    rerender({ id: 'b' })
    await waitFor(() => expect(result.current.detail).toBeNull())
  })

  it('ignores a response that lands after the selection was cleared', async () => {
    const slow = deferred<TaskDetail>()
    vi.spyOn(api, 'task').mockReturnValue(slow.promise)
    const { result, rerender } = renderHook(({ id }) => useDetail(id, [], false, noop), {
      initialProps: { id: 'a' as string | null },
    })
    rerender({ id: null })
    await act(async () => slow.resolve(detail('a')))
    expect(result.current.detail).toBeNull()
  })

  it('does not poll while the tab is hidden, and catches up when it is shown', async () => {
    vi.useFakeTimers()
    try {
      const spy = vi.spyOn(api, 'task').mockResolvedValue(detail('a'))
      const hidden = vi.spyOn(document, 'hidden', 'get').mockReturnValue(true)
      renderHook(() => useDetail('a', [], true, noop))
      await act(async () => {})
      const initial = spy.mock.calls.length
      await act(async () => {
        vi.advanceTimersByTime(DETAIL_POLL_MS * 3)
      })
      expect(spy.mock.calls.length).toBe(initial)
      hidden.mockReturnValue(false)
      await act(async () => {
        document.dispatchEvent(new Event('visibilitychange'))
      })
      expect(spy.mock.calls.length).toBe(initial + 1)
    } finally {
      vi.useRealTimers()
    }
  })
})
