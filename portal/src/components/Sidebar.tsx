import type { ComponentType, SVGProps } from 'react'
import { useTranslation } from 'react-i18next'
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

type StatusKey = 'status.active' | 'status.paused' | 'status.completed' | 'status.seeding' | 'status.failed'

/** `labelKey` rather than `label`: the module is evaluated before i18n has a language. */
const FILTERS: ReadonlyArray<{ key: Filter; labelKey: StatusKey; icon: Icon }> = [
  { key: 'active', labelKey: 'status.active', icon: ActiveIcon },
  { key: 'paused', labelKey: 'status.paused', icon: PausedIcon },
  { key: 'completed', labelKey: 'status.completed', icon: CompletedIcon },
  { key: 'seeding', labelKey: 'status.seeding', icon: SeedingIcon },
  { key: 'failed', labelKey: 'status.failed', icon: FailedIcon },
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
  const { t } = useTranslation()

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
        <div className="s-lbl">{t('sidebar.library')}</div>
        {libraryItem('all', t('sidebar.allDownloads'), ListIcon)}

        <div className="s-lbl">{t('sidebar.status')}</div>
        {FILTERS.map((f) => libraryItem(f.key, t(f.labelKey), f.icon))}

        <div className="s-lbl">{t('sidebar.tools')}</div>
        <div
          className={`s-item${view === 'history' ? ' active' : ''}`}
          onClick={() => onSelectView('history')}
        >
          <HistoryIcon />
          <span className="l">{t('common.history')}</span>
        </div>
        <div
          className={`s-item${view === 'settings' ? ' active' : ''}`}
          onClick={() => onSelectView('settings')}
        >
          <SettingsIcon />
          <span className="l">{t('common.settings')}</span>
        </div>
      </div>
    </>
  )
}
