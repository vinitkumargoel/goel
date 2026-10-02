import { useRef, type ReactNode } from 'react'
import { useDialogFocus } from '../../hooks/useDialogFocus'

interface ModalProps {
  /** Id of the visible title. */
  labelledBy: string
  describedBy?: string
  /** Escape, a click on the scrim, and whatever close button the content draws. */
  onClose: () => void
  /** `alertdialog` for a confirmation that interrupts. */
  role?: 'dialog' | 'alertdialog'
  /** False while a stacked child dialog owns Tab and Escape. */
  trap?: boolean
  /** A click on the scrim closes; off for a dialog holding unsaved input. */
  scrimCloses?: boolean
  /** Sheet width in px on a wide screen (default 560); on a phone every sheet is full width. */
  width?: number
  className?: string
  children: ReactNode
}

/**
 * A modal Studio sheet over a blurred scrim: focus trapped and handed back on close (see
 * useDialogFocus), Escape closes. On a phone the sheet rises from the bottom edge. Compose the
 * inside from `.sheet-h`, `.sheet-b` and `.sheet-f`.
 */
export function Modal({
  labelledBy,
  describedBy,
  onClose,
  role = 'dialog',
  trap = true,
  scrimCloses = true,
  width,
  className,
  children,
}: ModalProps) {
  const ref = useRef<HTMLDivElement>(null)
  useDialogFocus(ref, { trap, onEscape: onClose })
  return (
    <div
      className="scrim"
      onMouseDown={(e) => {
        // mousedown, not click: a drag that starts in a field and ends on the scrim must not close.
        if (scrimCloses && e.target === e.currentTarget) onClose()
      }}
    >
      <div
        ref={ref}
        className={`sheet${className ? ` ${className}` : ''}`}
        role={role}
        aria-modal="true"
        tabIndex={-1}
        aria-labelledby={labelledBy}
        aria-describedby={describedBy}
        style={width ? { width: `min(${width}px, 100%)` } : undefined}
      >
        {children}
      </div>
    </div>
  )
}
