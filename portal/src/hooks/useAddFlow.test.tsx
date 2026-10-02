import { renderHook } from '@testing-library/react'
import type { ReactNode } from 'react'
import { I18nextProvider } from 'react-i18next'
import { afterEach, describe, expect, it, vi } from 'vitest'
import i18n from '../i18n'
import { useAddFlow } from './useAddFlow'

function wrapper({ children }: { children: ReactNode }) {
  return <I18nextProvider i18n={i18n}>{children}</I18nextProvider>
}

function setup(canWrite = true) {
  return renderHook(
    () => useAddFlow({ canWrite, toast: vi.fn(), refresh: async () => {}, onQueued: vi.fn() }),
    { wrapper },
  )
}

afterEach(() => {
  window.history.replaceState(null, '', '/')
})

describe('useAddFlow launch parameters', () => {
  it('opens Add for a shared link and strips the parameters from the address', () => {
    window.history.replaceState(null, '', '/?url=https%3A%2F%2Fexample.org%2Fa.iso&token=t#/library')
    const { result } = setup()
    expect(result.current.addOpen).toBe(true)
    expect(window.location.search).toBe('?token=t')
    expect(window.location.hash).toBe('#/library')
  })

  it('opens an empty Add for the shortcut', () => {
    window.history.replaceState(null, '', '/?add=1')
    const { result } = setup()
    expect(result.current.addOpen).toBe(true)
    expect(window.location.search).toBe('')
  })

  it('does not open Add when the portal is read-only, but still cleans the address', () => {
    window.history.replaceState(null, '', '/?url=https%3A%2F%2Fexample.org%2Fa.iso')
    const { result } = setup(false)
    expect(result.current.addOpen).toBe(false)
    expect(window.location.search).toBe('')
  })

  it('stays closed on an ordinary launch', () => {
    window.history.replaceState(null, '', '/')
    expect(setup().result.current.addOpen).toBe(false)
  })
})
