import { useEffect, useId, useRef, useState, type ReactNode, type RefObject } from 'react'
import { useTranslation } from 'react-i18next'
import { TYPE_FILTERS, type Filter, type FilterCounts, type TypeFilter } from '../../lib/filters'
import type { RouteView } from '../../lib/route'
import { Art } from '../ui/Art'
import { Icon, type IconName } from '../ui/Icon'

export type View = RouteView
export type { Filter, FilterCounts }

type StatusKey = 'active' | 'queued' | 'paused' | 'completed' | 'seeding' | 'failed'

const STATUSES: ReadonlyArray<{ key: StatusKey; icon: IconName }> = [
  { key: 'active', icon: 'bolt' },
  { key: 'queued', icon: 'clock' },
  { key: 'paused', icon: 'pause' },
  { key: 'completed', icon: 'check' },
  { key: 'seeding', icon: 'seed' },
  { key: 'failed', icon: 'alert' },
]

interface RailProps {
  view: View
  filter: Filter
  counts: FilterCounts
  /** Tags in the queue, most used first; the group is hidden when empty. */
  tags?: readonly { tag: string; count: number }[]
  /** A tag narrowing the list instead of a status/type filter. */
  activeTag?: string | null
  canWrite: boolean
  onSelectFilter: (filter: Filter) => void
  onSelectView: (view: View) => void
  onSelectTag?: (tag: string) => void
  onAdd: () => void
  /**
   * `rail`: the desktop column — slim icons, or labels and counts when `expanded`.
   * `drawer`: the phone's off-canvas panel, always labelled, opened from the tab bar.
   */
  variant: 'rail' | 'drawer'
  expanded?: boolean
  onToggleExpanded?: () => void
  /** Drawer only. */
  open?: boolean
  onClose?: () => void
  /** Drawer only: where focus goes when it closes with focus inside (the tab bar's Filters). */
  returnFocusTo?: RefObject<HTMLElement | null>
  /** Drawer only: what the status bar holds on wider screens (pause all, bandwidth). */
  footer?: ReactNode
}

/**
 * The Studio rail: every library filter with its count, the tags, History and Settings. On the
 * desktop it is the slim icon column (expandable to labels); on a phone the same list is a drawer.
 */
export function Rail(props: RailProps) {
  const { t } = useTranslation()
  const {
    view,
    filter,
    counts,
    tags = [],
    activeTag = null,
    canWrite,
    onSelectFilter,
    onSelectView,
    onSelectTag,
    onAdd,
    variant,
    expanded = false,
    onToggleExpanded,
    open = false,
    onClose,
    returnFocusTo,
    footer,
  } = props
  const drawer = variant === 'drawer'
  const wide = drawer || expanded
  const navRef = useRef<HTMLElement>(null)
  const wasOpen = useRef(open)
  const titleId = useId()

  // As a drawer: opening moves focus in; closing with focus inside (or lost) hands it back.
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

  const item = (
    key: string,
    label: string,
    lead: ReactNode,
    current: boolean,
    onClick: () => void,
    count?: number,
    bad = false,
  ) => {
    const showCount = count != null && (wide || count > 0)
    return (
      <button
        type="button"
        key={key}
        className={`ri${current ? ' on' : ''}`}
        aria-current={current ? 'page' : undefined}
        aria-label={!wide && count ? t('shell.rail.countLabel', { label, count }) : undefined}
        data-tip={wide ? undefined : label}
        title={wide ? undefined : label}
        onClick={onClick}
      >
        {lead}
        <span className="ri-l">{label}</span>
        {showCount && (
          <span className={`${wide ? 'n' : 'dot'}${bad && count > 0 ? ' bad' : ''}${count === 0 ? ' zero' : ''}`}>
            {!wide && count > 99 ? '99+' : count}
          </span>
        )}
      </button>
    )
  }

  const filterItem = (key: Filter, label: string, icon: ReactNode, bad = false) =>
    item(
      key,
      label,
      icon,
      view === 'library' && filter === key && activeTag == null,
      () => onSelectFilter(key),
      counts[key],
      bad,
    )

  const typeIcon = (type: TypeFilter) => <Art kind={type} size="xs" />

  const nav = (
    <nav
      ref={navRef}
      className={`rail${wide ? ' wide' : ''}${drawer ? ' drawer' : ''}${drawer && open ? ' open' : ''}`}
      aria-label={t('shell.rail.label')}
      aria-labelledby={drawer ? titleId : undefined}
      // Closed, the drawer is off-screen but still in the DOM: inert keeps Tab and screen readers out.
      inert={drawer && !open}
    >
      {drawer && (
        <div className="rail-head">
          <span className="h3" id={titleId}>
            {t('shell.drawer.title')}
          </span>
          <span className="sp" />
          <button type="button" className="ibtn" onClick={onClose} aria-label={t('common.close')}>
            <Icon name="x" />
          </button>
        </div>
      )}

      {!drawer && canWrite && (
        <button
          type="button"
          className="ri add"
          onClick={onAdd}
          aria-keyshortcuts="N"
          data-tip={wide ? undefined : t('shell.rail.add')}
          title={wide ? undefined : t('shell.rail.add')}
          aria-label={wide ? undefined : t('shell.rail.add')}
        >
          <Icon name="plus" size="l" />
          <span className="ri-l">{t('shell.rail.add')}</span>
        </button>
      )}

      {wide && <div className="eyebrow rail-lbl">{t('sidebar.library')}</div>}
      {filterItem('all', t('sidebar.allDownloads'), <Icon name="board" size="l" />)}

      {wide ? <div className="eyebrow rail-lbl">{t('sidebar.status')}</div> : <div className="rsep" role="presentation" />}
      {STATUSES.map((s) => filterItem(s.key, t(`status.${s.key}`), <Icon name={s.icon} size="l" />, s.key === 'failed'))}

      {wide && (
        <>
          <div className="eyebrow rail-lbl">{t('sidebar.type')}</div>
          {shownTypes.map((key) => filterItem(key, t(`fileType.${key}`), typeIcon(key)))}
          {(hiddenTypes > 0 || allTypes) && (
            <button type="button" className="ri more" aria-expanded={allTypes} onClick={() => setAllTypes((a) => !a)}>
              <Icon name={allTypes ? 'chevronUp' : 'chevronDown'} size="l" />
              <span className="ri-l">
                {allTypes ? t('sidebar.fewerTypes') : t('sidebar.allTypes', { count: hiddenTypes })}
              </span>
            </button>
          )}

          {tags.length > 0 && onSelectTag && (
            <>
              <div className="eyebrow rail-lbl">{t('queue.tagsGroup')}</div>
              {tags.map(({ tag, count }) =>
                item(
                  `tag:${tag}`,
                  tag,
                  <Icon name="tag" size="l" />,
                  view === 'library' && activeTag?.toLowerCase() === tag.toLowerCase(),
                  () => onSelectTag(tag),
                  count,
                ),
              )}
            </>
          )}
        </>
      )}

      <span className="gapr" />
      {wide ? <div className="eyebrow rail-lbl">{t('sidebar.tools')}</div> : <div className="rsep" role="presentation" />}
      {item('history', t('common.history'), <Icon name="history" size="l" />, view === 'history', () => onSelectView('history'))}
      {item('settings', t('common.settings'), <Icon name="settings" size="l" />, view === 'settings', () =>
        onSelectView('settings'),
      )}

      {!drawer && onToggleExpanded && (
        <button
          type="button"
          className="ri pin"
          onClick={onToggleExpanded}
          aria-pressed={expanded}
          aria-label={expanded ? t('shell.rail.collapse') : t('shell.rail.expand')}
          data-tip={wide ? undefined : t('shell.rail.expand')}
          title={expanded ? t('shell.rail.collapse') : t('shell.rail.expand')}
        >
          <Icon name="sidebar" size="l" />
          <span className="ri-l">{t('shell.rail.collapse')}</span>
        </button>
      )}

      {drawer && footer && <div className="rail-foot">{footer}</div>}
    </nav>
  )

  if (!drawer) return nav
  return (
    <>
      <div className={`drawer-scrim${open ? ' show' : ''}`} onClick={onClose} aria-hidden="true" />
      {nav}
    </>
  )
}
