import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { Toast, ToastTone } from '../hooks/useToasts'
import { CheckIcon, CloseIcon, CopyIcon, TrashIcon, WarnIcon } from './Icons'

function ToneIcon({ tone }: { tone: ToastTone }) {
  switch (tone) {
    case 'warn':
      return <WarnIcon />
    case 'copy':
      return <CopyIcon />
    case 'trash':
      return <TrashIcon />
    case 'ok':
      return <CheckIcon />
  }
}

interface ToastsProps {
  toasts: Toast[]
  onDismiss: (id: number) => void
  onPause: (id: number) => void
  onResume: (id: number) => void
}

/**
 * Two live regions: confirmations are polite, warnings interrupt. A single region would make a
 * screen reader either shout "Copied" or queue "Could not reach the server" behind other speech.
 */
export function Toasts({ toasts, onDismiss, onPause, onResume }: ToastsProps) {
  const item = (t: Toast) => (
    <ToastItem key={t.id} toast={t} onDismiss={onDismiss} onPause={onPause} onResume={onResume} />
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
}

function ToastItem({ toast, onDismiss, onPause, onResume }: ToastItemProps) {
  const { t } = useTranslation()
  const [hovered, setHovered] = useState(false)
  const [focused, setFocused] = useState(false)
  const held = hovered || focused

  useEffect(() => {
    if (held) onPause(toast.id)
    else onResume(toast.id)
  }, [held, toast.id, onPause, onResume])

  return (
    <div
      className={`toast${toast.tone === 'warn' ? ' warn' : ''}${toast.leaving ? ' out' : ''}`}
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      onFocus={() => setFocused(true)}
      onBlur={(e) => {
        if (!e.currentTarget.contains(e.relatedTarget as Node | null)) setFocused(false)
      }}
    >
      <ToneIcon tone={toast.tone} />
      <span className="tmsg">{toast.message}</span>
      <button
        className="tclose"
        onClick={() => onDismiss(toast.id)}
        aria-label={t('toast.dismiss')}
      >
        <CloseIcon />
      </button>
    </div>
  )
}
