import { useEffect, useId, useRef, useState, type ReactNode } from 'react'

interface PopoverProps {
  /** The trigger's content; it is a button with `aria-expanded` and `aria-controls`. */
  trigger: ReactNode
  /** The trigger's accessible name and tooltip. */
  label: string
  triggerClassName?: string
  /** Opens above the trigger (the status bar) instead of below it. */
  above?: boolean
  /** Aligns the panel's right edge with the trigger's. */
  alignEnd?: boolean
  className?: string
  children: ReactNode
}

/**
 * A small non-modal panel that does one job (the speed graph): opened by its trigger, closed by
 * Escape, the trigger again, or a click anywhere else. Focus stays on the trigger.
 */
export function Popover({ trigger, label, triggerClassName, above = false, alignEnd = false, className, children }: PopoverProps) {
  const [open, setOpen] = useState(false)
  const id = useId()
  const root = useRef<HTMLSpanElement>(null)

  useEffect(() => {
    if (!open) return
    const onDown = (e: PointerEvent) => {
      if (!root.current?.contains(e.target as Node)) setOpen(false)
    }
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.stopPropagation()
        setOpen(false)
        root.current?.querySelector<HTMLElement>('button')?.focus()
      }
    }
    document.addEventListener('pointerdown', onDown, true)
    document.addEventListener('keydown', onKey, true)
    return () => {
      document.removeEventListener('pointerdown', onDown, true)
      document.removeEventListener('keydown', onKey, true)
    }
  }, [open])

  return (
    <span className="pop-root" ref={root}>
      <button
        type="button"
        className={triggerClassName}
        aria-expanded={open}
        aria-controls={id}
        aria-label={label}
        title={label}
        onClick={() => setOpen((o) => !o)}
      >
        {trigger}
      </button>
      {open && (
        <div
          id={id}
          role="dialog"
          aria-label={label}
          className={`pop${above ? ' above' : ''}${alignEnd ? ' end' : ''}${className ? ` ${className}` : ''}`}
        >
          {children}
        </div>
      )}
    </span>
  )
}
