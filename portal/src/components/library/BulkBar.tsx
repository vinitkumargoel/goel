import { useTranslation } from 'react-i18next'
import { eligibleFor } from '../../lib/bulk'
import type { RowAction } from '../../lib/taskKind'
import type { TaskRow } from '../../lib/types'
import { Icon } from '../ui/Icon'

export { eligibleFor }

interface BulkBarProps {
  selected: TaskRow[]
  canWrite: boolean
  onAction: (action: RowAction, ids: string[]) => void
  onCopyLinks: (sources: string[]) => void
  onRemove: (ids: string[]) => void
  onClear: () => void
  /** Touch select mode: a Done button ends it instead of the ✕ clearing the selection. */
  onDone?: () => void
  className?: string
}

const ACTIONS: readonly { action: RowAction; icon: 'pause' | 'play' | 'retry' }[] = [
  { action: 'pause', icon: 'pause' },
  { action: 'resume', icon: 'play' },
  { action: 'retry', icon: 'retry' },
]

/**
 * The selection's actions, floating at the bottom of the library. Each fans out to the per-id
 * endpoints; a button only appears when a selected download can take it. For a single row it is
 * the keyboard and screen-reader home of the row actions (select mode on a phone).
 */
export function BulkBar({ selected, canWrite, onAction, onCopyLinks, onRemove, onClear, onDone, className }: BulkBarProps) {
  const { t } = useTranslation()
  return (
    <div className={`bulkbar${className ? ` ${className}` : ''}`} role="toolbar" aria-label={t('bulk.toolbar')}>
      <span className="bk-count" aria-live="polite">
        {t('bulk.selected', { count: selected.length })}
      </span>
      {canWrite &&
        ACTIONS.map(({ action, icon }) => {
          const ids = eligibleFor(selected, action)
          if (ids.length === 0) return null
          return (
            <button key={action} type="button" className="btn sm ghost" onClick={() => onAction(action, ids)}>
              <Icon name={icon} />
              {t(`bulk.${action}`, { count: ids.length })}
            </button>
          )
        })}
      {selected.length > 0 && (
        <button type="button" className="btn sm ghost" onClick={() => onCopyLinks(selected.map((task) => task.source))}>
          <Icon name="link" />
          {selected.length === 1 ? t('common.copyLink') : t('bulk.copyLinks')}
        </button>
      )}
      {canWrite && selected.length > 0 && (
        <button type="button" className="btn sm ghost bk-remove" onClick={() => onRemove(selected.map((task) => task.id))}>
          <Icon name="trash" />
          {t('common.remove')}
        </button>
      )}
      <span className="sp" />
      {onDone ? (
        <button type="button" className="btn sm pri" onClick={onDone}>
          {t('workflow.library.done')}
        </button>
      ) : (
        <button type="button" className="ibtn sm" onClick={onClear} aria-label={t('bulk.clear')} title={t('bulk.clear')}>
          <Icon name="x" size="s" />
        </button>
      )}
    </div>
  )
}
