import { Fragment, useEffect, useId, useRef } from 'react'
import { useTranslation } from 'react-i18next'
import { SHORTCUT_DOCS, type ShortcutDoc } from '../../lib/shortcuts'
import { Icon } from '../ui/Icon'
import { Modal } from '../ui/Modal'

interface ShortcutsDialogProps {
  onClose: () => void
}

/** The "?" cheat sheet: two columns, Navigation and Actions, keys as kbd chips. */
export function ShortcutsDialog({ onClose }: ShortcutsDialogProps) {
  const { t } = useTranslation()
  const closeRef = useRef<HTMLButtonElement>(null)
  const titleId = useId()

  useEffect(() => {
    closeRef.current?.focus()
  }, [])

  const column = (title: string, docs: readonly ShortcutDoc[]) => (
    <section className="keys-col">
      <h3 className="eyebrow">{title}</h3>
      <dl className="keys-list">
        {docs.map((doc) => (
          <div className="keys-row" key={doc.labelKey}>
            <dt>
              {doc.keys.map((k, i) => (
                <Fragment key={k}>
                  {i > 0 && <span className="keys-plus tiny muted">{doc.sequence ? t('workflow.shortcuts.then') : '+'}</span>}
                  <kbd className="kbd">{k}</kbd>
                </Fragment>
              ))}
            </dt>
            <dd className="small">{t(doc.labelKey)}</dd>
          </div>
        ))}
      </dl>
    </section>
  )

  return (
    <Modal labelledBy={titleId} onClose={onClose} width={720} className="keys">
      <div className="sheet-h">
        <Icon name="keyboard" size="l" className="acc" />
        <h2 className="h2" id={titleId}>
          {t('shortcuts.title')}
        </h2>
        <span className="sp" />
        <button ref={closeRef} type="button" className="ibtn" onClick={onClose} aria-label={t('common.close')}>
          <Icon name="x" />
        </button>
      </div>
      <div className="sheet-b keys-grid">
        {column(t('shortcuts.navigation'), SHORTCUT_DOCS.navigation)}
        {column(t('shortcuts.actions'), SHORTCUT_DOCS.actions)}
      </div>
    </Modal>
  )
}
