import { useEffect, useId, useRef } from 'react'
import { useTranslation } from 'react-i18next'
import { useDialogFocus } from '../hooks/useDialogFocus'
import { WarnIcon } from './Icons'

export interface ConfirmRequest {
  title: string
  body: string
  confirmLabel: string
  onConfirm: () => void
}

interface ConfirmDialogProps {
  request: ConfirmRequest | null
  onClose: () => void
}

/** In-page replacement for `window.confirm`: themed, focus-trapped, and Cancel is the default. */
export function ConfirmDialog({ request, onClose }: ConfirmDialogProps) {
  if (!request) return null
  return <Open request={request} onClose={onClose} />
}

function Open({ request, onClose }: { request: ConfirmRequest; onClose: () => void }) {
  const { t } = useTranslation()
  const ref = useRef<HTMLDivElement>(null)
  const cancelRef = useRef<HTMLButtonElement>(null)
  const titleId = useId()
  const bodyId = useId()
  useDialogFocus(ref, { onEscape: onClose })

  // Destructive confirmations never take Return as their default, so focus starts on Cancel.
  useEffect(() => {
    cancelRef.current?.focus()
  }, [])

  return (
    <div
      className="scrim open confirm-scrim"
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose()
      }}
    >
      <div
        className="modal confirm"
        ref={ref}
        role="alertdialog"
        aria-modal="true"
        aria-labelledby={titleId}
        aria-describedby={bodyId}
      >
        <div className="mhead">
          <div className="mic danger">
            <WarnIcon />
          </div>
          <h3 id={titleId}>{request.title}</h3>
        </div>
        <div className="mbody">
          <p id={bodyId} className="cbody">
            {request.body}
          </p>
        </div>
        <div className="mfoot">
          <button className="btn" ref={cancelRef} onClick={onClose}>
            {t('common.cancel')}
          </button>
          <button
            className="btn danger"
            onClick={() => {
              onClose()
              request.onConfirm()
            }}
          >
            {request.confirmLabel}
          </button>
        </div>
      </div>
    </div>
  )
}
