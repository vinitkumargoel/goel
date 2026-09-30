import {
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type FocusEvent,
  type KeyboardEvent,
  type ReactNode,
} from 'react'
import { useTranslation } from 'react-i18next'
import { useMediaQuery } from '../hooks/useMediaQuery'
import { useNow } from '../hooks/useNow'
import { useStableCallback } from '../hooks/useStableCallback'
import { emptyState } from '../lib/emptyState'
import type { SelectionAction } from '../lib/selection'
import { ariaSort, type SortKey, type SortState } from '../lib/sort'
import type { RowAction } from '../lib/taskKind'
import type { TaskRow } from '../lib/types'
import { PlusIcon } from './Icons'
import { LibraryEmpty } from './LibraryEmpty'
import { LibraryRow, type RowClick } from './LibraryRow'

interface LibraryViewProps {
  /** Filtered and sorted: exactly the rows on screen, in order. */
  tasks: TaskRow[]
  /** Every task before search and filter, so the empty state can tell "none" from "none match". */
  total: number
  loaded: boolean
  /** The snapshot fetch is failing; before the first snapshot this shows an error with Retry. */
  error?: boolean
  search: string
  /** A sidebar filter other than "All" is active. */
  filtered?: boolean
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
  /** Clears the search and the sidebar filter. */
  onClearSearch: () => void
  onAdd: () => void
  onRetry?: () => void
  /**
   * The selection toolbar. It takes the column header's slot rather than pushing the rows down, so
   * a click never moves the row under the pointer.
   */
  bulk?: ReactNode
}

export function LibraryView({
  tasks,
  total,
  loaded,
  error = false,
  search,
  filtered = false,
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
  onRetry,
  bulk,
}: LibraryViewProps) {
  const { t } = useTranslation()
  const rowEls = useRef(new Map<string, HTMLDivElement>())
  const emptyRef = useRef<HTMLDivElement>(null)
  const [focusId, setFocusId] = useState<string | null>(null)
  const hintId = useId()
  const phone = useMediaQuery('(max-width: 680px)')
  const now = useNow(60_000)

  const order = useMemo(() => tasks.map((task) => task.id), [tasks])

  // Roving tabindex: the list is one tab stop, landing on the last-focused row, else the lead.
  const tabStop =
    (focusId && order.includes(focusId) ? focusId : null) ??
    (lead && order.includes(lead) ? lead : null) ??
    order[0] ??
    null

  const rowRef = useStableCallback((id: string, el: HTMLDivElement | null) => {
    if (el) rowEls.current.set(id, el)
    else rowEls.current.delete(id)
  })

  const focusRow = (id: string) => {
    setFocusId(id)
    rowEls.current.get(id)?.focus()
  }

  // Stable across snapshots: `order` changes every tick and would otherwise re-render every memoised row.
  const onRowClick = useStableCallback((id: string, mods: RowClick) => {
    setFocusId(id)
    if (mods.shift) onSelection({ type: 'range', id, order })
    else if (mods.toggle) onSelection({ type: 'toggle', id })
    else onOpen(id)
  })

  /** The last row that held focus, so a removal that takes it can hand focus to a neighbour. */
  const lastFocused = useRef<string | null>(null)
  const onListFocus = (e: FocusEvent<HTMLDivElement>) => {
    const id = (e.target as HTMLElement).closest<HTMLElement>('[role="option"]')?.dataset.id
    if (id != null) lastFocused.current = id
  }

  const prevOrder = useRef(order)
  useLayoutEffect(() => {
    const before = prevOrder.current
    prevOrder.current = order
    const gone = lastFocused.current
    if (before === order || gone == null || order.includes(gone)) return
    lastFocused.current = null
    // Only when the removal took focus with it: focus the user moved elsewhere stays put.
    const active = document.activeElement
    if (active && active !== document.body) return
    const at = before.indexOf(gone)
    const present = new Set(order)
    const neighbour =
      before.slice(at + 1).find((id) => present.has(id)) ??
      before.slice(0, Math.max(0, at)).reverse().find((id) => present.has(id))
    if (neighbour != null) {
      setFocusId(neighbour)
      rowEls.current.get(neighbour)?.focus()
    } else {
      emptyRef.current?.focus()
    }
  }, [order])

  const onKeyDown = (e: KeyboardEvent<HTMLDivElement>) => {
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'a') {
      e.preventDefault()
      onSelection({ type: 'all', order })
      return
    }
    // Keys pressed on a row's own buttons belong to those buttons.
    const target = e.target as HTMLElement
    if (target.getAttribute('role') !== 'option') return
    const current = target.dataset.id
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
        // Plain Space is the global pause/resume shortcut (see lib/shortcuts), so it must reach
        // the document unhandled; ⌘/Ctrl+Space adds or drops this row, like ⌘/Ctrl-click.
        if (!(e.metaKey || e.ctrlKey)) return
        e.preventDefault()
        onSelection({ type: 'toggle', id: current })
        return
      case 'Enter':
        e.preventDefault()
        onOpen(current)
        return
    }
  }

  const state = tasks.length === 0 ? emptyState({ loaded, error, total, search, canWrite }) : null

  return (
    <div className="view">
      {readOnly && <div className="ro-banner">{t('library.readOnlyBanner')}</div>}

      {/* Plain headers, not role=columnheader: the list is a listbox, not a grid, so the sort
          state lives in each button's name. hide-* must match the cells in LibraryRow AND the
          ≤920px grid in portal.css and the list-width grids in features.css, or a label loses its
          column. */}
      {bulk ? (
        // The bulk bar takes the header's slot; sorting stays reachable beside it.
        <div className="lbulk">
          {bulk}
          <SortPicker sort={sort} onSort={onSort} />
        </div>
      ) : (
        <div className="lhead">
          <SortHeader sortKey="name" sort={sort} onSort={onSort} label={t('library.colName')} />
          <SortHeader
            sortKey="size"
            sort={sort}
            onSort={onSort}
            label={t('library.colSize')}
            className="r"
          />
          {/* ETA lives in the Status column now, so it is that column's second sort. */}
          <div className="hide-sm lhead-pair">
            <SortHeader sortKey="status" sort={sort} onSort={onSort} label={t('library.colStatus')} />
            <SortHeader sortKey="eta" sort={sort} onSort={onSort} label={t('library.colEta')} />
          </div>
          <SortHeader
            sortKey="speed"
            sort={sort}
            onSort={onSort}
            label={t('library.colSpeed')}
            className="r hide-xs"
          />
          <SortHeader
            sortKey="added"
            sort={sort}
            onSort={onSort}
            label={t('library.colAdded')}
            className="hide-lg"
          />
        </div>
      )}

      {state ? (
        <div className="rows" ref={emptyRef} tabIndex={-1}>
          <LibraryEmpty
            state={state}
            search={search}
            filtered={filtered}
            onClearSearch={onClearSearch}
            onAdd={onAdd}
            onRetry={onRetry}
          />
        </div>
      ) : (
        <div
          className="rows"
          role="listbox"
          aria-label={t('library.queueLabel')}
          aria-multiselectable="true"
          onKeyDown={onKeyDown}
          onFocus={onListFocus}
        >
          {tasks.map((task) => (
            <LibraryRow
              key={task.id}
              task={task}
              selected={selectedIds.has(task.id)}
              focusable={task.id === tabStop}
              canWrite={canWrite}
              phone={phone}
              now={now}
              describedBy={hintId}
              rowRef={rowRef}
              onClick={onRowClick}
              onAction={onAction}
              onMenu={onMenu}
            />
          ))}
        </div>
      )}
      <span id={hintId} hidden>
        {t('library.actionsHint')}
      </span>
      {/* The ≤680px floating Add button (CSS hides it wider, where the topbar's Add shows). */}
      {canWrite && (
        <button className="fab" onClick={onAdd} aria-label={t('topbar.addDownload')} aria-keyshortcuts="N">
          <PlusIcon aria-hidden="true" />
        </button>
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

const SORT_KEYS: readonly SortKey[] = ['name', 'size', 'status', 'eta', 'speed', 'added']
const SORT_LABEL = {
  name: 'library.colName',
  size: 'library.colSize',
  status: 'library.colStatus',
  eta: 'library.colEta',
  speed: 'library.colSpeed',
  added: 'library.colAdded',
} as const

/** The header's sort as one compact control, for when the bulk bar has the header's slot. */
function SortPicker({ sort, onSort }: Pick<SortHeaderProps, 'sort' | 'onSort'>) {
  const { t } = useTranslation()
  const id = useId()
  return (
    <div className="sortpick">
      <label htmlFor={id} className="sr-only">
        {t('library.sortBy')}
      </label>
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
      {sort.key != null && (
        <button
          type="button"
          className="sorth"
          title={t('library.sortFlip')}
          aria-label={t(sort.dir === 'asc' ? 'library.sortedAscending' : 'library.sortedDescending', {
            label: t(SORT_LABEL[sort.key]),
          })}
          onClick={() => onSort(sort.key!)}
        >
          <span className="sarrow" aria-hidden="true">
            {sort.dir === 'asc' ? '▲' : '▼'}
          </span>
        </button>
      )}
    </div>
  )
}

function SortHeader({ sortKey, sort, label, className, onSort }: SortHeaderProps) {
  const { t } = useTranslation()
  const state = ariaSort(sort, sortKey)
  const name =
    state === 'ascending'
      ? t('library.sortedAscending', { label })
      : state === 'descending'
        ? t('library.sortedDescending', { label })
        : undefined
  return (
    <div className={className}>
      <button type="button" className="sorth" aria-label={name} onClick={() => onSort(sortKey)}>
        {label}
        <span className="sarrow" aria-hidden="true">
          {state === 'ascending' ? '▲' : state === 'descending' ? '▼' : ''}
        </span>
      </button>
    </div>
  )
}
