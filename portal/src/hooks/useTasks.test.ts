import { act, renderHook, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { api, ApiError } from '../lib/api'
import { SpeedStore } from '../lib/speedStore'
import type { TaskRow } from '../lib/types'
import { reconnectDelay, useTasks, WATCHDOG_MS } from './useTasks'

class FakeEventSource {
  static last: FakeEventSource | null = null
  static opened = 0
  closed = false
  onmessage: ((e: MessageEvent) => void) | null = null
  onerror: (() => void) | null = null
  listeners = new Map<string, () => void>()
  addEventListener(type: string, fn: () => void) {
    this.listeners.set(type, fn)
  }
  ping() {
    this.listeners.get('ping')?.()
  }
  constructor() {
    FakeEventSource.last = this
    FakeEventSource.opened++
  }
  close() {
    this.closed = true
  }
  fail() {
    this.onerror?.()
  }
  emit(rows: TaskRow[]) {
    this.onmessage?.({ data: JSON.stringify(rows) } as MessageEvent)
  }
}

const row = (id: string, progress = 0, downSpeed = 0): TaskRow => ({ id, progress, downSpeed }) as TaskRow

function deferred<T>() {
  let resolve!: (v: T) => void
  const promise = new Promise<T>((res) => {
    resolve = res
  })
  return { promise, resolve }
}

beforeEach(() => {
  vi.stubGlobal('EventSource', FakeEventSource)
})

afterEach(() => {
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

describe('useTasks', () => {
  it('drops a fetch result when an SSE snapshot arrived after the fetch started', async () => {
    const slow = deferred<TaskRow[]>()
    vi.spyOn(api, 'tasks').mockReturnValue(slow.promise)
    const { result } = renderHook(() => useTasks())

    act(() => FakeEventSource.last!.emit([row('a', 0.9)]))
    expect(result.current.tasks[0]?.progress).toBe(0.9)

    await act(async () => slow.resolve([row('a', 0.1)]))
    expect(result.current.tasks[0]?.progress).toBe(0.9)
  })

  it('keeps row and array identity when a snapshot changes nothing', async () => {
    vi.spyOn(api, 'tasks').mockReturnValue(new Promise(() => {}))
    const { result } = renderHook(() => useTasks())
    act(() => FakeEventSource.last!.emit([row('a'), row('b')]))
    const first = result.current.tasks
    act(() => FakeEventSource.last!.emit([row('a'), row('b')]))
    expect(result.current.tasks).toBe(first)
    act(() => FakeEventSource.last!.emit([row('a'), row('b', 0.5)]))
    expect(result.current.tasks[0]).toBe(first[0])
    expect(result.current.tasks[1]).not.toBe(first[1])
  })

  it('reports an error when the snapshot fetch fails, and clears it on the next snapshot', async () => {
    vi.spyOn(api, 'tasks').mockRejectedValue(new ApiError('network', 'down'))
    const { result } = renderHook(() => useTasks())
    await waitFor(() => expect(result.current.error).toBe(true))
    expect(result.current.loaded).toBe(false)

    act(() => FakeEventSource.last!.emit([]))
    expect(result.current.error).toBe(false)
    expect(result.current.loaded).toBe(true)
  })

  it('hands out a stable refresh', () => {
    vi.spyOn(api, 'tasks').mockReturnValue(new Promise(() => {}))
    const { result, rerender } = renderHook(() => useTasks())
    const first = result.current.refresh
    act(() => FakeEventSource.last!.emit([row('a')]))
    rerender()
    expect(result.current.refresh).toBe(first)
  })

  it('stamps each snapshot so staleness can be measured', () => {
    vi.spyOn(api, 'tasks').mockReturnValue(new Promise(() => {}))
    const { result } = renderHook(() => useTasks())
    expect(result.current.lastUpdate).toBeNull()
    act(() => FakeEventSource.last!.emit([row('a')]))
    expect(result.current.lastUpdate).toBeTypeOf('number')
  })

  it('samples rates once a second from the latest rows, per task and in total', () => {
    vi.useFakeTimers()
    try {
      vi.spyOn(api, 'tasks').mockReturnValue(new Promise(() => {}))
      const store = new SpeedStore()
      renderHook(() => useTasks(store))
      act(() => FakeEventSource.last!.emit([row('a', 0, 100), row('b', 0, 50)]))
      act(() => vi.advanceTimersByTime(3000))
      expect(store.snapshot().perTask.get('a')).toHaveLength(3)
      expect(store.snapshot().total.at(-1)).toEqual({ down: 150, up: 0 })
      act(() => FakeEventSource.last!.emit([row('a', 0, 10)]))
      act(() => vi.advanceTimersByTime(1000))
      expect(store.snapshot().perTask.has('b')).toBe(false)
    } finally {
      vi.useRealTimers()
    }
  })

  it('does not re-render its caller on a sample tick', () => {
    vi.useFakeTimers()
    try {
      vi.spyOn(api, 'tasks').mockReturnValue(new Promise(() => {}))
      const store = new SpeedStore()
      let renders = 0
      renderHook(() => {
        renders++
        return useTasks(store)
      })
      act(() => FakeEventSource.last!.emit([row('a', 0, 100)]))
      const before = renders
      act(() => vi.advanceTimersByTime(3000))
      expect(store.snapshot().total).toHaveLength(3)
      expect(renders).toBe(before)
    } finally {
      vi.useRealTimers()
    }
  })

  it('skips samples while the tab is hidden', () => {
    vi.useFakeTimers()
    const visibility = vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('hidden')
    try {
      vi.spyOn(api, 'tasks').mockReturnValue(new Promise(() => {}))
      const store = new SpeedStore()
      renderHook(() => useTasks(store))
      act(() => FakeEventSource.last!.emit([row('a', 0, 100)]))
      act(() => vi.advanceTimersByTime(3000))
      expect(store.snapshot().total).toHaveLength(0)
      visibility.mockReturnValue('visible')
      act(() => vi.advanceTimersByTime(1000))
      expect(store.snapshot().total).toHaveLength(1)
    } finally {
      vi.useRealTimers()
    }
  })

  it('reconnects at once on request instead of waiting out the backoff', () => {
    vi.useFakeTimers()
    try {
      const tasks = vi.spyOn(api, 'tasks').mockReturnValue(new Promise(() => {}))
      const { result } = renderHook(() => useTasks())
      const first = FakeEventSource.last!
      act(() => first.fail())
      expect(result.current.live).toBe(false)
      const before = FakeEventSource.opened
      const fetches = tasks.mock.calls.length
      act(() => result.current.reconnect())
      expect(FakeEventSource.opened).toBe(before + 1)
      expect(tasks.mock.calls.length).toBe(fetches + 1)
      // The pending backoff was cancelled: no second socket when it would have fired.
      act(() => vi.advanceTimersByTime(31_000))
      expect(FakeEventSource.opened).toBe(before + 1)
    } finally {
      vi.useRealTimers()
    }
  })

  it('backs off exponentially with jitter, capped at 30 s', () => {
    expect(reconnectDelay(0, 0)).toBe(500)
    expect(reconnectDelay(0, 1)).toBe(1000)
    expect(reconnectDelay(3, 0)).toBe(4000)
    expect(reconnectDelay(20, 0.999)).toBeLessThanOrEqual(30_000)
    expect(reconnectDelay(20, 0)).toBe(15_000)
  })

  it('reopens a stream that goes silent past the watchdog, and keeps one that pings', () => {
    vi.useFakeTimers()
    try {
      vi.spyOn(api, 'tasks').mockReturnValue(new Promise(() => {}))
      const { result } = renderHook(() => useTasks())
      const first = FakeEventSource.last!
      act(() => vi.advanceTimersByTime(WATCHDOG_MS - 1000))
      act(() => first.ping())
      expect(result.current.live).toBe(true)
      act(() => vi.advanceTimersByTime(WATCHDOG_MS - 1000))
      expect(first.closed).toBe(false)
      act(() => vi.advanceTimersByTime(2000))
      expect(first.closed).toBe(true)
      expect(result.current.live).toBe(false)
      act(() => vi.advanceTimersByTime(2000))
      expect(FakeEventSource.last).not.toBe(first)
    } finally {
      vi.useRealTimers()
    }
  })

  it('reconnects and refreshes when the tab becomes visible or the network returns', () => {
    vi.useFakeTimers()
    try {
      const tasks = vi.spyOn(api, 'tasks').mockReturnValue(new Promise(() => {}))
      renderHook(() => useTasks())
      const before = FakeEventSource.opened
      const fetches = tasks.mock.calls.length
      act(() => {
        document.dispatchEvent(new Event('visibilitychange'))
      })
      expect(FakeEventSource.opened).toBe(before + 1)
      act(() => {
        window.dispatchEvent(new Event('online'))
      })
      expect(FakeEventSource.opened).toBe(before + 2)
      expect(tasks.mock.calls.length).toBe(fetches + 2)
    } finally {
      vi.useRealTimers()
    }
  })
})
