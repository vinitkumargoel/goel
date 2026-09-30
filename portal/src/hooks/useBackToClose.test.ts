import { act, renderHook } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { useBackToClose } from './useBackToClose'

function pop() {
  act(() => {
    history.back()
  })
  // jsdom delivers popstate asynchronously after history.back().
  return new Promise((r) => setTimeout(r, 20))
}

describe('useBackToClose', () => {
  afterEach(() => history.replaceState(null, ''))

  it('closes the open layer on Back instead of leaving the page', async () => {
    const close = vi.fn()
    const start = history.length
    renderHook(({ open }) => useBackToClose(open, close), { initialProps: { open: true } })
    expect(history.length).toBe(start + 1)
    await pop()
    expect(close).toHaveBeenCalledTimes(1)
  })

  it('closing from the UI pops its entry and leaves an outer layer open', async () => {
    const outer = vi.fn()
    const inner = vi.fn()
    renderHook(() => useBackToClose(true, outer))
    const dialog = renderHook(({ open }) => useBackToClose(open, inner), { initialProps: { open: true } })
    dialog.rerender({ open: false })
    await new Promise((r) => setTimeout(r, 20))
    expect(inner).not.toHaveBeenCalled()
    expect(outer).not.toHaveBeenCalled()
    await pop()
    expect(outer).toHaveBeenCalledTimes(1)
  })
})

describe('useBackToClose — moving on while closing', () => {
  afterEach(() => history.replaceState(null, '', '#/library'))

  it('keeps the address the portal moved to, rather than the one the layer opened over', async () => {
    history.replaceState(null, '', '#/library?task=t1')
    // What a hashchange handler reads when it re-routes (App's reads `location.hash`).
    const seen: string[] = []
    const onHash = () => seen.push(location.hash)
    window.addEventListener('hashchange', onHash)
    const drawer = renderHook(({ open }) => useBackToClose(open, vi.fn()), { initialProps: { open: true } })
    // One commit: the drawer closes and the view changes, mirrored into the address.
    drawer.rerender({ open: false })
    history.replaceState(history.state, '', '#/settings')
    await new Promise((r) => setTimeout(r, 20))
    window.removeEventListener('hashchange', onHash)
    expect(location.hash).toBe('#/settings')
    expect(seen.every((h) => h === '#/settings')).toBe(true)
  })
})
