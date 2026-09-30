import { useEffect, useRef, useState, type ComponentType, type RefObject, type SVGProps } from 'react'
import { useTranslation } from 'react-i18next'
import { useMediaQuery } from '../hooks/useMediaQuery'
import { TYPE_FILTERS, type Filter, type FilterCounts, type TypeFilter } from '../lib/filters'
import {
  ActiveIcon,
  ChevronDownIcon,
  ClockIcon,
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

type StatusKey =
  | 'status.active'
  | 'status.queued'
  | 'status.paused'
  | 'status.completed'
  | 'status.seeding'
  | 'status.failed'

/** `labelKey` rather than `label`: the module is evaluated before i18n has a language. */
const FILTERS: ReadonlyArray<{ key: Filter; labelKey: StatusKey; icon: Icon }> = [
  { key: 'active', labelKey: 'status.active', icon: ActiveIcon },
  { key: 'queued', labelKey: 'status.queued', icon: ClockIcon },
  { key: 'paused', labelKey: 'status.paused', icon: PausedIcon },
  { key: 'completed', labelKey: 'status.completed', icon: CompletedIcon },
  { key: 'seeding', labelKey: 'status.seeding', icon: SeedingIcon },
  { key: 'failed', labelKey: 'status.failed', icon: FailedIcon },
]

/** One component per type, so the Type group can share `libraryItem` with the status group. */
const typeIcon =
  (type: TypeFilter): Icon =>
  (p) => <FileTypeIcon {...p} type={type} ink="currentColor" />
const TYPE_ICONS = Object.fromEntries(TYPE_FILTERS.map((k) => [k, typeIcon(k)])) as Record<TypeFilter, Icon>

interface SidebarProps {
  view: View
  filter: Filter
  counts: FilterCounts
  open: boolean
  onSelectFilter: (filter: Filter) => void
  onSelectView: (view: View) => void
  onClose: () => void
  /** Where focus goes when the off-canvas sidebar closes with focus inside it (the hamburger). */
  returnFocusTo?: RefObject<HTMLElement | null>
}

/** Matches portal.css: at this width the sidebar is an off-canvas drawer. */
export const DRAWER_QUERY = '(max-width: 680px)'

export function Sidebar({
  view,
  filter,
  counts,
  open,
  onSelectFilter,
  onSelectView,
  onClose,
  returnFocusTo,
}: SidebarProps) {
  const { t } = useTranslation()
  const drawer = useMediaQuery(DRAWER_QUERY)
  const navRef = useRef<HTMLElement>(null)
  const wasOpen = useRef(open)

  // As a drawer: opening moves focus in; closing with focus inside (or lost) hands it to the hamburger.
  useEffect(() => {
    const opened = open && !wasOpen.current
    const closed = !open && wasOpen.current
    wasOpen.current = open
    if (!drawer) return
    const nav = navRef.current
    if (opened) {
      const current = nav?.querySelector<HTMLElement>('[aria-current="page"]')
      ;(current ?? nav?.querySelector<HTMLElement>('button'))?.focus()
    } else if (closed) {
      const active = document.activeElement
      if (!active || active === document.body || nav?.contains(active)) returnFocusTo?.current?.focus()
    }
  }, [open, drawer, returnFocusTo])

  // Types nobody has queued are noise: they fold away until asked for (the current one stays).
  const [allTypes, setAllTypes] = useState(false)
  const shownTypes = TYPE_FILTERS.filter((k) => allTypes || counts[k] > 0 || filter === k)
  const hiddenTypes = TYPE_FILTERS.length - shownTypes.length

  const libraryItem = (key: Filter, label: string, Icon: Icon) => {
    const current = view === 'library' && filter === key
    const n = counts[key]
    // Something failed: the count turns red so the sidebar itself says so.
    const bad = key === 'failed' && n > 0
    return (
      <button
        type="button"
        key={key}
        className={`s-item${current ? ' active' : ''}`}
        aria-current={current ? 'page' : undefined}
        title={label}
        onClick={() => onSelectFilter(key)}
      >
        <Icon aria-hidden="true" />
        <span className="l">{label}</span>
        <span className={`ct${bad ? ' bad' : ''}${n === 0 ? ' zero' : ''}`}>{n}</span>
      </button>
    )
  }

  const viewItem = (key: Exclude<View, 'library'>, label: string, Icon: Icon) => (
    <button
      type="button"
      className={`s-item${view === key ? ' active' : ''}`}
      aria-current={view === key ? 'page' : undefined}
      title={label}
      onClick={() => onSelectView(key)}
    >
      <Icon aria-hidden="true" />
      <span className="l">{label}</span>
    </button>
  )

  return (
    <>
      <div className={`sb-backdrop${open ? ' show' : ''}`} onClick={onClose} />
      {/* Closed, the drawer is off-screen but still in the DOM: inert keeps Tab and screen readers out. */}
      <nav
        ref={navRef}
        className={`sidebar${open ? ' open' : ''}`}
        aria-label={t('sidebar.navLabel')}
        inert={drawer && !open}
      >
        <div className="s-lbl">{t('sidebar.library')}</div>
        {libraryItem('all', t('sidebar.allDownloads'), ListIcon)}

        <div className="s-lbl">{t('sidebar.status')}</div>
        {FILTERS.map((f) => libraryItem(f.key, t(f.labelKey), f.icon))}

        <div className="s-lbl">{t('sidebar.type')}</div>
        {shownTypes.map((key) => libraryItem(key, t(`fileType.${key}`), TYPE_ICONS[key]))}
        {(hiddenTypes > 0 || allTypes) && (
          <button
            type="button"
            className="s-item s-more"
            aria-expanded={allTypes}
            title={allTypes ? t('sidebar.fewerTypes') : t('sidebar.allTypes', { count: hiddenTypes })}
            onClick={() => setAllTypes((a) => !a)}
          >
            <ChevronDownIcon aria-hidden="true" style={allTypes ? { transform: 'rotate(180deg)' } : undefined} />
            <span className="l">
              {allTypes ? t('sidebar.fewerTypes') : t('sidebar.allTypes', { count: hiddenTypes })}
            </span>
          </button>
        )}

        <div className="s-lbl">{t('sidebar.tools')}</div>
        {viewItem('history', t('common.history'), HistoryIcon)}
        {viewItem('settings', t('common.settings'), SettingsIcon)}
      </nav>
    </>
  )
}
