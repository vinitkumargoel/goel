import { useEffect, useId, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { fmtSize } from '../../lib/format'
import { fileType } from '../../lib/taskKind'
import type { TaskKind } from '../../lib/types'
import { Art } from '../ui/Art'
import { Icon } from '../ui/Icon'
import { Modal } from '../ui/Modal'

/** A listed download: a bare name, or a name with what is known of its size and kind. */
export type ConfirmItem = string | { name: string; bytes?: number | null; kind?: TaskKind }

export interface ConfirmRequest {
  title: string
  body: string
  confirmLabel: string
  /** `checked` is the option's state; false when there is none. */
  onConfirm: (checked: boolean) => void
  /** Names to list under the body, e.g. what a bulk remove covers. */
  items?: readonly ConfirmItem[]
  /** A quiet line after the names: "and 5 more · 3 GB in all". */
  footnote?: string
  /**
   * A checkbox that makes the action destructive, e.g. "Also delete files from disk". While it is
   * unticked the confirm button is a plain primary; ticked, it turns red and reads `confirmLabel`.
   */
  option?: { label: string; confirmLabel: string }
}

/**
 * The Studio confirmation: an alertdialog with a trash title, what it covers, and the button that
 * does it. Focus starts on Cancel, so a stray Enter never confirms.
 */
export function ConfirmDialog({ request, onClose }: { request: ConfirmRequest | null; onClose: () => void }) {
  if (!request) return null
  return <ConfirmSheet request={request} onClose={onClose} />
}

function ConfirmSheet({ request, onClose }: { request: ConfirmRequest; onClose: () => void }) {
  const { t } = useTranslation()
  const id = useId()
  const cancelRef = useRef<HTMLButtonElement>(null)
  const [checked, setChecked] = useState(false)

  useEffect(() => {
    cancelRef.current?.focus()
  }, [])

  const danger = request.option == null || checked
  const label = request.option && checked ? request.option.confirmLabel : request.confirmLabel
  const items = request.items ?? []

  return (
    <Modal labelledBy={`${id}-t`} describedBy={`${id}-b`} onClose={onClose} role="alertdialog" width={420} className="cf">
      <div className="sheet-h">
        <Icon name="trash" size="l" className={danger ? 'badc' : 'muted'} />
        <h2 className="h2" id={`${id}-t`}>
          {request.title}
        </h2>
      </div>
      <div className="sheet-b">
        <p className="small muted" id={`${id}-b`}>
          {request.body}
        </p>
        {items.length > 0 && (
          <ul className="cf-items">
            {items.map((item, i) => {
              const it = typeof item === 'string' ? { name: item } : item
              const kind = fileType({ name: it.name, kind: it.kind ?? 'http', statusToken: '' })
              return (
                <li key={`${i}:${it.name}`} className="cf-item small">
                  <Art kind={kind} size="xs" />
                  <span className="ell" title={it.name}>
                    {it.name}
                  </span>
                  {it.bytes != null && <span className="mono faint">{fmtSize(it.bytes)}</span>}
                </li>
              )
            })}
          </ul>
        )}
        {request.footnote && <p className="tiny muted cf-foot">{request.footnote}</p>}
        {request.option && (
          <label className={`cf-option small${checked ? ' on' : ''}`}>
            <input
              type="checkbox"
              className="check"
              checked={checked}
              onChange={(e) => setChecked(e.target.checked)}
            />
            <span>{request.option.label}</span>
          </label>
        )}
      </div>
      <div className="sheet-f">
        <span className="sp" />
        <button ref={cancelRef} type="button" className="btn" onClick={onClose}>
          {t('common.cancel')}
        </button>
        <button
          type="button"
          className={`btn pri${danger ? ' dang' : ''}`}
          onClick={() => {
            onClose()
            request.onConfirm(checked)
          }}
        >
          {label}
        </button>
      </div>
    </Modal>
  )
}
