import { useMemo } from 'react'
import type { Filter } from '../components/shell/Rail'
import { countFilters, filterTasks } from '../lib/filters'
import { groupTasks, type GroupBy } from '../lib/grouping'
import { panelVisible } from '../lib/prefs'
import { queueEstimate } from '../lib/queue'
import { allTags, byQueuePosition, hasTag } from '../lib/queueControls'
import type { Selection } from '../lib/selection'
import { sortTasks, type SortState } from '../lib/sort'
import type { TaskRow } from '../lib/types'

interface Inputs {
  tasks: TaskRow[]
  filter: Filter
  search: string
  sort: SortState
  tag: string | null
  group: GroupBy
  selection: Selection
  panelOpen: boolean
  panelAutoHide: boolean
}

/** What the window shows, derived from the snapshot and the user's filter, sort and selection. */
export function useLibraryModel(inputs: Inputs) {
  const { tasks, filter, search, sort, tag, group, selection, panelOpen, panelAutoHide } = inputs
  const counts = useMemo(() => countFilters(tasks), [tasks])
  const tagCounts = useMemo(() => allTags(tasks), [tasks])
  // History reloads when this changes: a download finished, or a finished one left the list.
  const finishedKey = useMemo(
    () =>
      tasks
        .filter((task) => task.statusToken === 'completed' || task.statusToken === 'seeding')
        .map((task) => task.id)
        .join(),
    [tasks],
  )
  const visible = useMemo(() => {
    const shown = filterTasks(tasks, filter, search).filter((task) => tag == null || hasTag(task, tag))
    // Queued, unsorted: the order the queue will run them in, so Move to top/bottom is visible.
    if (filter === 'queued' && sort.key === null) return byQueuePosition(shown)
    return sortTasks(shown, sort)
  }, [tasks, filter, search, sort, tag])

  // Grouped, the list reads section by section: keyboard order has to follow the same order.
  const groups = useMemo(() => (group === 'none' ? null : groupTasks(visible, group)), [visible, group])
  const ordered = useMemo(() => (groups ? groups.flatMap((g) => g.tasks) : visible), [groups, visible])

  // Bulk actions apply to what the user can see: a row hidden by a filter is never acted on unseen.
  const selectedVisible = useMemo(
    () => visible.filter((task) => selection.ids.has(task.id)),
    [visible, selection.ids],
  )

  // The detail panel follows the lead row, only while it is still selected and not filtered out.
  const lead = selection.lead
  const detailId =
    lead != null && selection.ids.has(lead) && visible.some((task) => task.id === lead) ? lead : null
  const selectedLead = lead != null && selection.ids.has(lead) ? lead : null

  // Auto-hide only takes the panel away while nothing is selected; the toggle still closes it.
  const panelShown = panelVisible(panelOpen, panelAutoHide, detailId != null)

  const estimate = useMemo(() => queueEstimate(tasks), [tasks])
  const totals = useMemo(
    () =>
      tasks.reduce(
        (acc, t) => ({ down: acc.down + (t.downSpeed || 0), up: acc.up + (t.upSpeed || 0) }),
        { down: 0, up: 0 },
      ),
    [tasks],
  )

  return {
    counts,
    tagCounts,
    finishedKey,
    visible,
    groups,
    ordered,
    selectedVisible,
    detailId,
    selectedLead,
    panelShown,
    estimate,
    totals,
  }
}

export type LibraryModel = ReturnType<typeof useLibraryModel>
