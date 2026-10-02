import { useId, useLayoutEffect, useMemo, useRef, useState, type CSSProperties, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import type { Density } from '../../lib/libraryPrefs'
import { fmtSpeed } from '../../lib/format'
import { cardStyle, columnCount, estimatedHeight, laneColumns, type BoardLane } from '../../lib/lanes'
import type { TaskRow } from '../../lib/types'
import { BoardCard } from './BoardCard'
import { groupTitle, type ItemProps } from './itemShared'

/** The gaps the CSS draws: between columns, and between cards in a lane. */
const COLUMN_GAP = 18
const CARD_GAP = 10

type SharedItemProps = Omit<ItemProps, 'task' | 'selected' | 'focusable'>

interface BoardProps {
  lanes: readonly BoardLane[]
  density: Density
  selectedIds: ReadonlySet<string>
  tabStop: string | null
  item: SharedItemProps
}

/** The board's width, tracked so its lanes can reflow into as many columns as fit. */
function useWidth() {
  const ref = useRef<HTMLDivElement>(null)
  const [width, setWidth] = useState(0)
  useLayoutEffect(() => {
    const el = ref.current
    if (!el) return
    setWidth(el.clientWidth)
    if (typeof ResizeObserver !== 'function') return
    const observer = new ResizeObserver((entries) => {
      const w = entries[0]?.contentRect.width
      if (w != null) setWidth(Math.round(w))
    })
    observer.observe(el)
    return () => observer.disconnect()
  }, [])
  return [ref, width] as const
}

/**
 * Lanes of cards, as the app draws them: as many 236px columns as fit, consecutive lanes stacked
 * where there are fewer columns than lanes, balanced so no column runs far longer than the rest.
 */
export function Board({ lanes, density, selectedIds, tabStop, item }: BoardProps) {
  const [ref, width] = useWidth()
  const columns = useMemo(() => {
    const count = columnCount(width, lanes.length, COLUMN_GAP)
    return laneColumns(
      lanes.map((lane) => estimatedHeight(lane, CARD_GAP)),
      count,
    )
  }, [lanes, width])
  const style = { '--bd-cols': columns.length } as CSSProperties
  const card = (task: TaskRow) => (
    <BoardCard
      key={task.id}
      {...item}
      task={task}
      style={density === 'compact' ? 'compact' : cardStyle(task)}
      selected={selectedIds.has(task.id)}
      focusable={task.id === tabStop}
    />
  )

  return (
    <div ref={ref} className={`bd${columns.length === 1 ? ' one' : ''}`} style={style}>
      {columns.map((indices) => (
        <div className="bd-col" key={indices.map((i) => lanes[i]!.id).join()}>
          {indices.map((i) => (
            <Lane key={lanes[i]!.id} lane={lanes[i]!}>
              {lanes[i]!.tasks.map(card)}
            </Lane>
          ))}
        </div>
      ))}
    </div>
  )
}

/** One lane: a labelled group of options under its title, count and a line of context. */
function Lane({ lane, children }: { lane: BoardLane; children: ReactNode }) {
  const { t } = useTranslation()
  const headId = useId()
  const title = lane.group
    ? groupTitle(lane.group, t)
    : lane.kind === 'done' && lane.doneToday
      ? t('board.lane.doneToday')
      : t(`board.lane.${lane.kind ?? 'done'}`)
  let sub: string | null = null
  if (lane.kind === 'downloading') {
    const rate = lane.tasks.reduce((sum, task) => sum + (task.downSpeed || 0), 0)
    if (rate > 0) sub = `↓ ${fmtSpeed(rate)}`
  } else if (lane.kind === 'upNext') {
    sub = t('board.lane.inOrder')
  }
  return (
    <div className="lane" role="group" aria-labelledby={`${headId}t ${headId}n`} data-lane={lane.kind ?? 'group'}>
      <div className="lane-h">
        <b id={`${headId}t`}>{title}</b>
        <span className="n" id={`${headId}n`}>
          {lane.tasks.length}
        </span>
        {sub && <span className={`sub${lane.kind === 'downloading' ? ' mono' : ''}`}>{sub}</span>}
      </div>
      {children}
    </div>
  )
}
