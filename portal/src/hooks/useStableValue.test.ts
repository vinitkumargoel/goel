import { renderHook } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { useStableValue } from './useStableValue'

describe('useStableValue', () => {
  it('keeps identity while the content is equal and swaps it when it changes', () => {
    const { result, rerender } = renderHook(({ v }) => useStableValue(v), { initialProps: { v: { a: 1 } } })
    const first = result.current
    rerender({ v: { a: 1 } })
    expect(result.current).toBe(first)
    rerender({ v: { a: 2 } })
    expect(result.current).not.toBe(first)
    expect(result.current).toEqual({ a: 2 })
  })
})
