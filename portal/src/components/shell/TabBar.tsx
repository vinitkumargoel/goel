import type { RefObject } from 'react'
import { useTranslation } from 'react-i18next'
import type { RouteView } from '../../lib/route'
import { Icon } from '../ui/Icon'

interface TabBarProps {
  view: RouteView
  canWrite: boolean
  drawerOpen: boolean
  onView: (view: RouteView) => void
  onAdd: () => void
  onDrawer: () => void
  drawerButtonRef: RefObject<HTMLButtonElement | null>
}

/** The phone's bottom bar, after the mockup's phone frame: Add sits in the middle, under the thumb. */
export function TabBar({ view, canWrite, drawerOpen, onView, onAdd, onDrawer, drawerButtonRef }: TabBarProps) {
  const { t } = useTranslation()
  const tab = (key: RouteView, label: string, icon: 'board' | 'history' | 'settings') => (
    <button
      type="button"
      className={`tab${view === key ? ' on' : ''}`}
      aria-current={view === key ? 'page' : undefined}
      onClick={() => onView(key)}
    >
      <Icon name={icon} size="l" />
      <span>{label}</span>
    </button>
  )
  return (
    <nav className="tabbar" aria-label={t('shell.tabs.label')}>
      {tab('library', t('shell.tabs.board'), 'board')}
      {tab('history', t('common.history'), 'history')}
      {canWrite && (
        <button type="button" className="tab-add" onClick={onAdd} aria-label={t('topbar.addDownload')}>
          <Icon name="plus" size="l" />
        </button>
      )}
      <button
        type="button"
        ref={drawerButtonRef}
        className={`tab${drawerOpen ? ' on' : ''}`}
        aria-expanded={drawerOpen}
        onClick={onDrawer}
      >
        <Icon name="filter" size="l" />
        <span>{t('shell.tabs.filters')}</span>
      </button>
      {tab('settings', t('common.settings'), 'settings')}
    </nav>
  )
}
