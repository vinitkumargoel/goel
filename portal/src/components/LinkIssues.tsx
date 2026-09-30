import { useTranslation } from 'react-i18next'
import type { LinkLine } from '../lib/links'
import { CloseIcon } from './Icons'

interface LinkIssuesProps {
  id: string
  valid: number
  unsupported: readonly LinkLine[]
  /** Removes every copy of that line from the textarea. */
  onRemove: (text: string) => void
}

/** Live feedback on a paste: how many links will queue, and each line that won't, with a ✕. */
export function LinkIssues({ id, valid, unsupported, onRemove }: LinkIssuesProps) {
  const { t } = useTranslation()
  // One entry per distinct text: removing it removes every copy.
  const distinct = [...new Set(unsupported.map((l) => l.text))]
  return (
    <div className="fcount" id={id} aria-live="polite">
      {(valid > 0 || distinct.length > 0) && <span>{t('addDialog.linksDetected', { count: valid })}</span>}
      {distinct.length > 0 && (
        <>
          <span className="fwarn">
            {' · '}
            {t('addDialog.unsupportedLines', { count: unsupported.length })}
          </span>
          <ul className="badlines">
            {distinct.map((text) => (
              <li key={text} className="badline">
                <span className="badline-t" title={text}>
                  {text}
                </span>
                <button
                  type="button"
                  className="tchip-x"
                  onClick={() => onRemove(text)}
                  aria-label={t('addDialog.removeLine', { line: text })}
                >
                  <CloseIcon aria-hidden="true" />
                </button>
              </li>
            ))}
          </ul>
        </>
      )}
    </div>
  )
}
