import type { ComponentType, SVGProps } from 'react'
import {
  ActiveIcon,
  CompletedIcon,
  FailedIcon,
  HistoryIcon,
  ListIcon,
  PausedIcon,
  SeedingIcon,
  SettingsIcon,
} from './Icons'

export type View = 'library' | 'history' | 'settings'
export type Filter = 'all' | 'active' | 'paused' | 'completed' | 'seeding' | 'failed'

export type FilterCounts = Record<Filter, number>

type Icon = ComponentType<SVGProps<SVGSVGElement>>

const FILTERS: ReadonlyArray<{ key: Filter; label: string; icon: Icon }> = [
  { key: 'active', label: 'Active', icon: ActiveIcon },
  { key: 'paused', label: 'Paused', icon: PausedIcon },
  { key: 'completed', label: 'Completed', icon: CompletedIcon },
  { key: 'seeding', label: 'Seeding', icon: SeedingIcon },
  { key: 'failed', label: 'Failed', icon: FailedIcon },
]

interface SidebarProps {
  view: View
  filter: Filter
  counts: FilterCounts
  open: boolean
  onSelectFilter: (filter: Filter) => void
  onSelectView: (view: View) => void
  onClose: () => void
}

export function Sidebar({
  view,
  filter,
  counts,
  open,
  onSelectFilter,
  onSelectView,
  onClose,
}: SidebarProps) {
  const libraryItem = (key: Filter, label: string, Icon: Icon) => (
    <div
      key={key}
      className={`s-item${view === 'library' && filter === key ? ' active' : ''}`}
      onClick={() => onSelectFilter(key)}
    >
      <Icon />
      <span className="l">{label}</span>
      <span className="ct">{counts[key]}</span>
    </div>
  )

  return (
    <>
      <div className={`sb-backdrop${open ? ' show' : ''}`} onClick={onClose} />
      <div className={`sidebar${open ? ' open' : ''}`}>
        <div className="s-lbl">Library</div>
        {libraryItem('all', 'All downloads', ListIcon)}

        <div className="s-lbl">Status</div>
        {FILTERS.map((f) => libraryItem(f.key, f.label, f.icon))}

        <div className="s-lbl">Tools</div>
        <div
          className={`s-item${view === 'history' ? ' active' : ''}`}
          onClick={() => onSelectView('history')}
        >
          <HistoryIcon />
          <span className="l">History</span>
        </div>
        <div
          className={`s-item${view === 'settings' ? ' active' : ''}`}
          onClick={() => onSelectView('settings')}
        >
          <SettingsIcon />
          <span className="l">Settings</span>
        </div>
      </div>
    </>
  )
}
