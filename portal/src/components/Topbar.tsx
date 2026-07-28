import { useTranslation } from 'react-i18next'
import { BOOT } from '../lib/boot'
import { fmtRate } from '../lib/format'
import {
  ArrowDownIcon,
  ArrowUpIcon,
  ChevronDownIcon,
  Logo,
  MenuIcon,
  PanelIcon,
  PlusIcon,
  SearchIcon,
} from './Icons'

interface TopbarProps {
  search: string
  onSearch: (value: string) => void
  downSpeed: number
  upSpeed: number
  showPanelToggle: boolean
  panelOpen: boolean
  onTogglePanel: () => void
  onAdd: () => void
  onToggleSidebar: () => void
  onUserMenu: (anchor: DOMRect) => void
  canWrite: boolean
}

export function Topbar({
  search,
  onSearch,
  downSpeed,
  upSpeed,
  showPanelToggle,
  panelOpen,
  onTogglePanel,
  onAdd,
  onToggleSidebar,
  onUserMenu,
  canWrite,
}: TopbarProps) {
  const { t } = useTranslation()
  const initial = (BOOT.username[0] ?? 'A').toUpperCase()

  return (
    <div className="topbar">
      <button className="hamburger" onClick={onToggleSidebar} aria-label={t('topbar.menu')}>
        <MenuIcon />
      </button>

      {/* "Goel°" is the product name, not copy — it stays out of the catalogue. */}
      <div className="brand">
        <span className="mk">
          <Logo />
        </span>
        Goel° <span className="sub">{t('topbar.web')}</span>
      </div>

      <div className="search">
        <SearchIcon />
        <input
          value={search}
          onChange={(e) => onSearch(e.target.value)}
          placeholder={t('topbar.searchDownloads')}
          aria-label={t('topbar.searchDownloads')}
        />
      </div>

      <div className="spacer" />

      <div className="stats">
        <span className="stat down">
          <ArrowDownIcon />
          <b>{fmtRate(downSpeed)}</b>
        </span>
        <span className="stat up">
          <ArrowUpIcon />
          <b>{fmtRate(upSpeed)}</b>
        </span>
      </div>

      {/* Cosmetic only — the server, not this flag, is what refuses a read-only session's POST. */}
      {canWrite && (
        <button className="add-btn" onClick={onAdd}>
          <PlusIcon />
          <span className="lbl">{t('common.add')}</span>
        </button>
      )}

      <button
        className={`ico${panelOpen ? ' active' : ''}`}
        style={showPanelToggle ? undefined : { display: 'none' }}
        onClick={onTogglePanel}
        title={t('topbar.detailPanel')}
        aria-pressed={panelOpen}
      >
        <PanelIcon />
      </button>

      <button
        className="user"
        onClick={(e) => onUserMenu(e.currentTarget.getBoundingClientRect())}
      >
        <span className="avatar">{initial}</span>
        <span className="uname">{BOOT.username}</span>
        <ChevronDownIcon />
      </button>
    </div>
  )
}
