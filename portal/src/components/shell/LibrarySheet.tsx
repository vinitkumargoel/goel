import type { ComponentProps } from 'react'
import type { Bandwidth } from '../../hooks/useBandwidth'
import type { LibraryModel } from '../../hooks/useLibraryModel'
import type { Filter as LibraryFilter } from '../../lib/filters'
import type { TaskRow } from '../../lib/types'
import { DetailPanel } from '../detail/DetailPanel'
import { QueueOverview } from '../detail/QueueOverview'

type PanelProps = Omit<ComponentProps<typeof DetailPanel>, 'open' | 'overview'>

interface LibrarySheetProps extends PanelProps {
  model: LibraryModel
  tasks: TaskRow[]
  loaded: boolean
  error: boolean
  bandwidth: Bandwidth
  autoHide: boolean
  onAutoHide: (on: boolean) => void
  onFilter: (filter: LibraryFilter) => void
}

/** The detail sheet beside (or over) the library: the selected download, or the queue overview. */
export function LibrarySheet({
  model,
  tasks,
  loaded,
  error,
  bandwidth,
  autoHide,
  onAutoHide,
  onFilter,
  ...panel
}: LibrarySheetProps) {
  return (
    <DetailPanel
      {...panel}
      open={model.panelShown}
      overview={
        // Until the first snapshot the sheet shows its loading state, not a queue of zeros.
        model.detailId == null && (loaded || error) ? (
          <QueueOverview
            tasks={tasks}
            counts={model.counts}
            down={model.totals.down}
            up={model.totals.up}
            bandwidth={bandwidth.status === 'unsupported' ? null : bandwidth.state}
            autoHide={autoHide}
            onAutoHide={onAutoHide}
            onFilter={onFilter}
          />
        ) : undefined
      }
    />
  )
}
