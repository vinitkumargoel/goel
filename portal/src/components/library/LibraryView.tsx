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
import { useLongPress } from '../../hooks/useLongPress'
import { useMediaQuery } from '../../hooks/useMediaQuery'
import { useNow } from '../../hooks/useNow'
import { useStableCallback } from '../../hooks/useStableCallback'
import { PHONE_QUERY } from '../../lib/breakpoints'
import { emptyState } from '../../lib/emptyState'
import type { GroupBy, TaskGroup } from '../../lib/grouping'
import { boardLanes, flattenLanes, laneNeighbor } from '../../lib/lanes'
import type { Density, LibraryLayout } from '../../lib/libraryPrefs'
import { limitToInclude, WINDOW_PAGE, windowIds } from '../../lib/renderWindow'
import type { SelectionAction } from '../../lib/selection'
import type { SortKey, SortState } from '../../lib/sort'
import type { RowAction } from '../../lib/taskKind'
import type { TaskRow } from '../../lib/types'
import { Board } from './Board'
import type { ItemClick } from './itemShared'
import { LibraryEmpty } from './LibraryEmpty'
import { TableBody, TableHead } from './TableView'

interface LibraryViewProps {
  /** Filtered and sorted (and, grouped, section by section): exactly the downloads on screen. */
  tasks: TaskRow[]
  /** Every task before search and filter, so the empty state can tell "none" from "none match". */
  total: number
  loaded: boolean
  /** The snapshot fetch is failing; before the first snapshot this shows an error with Retry. */
  error?: boolean
  search: string
  /** A filter or tag other than "All" is active. */
  filtered?: boolean
  selectedIds: ReadonlySet<string>
  lead: string | null
  sort: SortState
  canWrite: boolean
  /** The shell shows the read-only banner; kept so callers need not special-case it. */
  readOnly?: boolean
  onSelection: (action: SelectionAction) => void
  /** A plain click or Enter: the item becomes the only selection and the detail panel opens. */
  onOpen: (id: string) => void
  onSort: (key: SortKey) => void
  onAction: (id: string, action: RowAction) => void
  onMenu: (id: string, x: number, y: number) => void
  /** Clears the search and the filter. */
  onClearSearch: () => void
  onAdd: () => void
  onRetry?: () => void
  /** Plays a finished, streamable download (a board card's Play button). */
  onStream?: (task: TaskRow) => void
  /** The selection toolbar for two or more; it floats at the bottom so nothing under the pointer moves. */
  bulk?: ReactNode
  /** Table sections, in display order; `tasks` is then their concatenation. Null or empty: flat. */
  groups?: readonly TaskGroup[] | null
  /** What the board lanes by: status lanes for 'none', else the same groups as the table. */
  group?: GroupBy
  density?: Density
  layout?: LibraryLayout
  /** The filter chips row. */
  chips?: ReactNode
  /** The view controls (count, sort, group, density, layout). */
  tools?: ReactNode
  /**
   * Touch select mode: entered by a long press, items show checkboxes and a tap toggles. The
   * `selectBar` docks at the bottom.
   */
  selecting?: boolean
  onSelecting?: (on: boolean) => void
  selectBar?: ReactNode
  /** Items to scroll to and pulse once, e.g. just added. A new `seq` repeats it. */
  reveal?: { ids: readonly string[]; seq: number } | null
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
  onSelection,
  onOpen,
  onSort,
  onAction,
  onMenu,
  onClearSearch,
  onAdd,
  onRetry,
  onStream,
  bulk,
  groups = null,
  group = 'none',
  density = 'comfortable',
  layout = 'board',
  chips,
  tools,
  selecting = false,
  onSelecting,
  selectBar,
  reveal = null,
}: LibraryViewProps) {
  const { t } = useTranslation()
  const itemEls = useRef(new Map<string, HTMLElement>())
  const emptyRef = useRef<HTMLDivElement>(null)
  const [focusId, setFocusId] = useState<string | null>(null)
  const hintId = useId()
  const phone = useMediaQuery(PHONE_QUERY)
  const now = useNow(60_000)
  const board = layout === 'board'

  const lanes = useMemo(() => (board ? boardLanes(tasks, group, now) : []), [board, tasks, group, now])
  // Keyboard and Shift-click ranges walk what the eye reads: lane by lane on the board.
  const order = useMemo(
    () => (board ? flattenLanes(lanes) : tasks).map((task) => task.id),
    [board, lanes, tasks],
  )

  // Roving tabindex: the list is one tab stop, landing on the last-focused item, else the lead.
  const tabStop =
    (focusId && order.includes(focusId) ? focusId : null) ??
    (lead && order.includes(lead) ? lead : null) ??
    order[0] ??
    null

  const itemRef = useStableCallback((id: string, el: HTMLElement | null) => {
    if (el) itemEls.current.set(id, el)
    else itemEls.current.delete(id)
  })

  // A long list draws a window of `order`; the keyboard still walks all of it (see lib/renderWindow).
  const [limit, setLimit] = useState(WINDOW_PAGE)
  const allowed = useMemo(() => windowIds(order, limit), [order, limit])
  const pendingFocus = useRef<string | null>(null)

  const focusItem = (id: string) => {
    setFocusId(id)
    const el = itemEls.current.get(id)
    if (el) return el.focus()
    // Not drawn yet: widen the window, and focus it once it is.
    pendingFocus.current = id
    setLimit((n) => limitToInclude(order, n, id))
  }
  useLayoutEffect(() => {
    const id = pendingFocus.current
    const el = id ? itemEls.current.get(id) : undefined
    if (!el) return
    pendingFocus.current = null
    el.focus()
  }, [limit])

  // Stable across snapshots: `order` changes every tick and would otherwise re-render every memoised item.
  const onItemClick = useStableCallback((id: string, mods: ItemClick) => {
    setFocusId(id)
    if (mods.shift) onSelection({ type: 'range', id, order })
    else if (mods.toggle || selecting) onSelection({ type: 'toggle', id })
    else onOpen(id)
  })

  // A long press enters select mode with that item ticked (touch only: a mouse has ⌘-click).
  const longPress = useLongPress((target) => {
    const id = target.closest<HTMLElement>('[role="option"]')?.dataset.id
    if (id == null) return
    if (!selecting) onSelecting?.(true)
    onSelection(selecting ? { type: 'toggle', id } : { type: 'set', ids: [id] })
  })

  // Scroll the first revealed item into view and pulse each one once, as soon as they render.
  const revealed = useRef(0)
  useLayoutEffect(() => {
    if (!reveal || revealed.current === reveal.seq) return
    const els = reveal.ids.flatMap((id) => itemEls.current.get(id) ?? [])
    if (els.length === 0) {
      // A revealed row beyond the drawn window: widen it, and the effect runs again.
      const first = reveal.ids[0]
      if (first != null) setLimit((n) => limitToInclude(order, n, first))
      return
    }
    revealed.current = reveal.seq
    els[0]!.scrollIntoView?.({ block: 'nearest' })
    setFocusId(reveal.ids[0] ?? null)
    for (const el of els) {
      // A data attribute, not a class: React rewrites className on every snapshot.
      delete el.dataset.pulse
      void el.offsetWidth
      el.dataset.pulse = ''
      el.addEventListener('animationend', () => delete el.dataset.pulse, { once: true })
    }
  }, [reveal, order])

  /** The last item that held focus, so a removal that takes it can hand focus to a neighbour. */
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
      itemEls.current.get(neighbour)?.focus()
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
    // Keys pressed on an item's own buttons belong to those buttons.
    const target = e.target as HTMLElement
    if (target.getAttribute('role') !== 'option') return
    const current = target.dataset.id
    if (current == null) return
    const at = order.indexOf(current)

    const go = (id: string | null | undefined) => {
      if (id == null) return
      e.preventDefault()
      onSelection(e.shiftKey ? { type: 'range', id, order } : { type: 'single', id })
      focusItem(id)
    }
    const moveTo = (index: number) => go(order[Math.max(0, Math.min(order.length - 1, index))])

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
      case 'ArrowRight':
        if (board) go(laneNeighbor(lanes, current, 1))
        return
      case 'ArrowLeft':
        if (board) go(laneNeighbor(lanes, current, -1))
        return
      case 'Home':
        return moveTo(0)
      case 'End':
        return moveTo(order.length - 1)
      case ' ':
        // Plain Space is the global pause/resume shortcut (see lib/shortcuts), so it must reach
        // the document unhandled; ⌘/Ctrl+Space adds or drops this item, like ⌘/Ctrl-click.
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
  const item = {
    canWrite,
    phone,
    selecting,
    now,
    describedBy: hintId,
    itemRef,
    onClick: onItemClick,
    onAction,
    onMenu,
    onStream,
  }
  const listCls = [
    'lib-list',
    board ? 'lib-board' : 'lt',
    density === 'compact' ? 'compact' : '',
    selecting ? 'selecting' : '',
    phone ? 'phone' : '',
  ]
    .filter(Boolean)
    .join(' ')
  const dock = selecting ? selectBar : bulk

  return (
    <div className="lib">
      {(chips || tools) && (
        <div className="lib-bar">
          {chips}
          {tools}
        </div>
      )}

      {state ? (
        <div className="lib-empty" ref={emptyRef} tabIndex={-1}>
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
        <div className={board ? 'lib-wrap' : 'lib-wrap lt-wrap'}>
          {!board && !phone && <TableHead sort={sort} onSort={onSort} />}
          <div
            className={listCls}
            role="listbox"
            aria-label={t('library.queueLabel')}
            aria-multiselectable="true"
            onKeyDown={onKeyDown}
            onFocus={onListFocus}
            {...longPress}
          >
            {board ? (
              <Board lanes={lanes} density={density} selectedIds={selectedIds} tabStop={tabStop} item={item} allowed={allowed} />
            ) : (
              <TableBody tasks={tasks} groups={groups} selectedIds={selectedIds} tabStop={tabStop} item={item} allowed={allowed} />
            )}
          </div>
          {allowed && (
            <button type="button" className="btn sm soft lib-more" onClick={() => setLimit((n) => n + WINDOW_PAGE)}>
              {t('library.showMore', { count: Math.min(WINDOW_PAGE, order.length - allowed.size), remaining: order.length - allowed.size })}
            </button>
          )}
        </div>
      )}
      <span id={hintId} hidden>
        {t('library.actionsHint')}
      </span>
      {dock && <div className="lib-dock">{dock}</div>}
    </div>
  )
}
