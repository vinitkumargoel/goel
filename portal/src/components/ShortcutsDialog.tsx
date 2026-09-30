import { Fragment, useEffect, useId, useRef } from 'react'
import { useTranslation } from 'react-i18next'
import { useDialogFocus } from '../hooks/useDialogFocus'
import { SHORTCUT_DOCS, type ShortcutDoc } from '../lib/shortcuts'
import { CloseIcon } from './Icons'

interface ShortcutsDialogProps {
  onClose: () => void
}

/** The "?" cheat sheet: two columns, Navigation and Actions, keys as kbd chips. */
export function ShortcutsDialog({ onClose }: ShortcutsDialogProps) {
  const { t } = useTranslation()
  const ref = useRef<HTMLDivElement>(null)
  const closeRef = useRef<HTMLButtonElement>(null)
  const titleId = useId()
  useDialogFocus(ref, { onEscape: onClose })

  useEffect(() => {
    closeRef.current?.focus()
  }, [])

  const column = (title: string, docs: readonly ShortcutDoc[]) => (
    <section className="kcol">
      <h4 className="slbl">{title}</h4>
      <dl>
        {docs.map((doc) => (
          <div className="krow" key={doc.labelKey}>
            <dt>
              {doc.keys.map((k, i) => (
                <Fragment key={k}>
                  {i > 0 && <span className="kplus">+</span>}
                  <kbd className="kbd">{k}</kbd>
                </Fragment>
              ))}
            </dt>
            <dd>{t(doc.labelKey)}</dd>
          </div>
        ))}
      </dl>
    </section>
  )

  return (
    <div
      className="scrim open"
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose()
      }}
    >
      <div className="modal kmodal" ref={ref} role="dialog" aria-modal="true" aria-labelledby={titleId}>
        <div className="mhead">
          <h3 id={titleId}>{t('shortcuts.title')}</h3>
          <button ref={closeRef} className="dx" onClick={onClose} aria-label={t('common.close')}>
            <CloseIcon />
          </button>
        </div>
        <div className="mbody kgrid">
          {column(t('shortcuts.navigation'), SHORTCUT_DOCS.navigation)}
          {column(t('shortcuts.actions'), SHORTCUT_DOCS.actions)}
        </div>
      </div>
    </div>
  )
}
