import { useCallback, useEffect, useRef, useState } from 'react'

export type ToastTone = 'ok' | 'warn' | 'copy' | 'trash'

export interface Toast {
  id: number
  message: string
  tone: ToastTone
}

/** Matches the `.toast` exit transition in portal.css. */
const VISIBLE_MS = 2400

export function useToasts() {
  const [toasts, setToasts] = useState<Toast[]>([])
  const nextId = useRef(1)
  const timers = useRef<Set<ReturnType<typeof setTimeout>>>(new Set())

  // Cancel every pending dismissal on unmount: undrained timers outlived the component and still
  // fired (setState on an unmounted component), and StrictMode's remount doubled them per toast.
  useEffect(() => {
    const pending = timers.current
    return () => {
      for (const timer of pending) clearTimeout(timer)
      pending.clear()
    }
  }, [])

  const dismiss = useCallback((id: number) => {
    setToasts((current) => current.filter((t) => t.id !== id))
  }, [])

  const toast = useCallback(
    (message: string, tone: ToastTone = 'ok') => {
      const id = nextId.current++
      setToasts((current) => [...current, { id, message, tone }])
      const timer = setTimeout(() => {
        timers.current.delete(timer)
        dismiss(id)
      }, VISIBLE_MS)
      timers.current.add(timer)
    },
    [dismiss],
  )

  return { toasts, toast, dismiss }
}
