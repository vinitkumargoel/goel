import { act, renderHook } from '@testing-library/react'
import type { ReactNode } from 'react'
import { I18nextProvider } from 'react-i18next'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { ConfirmRequest } from '../components/dialogs/ConfirmDialog'
import i18n from '../i18n'
import { api, ApiError } from '../lib/api'
import { makeTask } from '../test/makeTask'
import { useTaskActions } from './useTaskActions'

function wrapper({ children }: { children: ReactNode }) {
  return <I18nextProvider i18n={i18n}>{children}</I18nextProvider>
}

function setup(ids: string[] = ['a', 'b', 'c', 'd', 'e'], lookup?: (id: string) => ReturnType<typeof makeTask> | undefined) {
  const toast = vi.fn()
  const refresh = vi.fn(async () => {})
  let pending: ConfirmRequest | null = null
  const present = new Set(ids)
  const { result } = renderHook(
    () =>
      useTaskActions({
        refresh,
        toast,
        confirm: (r) => {
          pending = r
        },
        currentIds: () => present,
        lookup,
      }),
    { wrapper },
  )
  return { result, toast, refresh, present, confirmPending: (checked = false) => pending!.onConfirm(checked), pending: () => pending }
}

afterEach(() => {
  vi.restoreAllMocks()
})

describe('useTaskActions', () => {
  it('reports a partial bulk failure with both counts', async () => {
    vi.spyOn(api, 'pause').mockImplementation(async (id) => {
      if (id === 'b' || id === 'd') throw new ApiError('http', 'boom', 500)
    })
    const { result, toast } = setup()
    await act(() => result.current.runBulk('pause', ['a', 'b', 'c', 'd', 'e']))
    expect(toast).toHaveBeenCalledTimes(1)
    expect(toast).toHaveBeenCalledWith('Paused 3 of 5 — 2 failed', 'warn')
  })

  it('warns, and does not claim success, when every bulk call failed', async () => {
    vi.spyOn(api, 'resume').mockRejectedValue(new ApiError('network', 'Could not reach the server'))
    const { result, toast } = setup()
    await act(() => result.current.runBulk('resume', ['a', 'b']))
    expect(toast).toHaveBeenCalledWith(
      'Couldn’t resume 2 downloads — Could not reach the server',
      'warn',
    )
  })

  it('stays silent when the api layer already reported a refusal', async () => {
    vi.spyOn(api, 'retry').mockRejectedValue(new ApiError('refused', 'Read-only', 403))
    const { result, toast } = setup()
    await act(() => result.current.runBulk('retry', ['a', 'b']))
    expect(toast).not.toHaveBeenCalled()
  })

  it('surfaces a single action failure with the server message', async () => {
    vi.spyOn(api, 'pause').mockRejectedValue(new ApiError('http', 'Task is busy', 409))
    const { result, toast } = setup()
    await act(() => result.current.runAction('a', 'pause'))
    expect(toast).toHaveBeenCalledWith('Task is busy', 'warn')
  })

  it('re-checks a confirmed removal against the tasks present at confirm time', async () => {
    const remove = vi.spyOn(api, 'remove').mockResolvedValue()
    const { result, present, confirmPending, toast } = setup(['a', 'b', 'c'])
    act(() => result.current.removeMany(['a', 'b', 'c']))
    present.delete('b')
    await act(async () => confirmPending())
    await act(async () => {})
    expect(remove.mock.calls.map((c) => c[0])).toEqual(['a', 'c'])
    expect(toast).toHaveBeenCalledWith('Removed', 'trash')
  })

  it('asks before removing with data, naming the download and its size', async () => {
    const remove = vi.spyOn(api, 'remove').mockResolvedValue()
    const task = makeTask('a', { name: 'big.iso', totalBytes: 2048 })
    const { result, pending, confirmPending } = setup(['a'], (id) => (id === 'a' ? task : undefined))
    act(() => result.current.removeTask('a', true))
    expect(remove).not.toHaveBeenCalled()
    expect(pending()?.items).toEqual([{ name: 'big.iso', bytes: 2048, kind: task.kind }])
    await act(async () => confirmPending())
    expect(remove).toHaveBeenCalledWith('a', true)
  })

  describe('undoable single remove', () => {
    it('hides the row at once and removes only when the toast closes', async () => {
      const remove = vi.spyOn(api, 'remove').mockResolvedValue()
      const { result, toast } = setup()
      act(() => result.current.removeTask('a', false))
      expect(result.current.hidden.has('a')).toBe(true)
      expect(remove).not.toHaveBeenCalled()
      const options = toast.mock.calls[0]![2]
      expect(options.action.label).toBe('Undo')
      await act(async () => options.onClose('timeout'))
      expect(remove).toHaveBeenCalledWith('a', false)
      expect(result.current.hidden.has('a')).toBe(false)
    })

    it('Undo brings the row back and never calls the server', async () => {
      const remove = vi.spyOn(api, 'remove').mockResolvedValue()
      const { result, toast } = setup()
      act(() => result.current.removeTask('a', false))
      const options = toast.mock.calls[0]![2]
      await act(async () => {
        options.onClose('action')
        options.action.run()
      })
      expect(result.current.hidden.has('a')).toBe(false)
      expect(remove).not.toHaveBeenCalled()
    })

    it('flushes pending removals when the page goes away', () => {
      const fetchSpy = vi.fn(async () => new Response(null))
      vi.stubGlobal('fetch', fetchSpy)
      const { result } = setup()
      act(() => result.current.removeTask('a', false))
      window.dispatchEvent(new Event('pagehide'))
      expect(fetchSpy).toHaveBeenCalledWith(
        '/api/remove?id=a&data=0',
        expect.objectContaining({ method: 'POST', keepalive: true }),
      )
      vi.unstubAllGlobals()
    })
  })

  it('a bulk confirm with "also delete" ticked removes with data', async () => {
    const remove = vi.spyOn(api, 'remove').mockResolvedValue()
    const { result, confirmPending, pending } = setup(['a', 'b'])
    act(() => result.current.removeMany(['a', 'b']))
    expect(pending()?.option?.confirmLabel).toMatch(/^Delete 2 · /)
    await act(async () => confirmPending(true))
    expect(remove.mock.calls).toEqual([
      ['a', true],
      ['b', true],
    ])
  })
})
