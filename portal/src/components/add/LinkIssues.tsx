import { useTranslation } from 'react-i18next'
import { nameFromLink } from '../../lib/addReview'
import type { LinkLine } from '../../lib/links'
import { kindBadge } from '../../lib/taskKind'
import { Icon } from '../ui/Icon'
import { lineHost, lineKind } from './addHelpers'

/** How many recognised lines the first step lists before "and N more". */
export const RECOGNISED_SHOWN = 6

interface LinkIssuesProps {
  id: string
  /** Every non-blank line, in order. */
  lines: readonly LinkLine[]
  valid: number
  unsupported: readonly LinkLine[]
  /** Removes every copy of that line from the textarea. */
  onRemove: (text: string) => void
}

/**
 * Live feedback on a paste: how many links will queue and what each looks like (its protocol and
 * host, read from the line itself), then each line that won't, with a ✕ to drop it.
 */
export function LinkIssues({ id, lines, valid, unsupported, onRemove }: LinkIssuesProps) {
  const { t } = useTranslation()
  // One entry per distinct text: removing it removes every copy.
  const distinct = [...new Set(unsupported.map((l) => l.text))]
  const recognised = lines.filter((l) => l.supported)
  const shown = recognised.slice(0, RECOGNISED_SHOWN)
  const hidden = recognised.length - shown.length
  if (valid === 0 && distinct.length === 0) return <div id={id} className="add-links" aria-live="polite" />
  return (
    <div id={id} className="add-links" aria-live="polite">
      <span className="eyebrow">{t('addDialog.linksDetected', { count: valid })}</span>
      {shown.length > 0 && (
        <ul className="add-recog">
          {shown.map((line, i) => {
            const host = lineHost(line.text)
            return (
              <li key={`${i}:${line.text}`} className="add-recog-row small">
                <span className="badge">{kindBadge(lineKind(line.text))}</span>
                <span className="ell" title={line.text}>
                  {nameFromLink(line.text)}
                </span>
                {/* Every supported line but a magnet has a host. */}
                <span className="faint ell add-recog-host">{host ?? t('adding.magnetLink')}</span>
              </li>
            )
          })}
          {hidden > 0 && (
            <li className="add-recog-row small faint">{t('workflow.add.moreFiles', { count: hidden })}</li>
          )}
        </ul>
      )}
      {distinct.length > 0 && (
        <div className="note warn add-bad">
          <Icon name="alert" />
          <div className="col add-bad-body">
            <span>{t('addDialog.unsupportedLines', { count: unsupported.length })}</span>
            <ul className="add-badlines">
              {distinct.map((text) => (
                <li key={text} className="add-badline">
                  <span className="mono small ell" title={text}>
                    {text}
                  </span>
                  <button
                    type="button"
                    className="ibtn sm"
                    onClick={() => onRemove(text)}
                    aria-label={t('addDialog.removeLine', { line: text })}
                  >
                    <Icon name="x" size="s" />
                  </button>
                </li>
              ))}
            </ul>
          </div>
        </div>
      )}
    </div>
  )
}
