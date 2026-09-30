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
      const id = nextId.current++
      setToasts((current) => [...current, { id, message, tone, leaving: false }])
      start(id, TOAST_MS[tone])
    },
    [start],
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
