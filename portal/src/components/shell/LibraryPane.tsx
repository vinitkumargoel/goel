import type { RefObject } from 'react'
import type { AppState } from '../../hooks/useAppState'
import type { LibraryModel } from '../../hooks/useLibraryModel'
import type { useLibraryWorkflow } from '../../hooks/useLibraryWorkflow'
import type { Filter as LibraryFilter } from '../../lib/filters'
import type { SortKey } from '../../lib/sort'
import type { RowAction } from '../../lib/taskKind'
import type { TaskRow } from '../../lib/types'
import { BulkBar } from '../library/BulkBar'
import { FilterChips } from '../library/FilterChips'
import { LibraryTools } from '../library/LibraryTools'
import { LibraryView } from '../library/LibraryView'
import type { MenuState } from '../ui/Menu'
import { Omnibox } from './Omnibox'

interface LibraryPaneProps {
  state: AppState
  model: LibraryModel
  wf: ReturnType<typeof useLibraryWorkflow>
  /** Every task before search and filter. */
  tasks: TaskRow[]
  loaded: boolean
  error: boolean
  canWrite: boolean
  readOnly: boolean
  searchRef: RefObject<HTMLInputElement | null>
  openAdd: () => void
  openAddWith: (text: string, pasted: boolean) => void
  quickAdd: (text: string) => unknown
  goToFilter: (filter: LibraryFilter) => void
  goToTag: (tag: string) => void
  openMenu: (menu: MenuState) => void
  openDetail: (id: string) => void
  onSort: (key: SortKey) => void
  onRowAction: (id: string, action: RowAction) => void
  openRowMenu: (id: string, x: number, y: number) => void
  clearSearch: () => void
  refresh: () => void
  openPlayer: (task: TaskRow) => void
  runBulk: (action: RowAction, ids: string[]) => Promise<void>
  removeMany: (ids: string[]) => void
  copy: (text: string) => void
}

/** The library view: the omnibox, then the board or table with its chips, tools and bulk bars. */
export function LibraryPane(props: LibraryPaneProps) {
  const { state, model, wf, canWrite } = props
  const { selection, select, search, filter, tag, sort } = state
  const { selectedVisible } = model
  const bulkBar = (extra: { className?: string; onDone?: () => void }) => (
    <BulkBar
      {...extra}
      selected={selectedVisible}
      canWrite={canWrite}
      onAction={(action, ids) => void props.runBulk(action, ids)}
      onCopyLinks={(sources) => props.copy(sources.join('\n'))}
      onRemove={props.removeMany}
      onClear={() => select({ type: 'clear' })}
    />
  )
  return (
    <>
      <Omnibox
        value={search}
        onChange={state.setSearch}
        inputRef={props.searchRef}
        canWrite={canWrite}
        onAdd={props.openAdd}
        onAddLinks={(text, pasted) => props.openAddWith(text, pasted)}
        onQuickAdd={(text) => void props.quickAdd(text)}
        onPalette={wf.openPalette}
      />
      <LibraryView
        tasks={model.ordered}
        groups={model.groups}
        group={wf.group}
        density={wf.density}
        layout={wf.layout}
        selecting={wf.selecting}
        onSelecting={wf.setSelecting}
        reveal={wf.reveal}
        chips={
          <FilterChips
            filter={filter}
            counts={model.counts}
            onFilter={props.goToFilter}
            tags={model.tagCounts}
            activeTag={tag}
            onTag={props.goToTag}
            openMenu={props.openMenu}
          />
        }
        tools={
          <LibraryTools
            count={model.ordered.length}
            group={wf.group}
            onGroup={wf.setGroup}
            density={wf.density}
            onDensity={wf.setDensity}
            layout={wf.layout}
            onLayout={wf.setLayout}
            sort={sort}
            onSort={props.onSort}
          />
        }
        selectBar={bulkBar({
          className: 'pbulk',
          onDone: () => {
            wf.setSelecting(false)
            select({ type: 'clear' })
          },
        })}
        total={props.tasks.length}
        loaded={props.loaded}
        error={props.error}
        search={search}
        filtered={filter !== 'all' || tag != null}
        selectedIds={selection.ids}
        lead={selection.lead}
        sort={sort}
        canWrite={canWrite}
        readOnly={props.readOnly}
        onSelection={select}
        onOpen={props.openDetail}
        onSort={props.onSort}
        onAction={props.onRowAction}
        onMenu={props.openRowMenu}
        onClearSearch={props.clearSearch}
        onAdd={props.openAdd}
        onRetry={props.refresh}
        onStream={props.openPlayer}
        bulk={selectedVisible.length >= 2 ? bulkBar({}) : undefined}
      />
    </>
  )
}
