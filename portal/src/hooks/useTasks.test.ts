import { act, renderHook, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { api, ApiError } from '../lib/api'
import type { TaskRow } from '../lib/types'
import { useTasks } from './useTasks'

class FakeEventSource {
  static last: FakeEventSource | null = null
  onmessage: ((e: MessageEvent) => void) | null = null
  onerror: (() => void) | null = null
  constructor() {
    FakeEventSource.last = this
  }
  close() {}
  emit(rows: TaskRow[]) {
    this.onmessage?.({ data: JSON.stringify(rows) } as MessageEvent)
  }
}

const row = (id: string, progress = 0): TaskRow => ({ id, progress }) as TaskRow

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
})
