import { useCallback, useEffect, useRef, useState } from 'react'

export type ToastTone = 'ok' | 'warn' | 'copy' | 'trash'

/** Why a toast went away: its action (Undo) is the only exit that is not "let it happen". */
export type ToastClose = 'timeout' | 'dismiss' | 'action'

export interface ToastAction {
  label: string
  run: () => void
}

export interface ToastOptions {
  /** One button beside the message, e.g. Undo or Show. */
  action?: ToastAction
  /** Called once, however the toast leaves. */
  onClose?: (reason: ToastClose) => void
  /** Overrides the tone's time on screen. */
  ms?: number
}

export interface Toast {
  id: number
  message: string
  tone: ToastTone
  action?: ToastAction
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

/** An Undo has to be findable: longer than a plain confirmation. */
export const UNDO_MS = 6000

interface Countdown {
  handle: ReturnType<typeof setTimeout> | null
  remaining: number
  startedAt: number
}

export function useToasts() {
  const [toasts, setToasts] = useState<Toast[]>([])
  const toastsRef = useRef(toasts)
  toastsRef.current = toasts
  const nextId = useRef(1)
  const countdowns = useRef(new Map<number, Countdown>())
  const exits = useRef(new Set<ReturnType<typeof setTimeout>>())
  const recent = useRef(new Map<string, { id: number; at: number }>())
  const closers = useRef(new Map<number, (reason: ToastClose) => void>())

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

  const dismiss = useCallback((id: number, reason: ToastClose = 'dismiss') => {
    const countdown = countdowns.current.get(id)
    if (!countdown) return
    if (countdown.handle) clearTimeout(countdown.handle)
    countdowns.current.delete(id)
    for (const [key, seen] of recent.current) if (seen.id === id) recent.current.delete(key)
    const onClose = closers.current.get(id)
    closers.current.delete(id)
    onClose?.(reason)

    setToasts((current) => current.map((t) => (t.id === id ? { ...t, leaving: true } : t)))
    const exit = setTimeout(() => {
      exits.current.delete(exit)
      setToasts((current) => current.filter((t) => t.id !== id))
    }, EXIT_MS)
    exits.current.add(exit)
  }, [])

  const start = useCallback(
    (id: number, ms: number) => {
      const handle = setTimeout(() => dismiss(id, 'timeout'), ms)
      countdowns.current.set(id, { handle, remaining: ms, startedAt: Date.now() })
    },
    [dismiss],
  )

  const toast = useCallback(
    (message: string, tone: ToastTone = 'ok', options: ToastOptions = {}) => {
      const key = `${tone}\u0000${message}`
      const now = Date.now()
      const ms = options.ms ?? TOAST_MS[tone]
      // A toast with a callback stands alone: merging two Undos would lose one of them.
      const plain = options.action == null && options.onClose == null
      const seen = plain ? recent.current.get(key) : undefined
      const live = seen ? countdowns.current.get(seen.id) : undefined
      if (seen && live && now - seen.at < DEDUPE_MS) {
        // Same words, same tone, moments apart (a bulk action's N refusals): keep one, restart its clock.
        // A held (hovered/focused) toast keeps its hold; resuming restarts it with the full time.
        seen.at = now
        if (live.handle) {
          clearTimeout(live.handle)
          start(seen.id, ms)
        } else {
          live.remaining = ms
        }
        return seen.id
      }

      const id = nextId.current++
      if (plain) recent.current.set(key, { id, at: now })
      if (options.onClose) closers.current.set(id, options.onClose)
      setToasts((current) => [...current, { id, message, tone, action: options.action, leaving: false }])
      start(id, ms)

      // `countdowns` holds exactly the toasts not yet leaving, oldest first.
      const overflow = countdowns.current.size - MAX_TOASTS
      if (overflow > 0)
        [...countdowns.current.keys()].slice(0, overflow).forEach((old) => dismiss(old, 'timeout'))
      return id
    },
    [start, dismiss],
  )

  /** Runs a toast's action, then takes it away. */
  const act = useCallback(
    (id: number) => {
      const action = toastsRef.current.find((t) => t.id === id)?.action
      if (!countdowns.current.has(id) || !action) return
      dismiss(id, 'action')
      action.run()
    },
    [dismiss],
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

  return { toasts, toast, dismiss, pause, resume, act }
}
