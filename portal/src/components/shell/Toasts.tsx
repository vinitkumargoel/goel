import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { Toast, ToastTone } from '../../hooks/useToasts'
import { Icon, type IconName } from '../ui/Icon'

const TONE_ICON: Readonly<Record<ToastTone, IconName>> = {
  ok: 'check',
  warn: 'alert',
  copy: 'copy',
  trash: 'trash',
}

interface ToastsProps {
  toasts: Toast[]
  onDismiss: (id: number) => void
  onPause: (id: number) => void
  onResume: (id: number) => void
  /** A toast's own button (Undo, Show). */
  onAction?: (id: number) => void
}

/**
 * Studio toast cards, stacked bottom right (above the tab bar on a phone). Two live regions:
 * confirmations are polite, warnings interrupt — one region would either shout "Copied" or queue
 * "Could not reach the server" behind other speech.
 */
export function Toasts({ toasts, onDismiss, onPause, onResume, onAction }: ToastsProps) {
  const item = (t: Toast) => (
    <ToastItem key={t.id} toast={t} onDismiss={onDismiss} onPause={onPause} onResume={onResume} onAction={onAction} />
  )
  return (
    <div className="toasts">
      <div className="toast-region" role="alert">
        {toasts.filter((t) => t.tone === 'warn').map(item)}
      </div>
      <div className="toast-region" role="status" aria-live="polite">
        {toasts.filter((t) => t.tone !== 'warn').map(item)}
      </div>
    </div>
  )
}

interface ToastItemProps {
  toast: Toast
  onDismiss: (id: number) => void
  onPause: (id: number) => void
  onResume: (id: number) => void
  onAction?: (id: number) => void
}

function ToastItem({ toast, onDismiss, onPause, onResume, onAction }: ToastItemProps) {
  const { t } = useTranslation()
  const [hovered, setHovered] = useState(false)
  const [focused, setFocused] = useState(false)
  const held = hovered || focused

  // Hovering or focusing a toast holds its timer, so an Undo can be reached and read.
  useEffect(() => {
    if (held) onPause(toast.id)
    else onResume(toast.id)
  }, [held, toast.id, onPause, onResume])

  return (
    <div
      className={`toast ${toast.tone}${toast.leaving ? ' out' : ''}`}
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      onFocus={() => setFocused(true)}
      onBlur={(e) => {
        if (!e.currentTarget.contains(e.relatedTarget as Node | null)) setFocused(false)
      }}
    >
      <span className="ti" aria-hidden="true">
        <Icon name={TONE_ICON[toast.tone]} />
      </span>
      <span className="tmsg">{toast.message}</span>
      {toast.action && onAction && (
        <button type="button" className="btn sm" onClick={() => onAction(toast.id)}>
          {toast.action.label}
        </button>
      )}
      <button type="button" className="ibtn sm" onClick={() => onDismiss(toast.id)} aria-label={t('toast.dismiss')}>
        <Icon name="x" size="s" />
      </button>
    </div>
  )
}
