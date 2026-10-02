import { useId, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import type { TaskGroup } from '../../lib/grouping'
import type { SortKey, SortState } from '../../lib/sort'
import type { TaskRow } from '../../lib/types'
import { groupTitle, type ItemProps } from './itemShared'
import { SortHeader } from './SortPicker'
import { TableRow } from './TableRow'

type SharedItemProps = Omit<ItemProps, 'task' | 'selected' | 'focusable'>

interface TableHeadProps {
  sort: SortState
  onSort: (key: SortKey) => void
}

/**
 * The column headers. The `lt-*` column classes must match TableRow's cells, which share the grid
 * and the container-width rules in library.css, or a label loses its column.
 */
export function TableHead({ sort, onSort }: TableHeadProps) {
  return (
    <div className="lt-head">
      <span className="lt-c lt-name">
        <SortHeader sortKey="name" sort={sort} onSort={onSort} />
      </span>
      <span className="lt-c lt-size">
        <SortHeader sortKey="size" sort={sort} onSort={onSort} />
      </span>
      {/* ETA lives in the Status column, so it is that column's second sort. */}
      <span className="lt-c lt-status lt-pair">
        <SortHeader sortKey="status" sort={sort} onSort={onSort} />
        <SortHeader sortKey="eta" sort={sort} onSort={onSort} />
      </span>
      <span className="lt-c lt-speed">
        <SortHeader sortKey="speed" sort={sort} onSort={onSort} />
      </span>
      <span className="lt-c lt-added">
        <SortHeader sortKey="added" sort={sort} onSort={onSort} />
      </span>
      <span className="lt-c lt-more" />
    </div>
  )
}

interface TableBodyProps {
  tasks: readonly TaskRow[]
  groups: readonly TaskGroup[] | null
  selectedIds: ReadonlySet<string>
  tabStop: string | null
  item: SharedItemProps
}

/** The rows, flat or in Group by sections. */
export function TableBody({ tasks, groups, selectedIds, tabStop, item }: TableBodyProps) {
  const row = (task: TaskRow) => (
    <TableRow
      key={task.id}
      {...item}
      task={task}
      selected={selectedIds.has(task.id)}
      focusable={task.id === tabStop}
    />
  )
  if (groups && groups.length > 0) {
    return (
      <>
        {groups.map((group) => (
          <GroupSection key={`${group.by}:${group.key}`} group={group}>
            {group.tasks.map(row)}
          </GroupSection>
        ))}
      </>
    )
  }
  return <>{tasks.map(row)}</>
}

/** One section: a header row, then its rows, as a labelled group of options. */
function GroupSection({ group, children }: { group: TaskGroup; children: ReactNode }) {
  const { t } = useTranslation()
  const headId = useId()
  return (
    <div className="lt-group" role="group" aria-labelledby={headId}>
      <div className="lt-grp" id={headId}>
        <span className="eyebrow">{groupTitle(group, t)}</span>
        <span className="lt-gn">{group.tasks.length}</span>
      </div>
      {children}
    </div>
  )
}
