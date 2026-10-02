import { useRef } from 'react'

/**
 * The previous value while the new one serialises the same. For small derived objects (filter
 * counts, tag counts) that are recomputed on every snapshot but rarely change, so a memoised
 * shell component fed by them skips the render a one-second progress tick would otherwise cost.
 */
export function useStableValue<T>(value: T): T {
  const ref = useRef<{ json: string; value: T } | null>(null)
  const json = JSON.stringify(value)
  if (ref.current?.json !== json) ref.current = { json, value }
  return ref.current.value
}
