import type { ComponentType, SVGProps } from 'react'
import { useTranslation } from 'react-i18next'
import { TYPE_FILTERS, type Filter, type FilterCounts, type TypeFilter } from '../lib/filters'
import {
  ActiveIcon,
  CompletedIcon,
  FailedIcon,
  FileTypeIcon,
  HistoryIcon,
  ListIcon,
  PausedIcon,
  SeedingIcon,
  SettingsIcon,
} from './Icons'

export type View = 'library' | 'history' | 'settings'
export type { Filter, FilterCounts }

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

/** One component per type, so the Type group can share `libraryItem` with the status group. */
const TYPE_ICONS: Record<TypeFilter, Icon> = {
  video: (p) => <FileTypeIcon {...p} type="video" ink="currentColor" />,
  iso: (p) => <FileTypeIcon {...p} type="iso" ink="currentColor" />,
  archive: (p) => <FileTypeIcon {...p} type="archive" ink="currentColor" />,
  app: (p) => <FileTypeIcon {...p} type="app" ink="currentColor" />,
}

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

  const libraryItem = (key: Filter, label: string, Icon: Icon) => {
    const current = view === 'library' && filter === key
    return (
      <button
        type="button"
        key={key}
        className={`s-item${current ? ' active' : ''}`}
        aria-current={current ? 'page' : undefined}
        onClick={() => onSelectFilter(key)}
      >
        <Icon aria-hidden="true" />
        <span className="l">{label}</span>
        <span className="ct">{counts[key]}</span>
      </button>
    )
  }

  const viewItem = (key: Exclude<View, 'library'>, label: string, Icon: Icon) => (
    <button
      type="button"
      className={`s-item${view === key ? ' active' : ''}`}
      aria-current={view === key ? 'page' : undefined}
      onClick={() => onSelectView(key)}
    >
      <Icon aria-hidden="true" />
      <span className="l">{label}</span>
    </button>
  )

  return (
    <>
      <div className={`sb-backdrop${open ? ' show' : ''}`} onClick={onClose} />
      <nav className={`sidebar${open ? ' open' : ''}`} aria-label={t('sidebar.navLabel')}>
        <div className="s-lbl">{t('sidebar.library')}</div>
        {libraryItem('all', t('sidebar.allDownloads'), ListIcon)}

        <div className="s-lbl">{t('sidebar.status')}</div>
        {FILTERS.map((f) => libraryItem(f.key, t(f.labelKey), f.icon))}

        <div className="s-lbl">{t('sidebar.type')}</div>
        {TYPE_FILTERS.map((key) => libraryItem(key, t(`fileType.${key}`), TYPE_ICONS[key]))}

        <div className="s-lbl">{t('sidebar.tools')}</div>
        {viewItem('history', t('common.history'), HistoryIcon)}
        {viewItem('settings', t('common.settings'), SettingsIcon)}
      </nav>
    </>
  )
}
