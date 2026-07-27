import type { Toast, ToastTone } from '../hooks/useToasts'
import { CheckIcon, CopyIcon, TrashIcon, WarnIcon } from './Icons'

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

export function Toasts({ toasts }: { toasts: Toast[] }) {
  return (
    <div className="toasts" role="status" aria-live="polite">
      {toasts.map((t) => (
        <div className="toast" key={t.id}>
          <ToneIcon tone={t.tone} />
          <span>{t.message}</span>
        </div>
      ))}
    </div>
  )
}
