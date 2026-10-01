import { renderHook } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { usePasteToAdd } from './usePasteToAdd'

function paste(text: string, target: EventTarget = document.body) {
  const e = new Event('paste', { bubbles: true, cancelable: true }) as ClipboardEvent
  Object.defineProperty(e, 'clipboardData', { value: { getData: () => text } })
  target.dispatchEvent(e)
  return e
}

afterEach(() => {
  document.body.innerHTML = ''
})

describe('usePasteToAdd', () => {
  it('opens Add with pasted links', () => {
    const onLinks = vi.fn()
    renderHook(() => usePasteToAdd(true, onLinks))
    const e = paste('  https://e/a.iso\n')
    expect(onLinks).toHaveBeenCalledWith('https://e/a.iso')
    expect(e.defaultPrevented).toBe(true)
  })

  it('leaves plain text, text fields and a disabled hook alone', () => {
    const onLinks = vi.fn()
    const { rerender } = renderHook(({ on }) => usePasteToAdd(on, onLinks), { initialProps: { on: true } })
    paste('just words')
    const input = document.createElement('input')
    document.body.append(input)
    paste('https://e/a', input)
    rerender({ on: false })
    paste('https://e/b')
    expect(onLinks).not.toHaveBeenCalled()
  })
})
