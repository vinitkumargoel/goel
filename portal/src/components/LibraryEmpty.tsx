import { Trans, useTranslation } from 'react-i18next'
import type { EmptyState } from '../lib/emptyState'
import { DownloadIcon, PlusIcon, RetryIcon, SearchIcon, WarnIcon } from './Icons'

interface LibraryEmptyProps {
  state: EmptyState
  search: string
  /** A sidebar filter is narrowing the list too, so clearing the search alone may not help. */
  filtered?: boolean
  /** Clears the search and the sidebar filter. */
  onClearSearch: () => void
  onAdd: () => void
  onRetry?: () => void
}

export function LibraryEmpty({
  state,
  search,
  filtered = false,
  onClearSearch,
  onAdd,
  onRetry,
}: LibraryEmptyProps) {
  const { t } = useTranslation()

  if (state === 'loading') {
    return (
      <div className="empty" role="status">
        <p>{t('common.loading')}</p>
      </div>
    )
  }

  if (state === 'error') {
    return (
      <div className="empty" role="alert">
        <div>
          <WarnIcon />
          <h4>{t('library.loadErrorTitle')}</h4>
          <p>{t('library.loadErrorBody')}</p>
          {onRetry && (
            <button className="btn empty-cta" onClick={onRetry}>
              <RetryIcon />
              {t('common.retry')}
            </button>
          )}
        </div>
      </div>
    )
  }

  if (state === 'noMatch') {
    return (
      <div className="empty">
        <div>
          <SearchIcon />
          <h4>{t('library.noMatchTitle', { search: search.trim() })}</h4>
          <p>{t('library.noMatchBody')}</p>
          <button className="btn empty-cta" onClick={onClearSearch}>
            {t(filtered ? 'library.clearSearchAndFilter' : 'library.clearSearch')}
          </button>
        </div>
      </div>
    )
  }

  return (
    <div className="empty">
      <div>
        <DownloadIcon />
        <h4>{t(state === 'emptyFilter' ? 'library.emptyTitle' : 'library.emptyQueueTitle')}</h4>
        <p>
          {state === 'emptyQueue' && (
            // The bolded word is the Add button's own label, so it has to come from that key.
            <Trans
              i18nKey="library.emptyBody"
              values={{ addLabel: t('common.add') }}
              components={{ bold: <b /> }}
            />
          )}
          {state === 'emptyReadOnly' && t('library.emptyReadOnlyBody')}
          {state === 'emptyFilter' && t('library.emptyFilterBody')}
        </p>
        {state === 'emptyQueue' && (
          <button className="btn primary empty-cta" onClick={onAdd}>
            <PlusIcon />
            {t('common.add')}
          </button>
        )}
      </div>
    </div>
  )
}
