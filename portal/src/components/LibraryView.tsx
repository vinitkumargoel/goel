import { useCallback, useMemo, useRef, useState, type KeyboardEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { emptyState } from '../lib/emptyState'
import type { SelectionAction } from '../lib/selection'
import { ariaSort, type SortKey, type SortState } from '../lib/sort'
import type { RowAction } from '../lib/taskKind'
import type { TaskRow } from '../lib/types'
import { LibraryEmpty } from './LibraryEmpty'
import { LibraryRow, type RowClick } from './LibraryRow'

interface LibraryViewProps {
  /** Filtered and sorted: exactly the rows on screen, in order. */
  tasks: TaskRow[]
  /** Every task before search and filter, so the empty state can tell "none" from "none match". */
  total: number
  loaded: boolean
  search: string
  selectedIds: ReadonlySet<string>
  lead: string | null
  sort: SortState
  canWrite: boolean
  readOnly: boolean
  onSelection: (action: SelectionAction) => void
  /** A plain click or Enter: the row becomes the only selection and the detail panel opens. */
  onOpen: (id: string) => void
  onSort: (key: SortKey) => void
  onAction: (id: string, action: RowAction) => void
  onMenu: (id: string, x: number, y: number) => void
  onClearSearch: () => void
  onAdd: () => void
}

export function LibraryView({
  tasks,
  total,
  loaded,
  search,
  selectedIds,
  lead,
  sort,
  canWrite,
  readOnly,
  onSelection,
  onOpen,
  onSort,
  onAction,
  onMenu,
  onClearSearch,
  onAdd,
}: LibraryViewProps) {
  const { t } = useTranslation()
  const rowEls = useRef(new Map<string, HTMLDivElement>())
  const [focusId, setFocusId] = useState<string | null>(null)

  const order = useMemo(() => tasks.map((task) => task.id), [tasks])

  // Roving tabindex: the list is one tab stop, landing on the last-focused row, else the lead.
  const tabStop =
    (focusId && order.includes(focusId) ? focusId : null) ??
    (lead && order.includes(lead) ? lead : null) ??
    order[0] ??
    null

  const rowRef = useCallback((id: string, el: HTMLDivElement | null) => {
    if (el) rowEls.current.set(id, el)
    else rowEls.current.delete(id)
  }, [])

  const focusRow = (id: string) => {
    setFocusId(id)
    rowEls.current.get(id)?.focus()
  }

  const onRowClick = useCallback(
    (id: string, mods: RowClick) => {
      setFocusId(id)
      if (mods.shift) onSelection({ type: 'range', id, order })
      else if (mods.toggle) onSelection({ type: 'toggle', id })
      else onOpen(id)
    },
    [onSelection, onOpen, order],
  )

  const onKeyDown = (e: KeyboardEvent<HTMLDivElement>) => {
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'a') {
      e.preventDefault()
      onSelection({ type: 'all', order })
      return
    }
    // Keys pressed on a row's own buttons belong to those buttons.
    const target = e.target as HTMLElement
    if (target.getAttribute('role') !== 'option') return
    const current = [...rowEls.current].find(([, el]) => el === target)?.[0]
    if (current == null) return
    const at = order.indexOf(current)

    const moveTo = (index: number) => {
      const id = order[Math.max(0, Math.min(order.length - 1, index))]
      if (id == null) return
      e.preventDefault()
      onSelection(e.shiftKey ? { type: 'range', id, order } : { type: 'single', id })
      focusRow(id)
    }

    if ((e.shiftKey && e.key === 'F10') || e.key === 'ContextMenu') {
      e.preventDefault()
      const r = target.getBoundingClientRect()
      onMenu(current, r.left + 40, r.top + r.height / 2)
      return
    }
    switch (e.key) {
      case 'ArrowDown':
        return moveTo(at + 1)
      case 'ArrowUp':
        return moveTo(at - 1)
      case 'Home':
        return moveTo(0)
      case 'End':
        return moveTo(order.length - 1)
      case ' ':
        e.preventDefault()
        onSelection({ type: 'toggle', id: current })
        return
      case 'Enter':
        e.preventDefault()
        onOpen(current)
        return
    }
  }

  const state = tasks.length === 0 ? emptyState({ loaded, total, search, canWrite }) : null

  return (
    <div className="view">
      {readOnly && <div className="ro-banner">{t('library.readOnlyBanner')}</div>}

      {/* hide-* must match the cells in LibraryRow AND portal.css's ≤920px grid, or a label loses its column. */}
      <div className="lhead" role="row">
        <SortHeader sortKey="name" sort={sort} onSort={onSort} label={t('library.colName')} />
        <SortHeader
          sortKey="size"
          sort={sort}
          onSort={onSort}
          label={t('library.colSize')}
          className="r"
        />
        <SortHeader
          sortKey="status"
          sort={sort}
          onSort={onSort}
          label={t('library.colStatus')}
          className="hide-sm"
        />
        <div className="r hide-xs" role="columnheader">
          {t('library.colSpeed')}
        </div>
      </div>

      {state ? (
        <div className="rows">
          <LibraryEmpty state={state} search={search} onClearSearch={onClearSearch} onAdd={onAdd} />
        </div>
      ) : (
        <div
          className="rows"
          role="listbox"
          aria-label={t('library.queueLabel')}
          aria-multiselectable="true"
          onKeyDown={onKeyDown}
        >
          {tasks.map((task) => (
            <LibraryRow
              key={task.id}
              task={task}
              selected={selectedIds.has(task.id)}
              focusable={task.id === tabStop}
              canWrite={canWrite}
              rowRef={rowRef}
              onClick={onRowClick}
              onAction={onAction}
              onMenu={onMenu}
            />
          ))}
        </div>
      )}
    </div>
  )
}

interface SortHeaderProps {
  sortKey: SortKey
  sort: SortState
  label: string
  className?: string
  onSort: (key: SortKey) => void
}

function SortHeader({ sortKey, sort, label, className, onSort }: SortHeaderProps) {
  const state = ariaSort(sort, sortKey)
  return (
    <div className={className} role="columnheader" aria-sort={state}>
      <button type="button" className="sorth" onClick={() => onSort(sortKey)}>
        {label}
        <span className="sarrow" aria-hidden="true">
          {state === 'ascending' ? '▲' : state === 'descending' ? '▼' : ''}
        </span>
      </button>
    </div>
  )
}
