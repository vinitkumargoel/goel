import { useId } from 'react'
import { useTranslation } from 'react-i18next'
import { ariaSort, type SortKey, type SortState } from '../../lib/sort'
import { Icon } from '../ui/Icon'

export const SORT_KEYS: readonly SortKey[] = ['name', 'size', 'status', 'eta', 'speed', 'added']

export const SORT_LABEL = {
  name: 'library.colName',
  size: 'library.colSize',
  status: 'library.colStatus',
  eta: 'library.colEta',
  speed: 'library.colSpeed',
  added: 'library.colAdded',
} as const

interface SortProps {
  sort: SortState
  onSort: (key: SortKey) => void
}

/** The sort as one compact control, for where there are no column headers (the board, a phone). */
export function SortPicker({ sort, onSort }: SortProps) {
  const { t } = useTranslation()
  const id = useId()
  return (
    <span className="sortpick">
      <label htmlFor={id} className="sr-only">
        {t('library.sortBy')}
      </label>
      <span className="field sm select">
        <select id={id} value={sort.key ?? ''} onChange={(e) => onSort(e.target.value as SortKey)}>
          {sort.key == null && (
            <option value="" disabled>
              {t('library.sortNone')}
            </option>
          )}
          {SORT_KEYS.map((key) => (
            <option key={key} value={key}>
              {t(SORT_LABEL[key])}
            </option>
          ))}
        </select>
        <Icon name="chevronDown" size="s" />
      </span>
      {sort.key != null && (
        <button
          type="button"
          className="ibtn sm b"
          title={t('library.sortFlip')}
          aria-label={t(sort.dir === 'asc' ? 'library.sortedAscending' : 'library.sortedDescending', {
            label: t(SORT_LABEL[sort.key]),
          })}
          onClick={() => onSort(sort.key!)}
        >
          <Icon name={sort.dir === 'asc' ? 'up' : 'down'} size="s" />
        </button>
      )}
    </span>
  )
}

interface SortHeaderProps extends SortProps {
  sortKey: SortKey
  className?: string
}

/**
 * A column header. Plain buttons, not role=columnheader: the list is a listbox, not a grid, so the
 * sort state lives in each button's name.
 */
export function SortHeader({ sortKey, sort, onSort, className }: SortHeaderProps) {
  const { t } = useTranslation()
  const label = t(SORT_LABEL[sortKey])
  const state = ariaSort(sort, sortKey)
  const name =
    state === 'ascending'
      ? t('library.sortedAscending', { label })
      : state === 'descending'
        ? t('library.sortedDescending', { label })
        : undefined
  return (
    <button
      type="button"
      className={`lt-sort${state !== 'none' ? ' on' : ''}${className ? ` ${className}` : ''}`}
      aria-label={name}
      onClick={() => onSort(sortKey)}
    >
      {label}
      {state !== 'none' && <Icon name={state === 'ascending' ? 'chevronUp' : 'chevronDown'} size="s" />}
    </button>
  )
}
