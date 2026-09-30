import { useCallback, useEffect, useRef, useState } from 'react'

export type ToastTone = 'ok' | 'warn' | 'copy' | 'trash'

export interface Toast {
  id: number
  message: string
  tone: ToastTone
  /** Set once the toast is on its way out; it stays mounted for `EXIT_MS` so `.out` can animate. */
  leaving: boolean
}

/** Confirmations are glanceable; a warning has to survive being read, so it stays longer. */
export const TOAST_MS: Readonly<Record<ToastTone, number>> = {
  ok: 2400,
  copy: 2400,
  trash: 2400,
  warn: 6000,
}

/** Matches the `.toast.out` transition in portal.css. */
export const EXIT_MS = 300

/** A second identical toast inside this window restarts the first one's timer instead of stacking. */
export const DEDUPE_MS = 2000

/** At most this many toasts on screen; the oldest makes way for a new one. */
export const MAX_TOASTS = 4

interface Countdown {
  handle: ReturnType<typeof setTimeout> | null
  remaining: number
  startedAt: number
}

export function useToasts() {
  const [toasts, setToasts] = useState<Toast[]>([])
  const nextId = useRef(1)
  const countdowns = useRef(new Map<number, Countdown>())
  const exits = useRef(new Set<ReturnType<typeof setTimeout>>())
  const recent = useRef(new Map<string, { id: number; at: number }>())

  // Cancel pending timers on unmount: undrained ones fire setState on an unmounted component, and StrictMode doubles them.
  useEffect(() => {
    const pending = countdowns.current
    const leaving = exits.current
    return () => {
      for (const c of pending.values()) if (c.handle) clearTimeout(c.handle)
      pending.clear()
      for (const timer of leaving) clearTimeout(timer)
      leaving.clear()
    }
  }, [])

  const dismiss = useCallback((id: number) => {
    const countdown = countdowns.current.get(id)
    if (!countdown) return
    if (countdown.handle) clearTimeout(countdown.handle)
    countdowns.current.delete(id)
    for (const [key, seen] of recent.current) if (seen.id === id) recent.current.delete(key)

    setToasts((current) => current.map((t) => (t.id === id ? { ...t, leaving: true } : t)))
    const exit = setTimeout(() => {
      exits.current.delete(exit)
      setToasts((current) => current.filter((t) => t.id !== id))
    }, EXIT_MS)
    exits.current.add(exit)
  }, [])

  const start = useCallback(
    (id: number, ms: number) => {
      const handle = setTimeout(() => dismiss(id), ms)
      countdowns.current.set(id, { handle, remaining: ms, startedAt: Date.now() })
    },
    [dismiss],
  )

  const toast = useCallback(
    (message: string, tone: ToastTone = 'ok') => {
      const key = `${tone}\u0000${message}`
      const now = Date.now()
      const seen = recent.current.get(key)
      const live = seen ? countdowns.current.get(seen.id) : undefined
      if (seen && live && now - seen.at < DEDUPE_MS) {
        // Same words, same tone, moments apart (a bulk action's N refusals): keep one, restart its clock.
        // A held (hovered/focused) toast keeps its hold; resuming restarts it with the full time.
        seen.at = now
        if (live.handle) {
          clearTimeout(live.handle)
          start(seen.id, TOAST_MS[tone])
        } else {
          live.remaining = TOAST_MS[tone]
        }
        return
      }

      const id = nextId.current++
      recent.current.set(key, { id, at: now })
      setToasts((current) => [...current, { id, message, tone, leaving: false }])
      start(id, TOAST_MS[tone])

      // `countdowns` holds exactly the toasts not yet leaving, oldest first.
      const overflow = countdowns.current.size - MAX_TOASTS
      if (overflow > 0) [...countdowns.current.keys()].slice(0, overflow).forEach(dismiss)
    },
    [start, dismiss],
  )

  /** Hover or focus holds a toast: it must not vanish under the pointer or a screen reader. */
  const pause = useCallback((id: number) => {
    const countdown = countdowns.current.get(id)
    if (!countdown?.handle) return
    clearTimeout(countdown.handle)
    countdowns.current.set(id, {
      handle: null,
      remaining: Math.max(0, countdown.remaining - (Date.now() - countdown.startedAt)),
      startedAt: countdown.startedAt,
    })
  }, [])

  const resume = useCallback(
    (id: number) => {
      const countdown = countdowns.current.get(id)
      if (!countdown || countdown.handle) return
      start(id, countdown.remaining)
    },
    [start],
  )

  return { toasts, toast, dismiss, pause, resume }
}
