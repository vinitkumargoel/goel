import { Trans, useTranslation } from 'react-i18next'
import type { EmptyState } from '../../lib/emptyState'
import { Icon, type IconName } from '../ui/Icon'

interface LibraryEmptyProps {
  state: EmptyState
  search: string
  /** A filter or tag is narrowing the list too, so clearing the search alone may not help. */
  filtered?: boolean
  /** Clears the search and the filter. */
  onClearSearch: () => void
  onAdd: () => void
  onRetry?: (() => void) | undefined
}

function Glyph({ name, tone = '' }: { name: IconName; tone?: string }) {
  return (
    <span className={`lib-glyph${tone ? ` ${tone}` : ''}`} aria-hidden="true">
      <Icon name={name} size="xl" />
    </span>
  )
}

/** What the library says when it has nothing to show, fitted to why. */
export function LibraryEmpty({ state, search, filtered = false, onClearSearch, onAdd, onRetry }: LibraryEmptyProps) {
  const { t } = useTranslation()

  if (state === 'loading') {
    return (
      <div className="empty" role="status">
        <span className="lib-spin" aria-hidden="true" />
        <p className="muted">{t('common.loading')}</p>
      </div>
    )
  }

  if (state === 'error') {
    return (
      <div className="empty" role="alert">
        <Glyph name="wifiOff" tone="bad" />
        <h2 className="h2">{t('library.loadErrorTitle')}</h2>
        <p className="muted">{t('library.loadErrorBody')}</p>
        {onRetry && (
          <button type="button" className="btn" onClick={onRetry}>
            <Icon name="retry" />
            {t('common.retry')}
          </button>
        )}
      </div>
    )
  }

  if (state === 'noMatch') {
    return (
      <div className="empty">
        <Glyph name="search" />
        <h2 className="h2">{t('library.noMatchTitle', { search: search.trim() })}</h2>
        <p className="muted">{t('library.noMatchBody')}</p>
        <button type="button" className="btn" onClick={onClearSearch}>
          <Icon name="x" />
          {t(filtered ? 'library.clearSearchAndFilter' : 'library.clearSearch')}
        </button>
      </div>
    )
  }

  return (
    <div className="empty">
      <Glyph name={state === 'emptyFilter' ? 'filter' : 'inbox'} tone={state === 'emptyQueue' ? 'acc' : ''} />
      <h2 className="h2">{t(state === 'emptyFilter' ? 'library.emptyTitle' : 'library.emptyQueueTitle')}</h2>
      <p className="muted">
        {state === 'emptyQueue' && (
          // The bolded word is the Add button's own label, so it has to come from that key.
          <Trans i18nKey="library.emptyBody" values={{ addLabel: t('common.add') }} components={{ bold: <b /> }} />
        )}
        {state === 'emptyReadOnly' && t('library.emptyReadOnlyBody')}
        {state === 'emptyFilter' && t('library.emptyFilterBody')}
      </p>
      {state === 'emptyQueue' && (
        <button type="button" className="btn pri" onClick={onAdd}>
          <Icon name="plus" />
          {t('common.add')}
        </button>
      )}
    </div>
  )
}
