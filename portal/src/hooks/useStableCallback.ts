import { useCallback, useLayoutEffect, useRef } from 'react'

/**
 * A callback whose identity never changes but which always runs the latest `fn`. For handlers
 * passed to memoised children (every list row), where a fresh identity per render would defeat
 * the memo. Must not be called during render.
 */
export function useStableCallback<A extends unknown[], R>(fn: (...args: A) => R): (...args: A) => R {
  const ref = useRef(fn)
  useLayoutEffect(() => {
    ref.current = fn
  })
  return useCallback((...args: A) => ref.current(...args), [])
}
