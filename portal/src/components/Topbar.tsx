import { useId, useRef, type RefObject } from 'react'
import { useTranslation } from 'react-i18next'
import { BOOT } from '../lib/boot'
import { fmtSpeed, IDLE_RATE } from '../lib/format'
import { useSpeedSeries } from '../lib/speedStore'
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
import { MobileSearch } from './MobileSearch'
import { SearchChips, useSearchChips } from './SearchChips'
import { Sparkline } from './SpeedChart'

/** The total's last minute. Subscribes on its own, so a sample redraws this and not the topbar. */
function TotalSparkline({ label }: { label: string }) {
  const samples = useSpeedSeries('total')
  return samples.length > 1 ? <Sparkline samples={samples} label={label} /> : null
}

interface TopbarProps {
  search: string
  onSearch: (value: string) => void
  /** The desktop search field; "/" focuses it. */
  searchRef?: RefObject<HTMLInputElement | null>
  /** The ≤680px search bar is open over the topbar. */
  mobileSearchOpen: boolean
  onMobileSearch: (open: boolean) => void
  downSpeed: number
  upSpeed: number
  /** Library only: History and Settings have their own search, and two fields side by side confused. */
  showSearch?: boolean
  showPanelToggle: boolean
  panelOpen: boolean
  onTogglePanel: () => void
  onAdd: () => void
  onToggleSidebar: () => void
  onUserMenu: (anchor: DOMRect) => void
  userMenuOpen: boolean
  sidebarOpen: boolean
  /** The off-canvas sidebar hands focus back here when it closes. */
  hamburgerRef?: RefObject<HTMLButtonElement | null>
  canWrite: boolean
}

export function Topbar({
  search,
  onSearch,
  searchRef,
  mobileSearchOpen,
  onMobileSearch,
  downSpeed,
  upSpeed,
  showSearch = true,
  showPanelToggle,
  panelOpen,
  onTogglePanel,
  onAdd,
  onToggleSidebar,
  onUserMenu,
  userMenuOpen,
  sidebarOpen,
  hamburgerRef,
  canWrite,
}: TopbarProps) {
  const { t } = useTranslation()
  const initial = (BOOT.username[0] ?? 'A').toUpperCase()
  const searchToggle = useRef<HTMLButtonElement>(null)
  const tokens = useSearchChips(search, onSearch)
  const searchHintId = useId()

  return (
    <div className="topbar">
      <button
        className="hamburger"
        ref={hamburgerRef}
        onClick={onToggleSidebar}
        aria-label={t('topbar.menu')}
        aria-expanded={sidebarOpen}
      >
        <MenuIcon />
      </button>

      {/* "Goel°" is the product name, not copy — it stays out of the catalogue. */}
      <div className="brand">
        <span className="mk">
          <Logo />
        </span>
        Goel° <span className="sub">{t('topbar.web')}</span>
      </div>

      <div className="search" hidden={!showSearch}>
        <SearchIcon />
        <SearchChips chips={tokens.chips} onRemove={tokens.remove} />
        <input
          ref={searchRef}
          type="search"
          value={tokens.rest}
          onChange={(e) => tokens.onRest(e.target.value)}
          onKeyDown={(e) => {
            const el = e.currentTarget
            if (e.key === 'Backspace' && tokens.onBackspace(el.selectionStart === 0 && el.selectionEnd === 0)) {
              e.preventDefault()
            }
          }}
          placeholder={tokens.chips.length > 0 ? '' : t('topbar.searchDownloads')}
          aria-label={t('topbar.searchDownloads')}
          aria-describedby={searchHintId}
          aria-keyshortcuts="/"
          title={t('shortcuts.hint', { label: t('topbar.searchDownloads'), key: '/' })}
        />
        <span id={searchHintId} hidden>
          {t('workflow.search.hint')}
        </span>
      </div>

      <div className="spacer" />

      <div className="stats">
        <TotalSparkline label={t('topbar.speedTrend')} />
        <span className="stat down">
          <ArrowDownIcon />
          <b>{fmtSpeed(downSpeed, IDLE_RATE)}</b>
        </span>
        <span className="stat up">
          <ArrowUpIcon />
          <b>{fmtSpeed(upSpeed, IDLE_RATE)}</b>
        </span>
      </div>

      {/* Only shown ≤680px, where the inline field is hidden. */}
      <button
        ref={searchToggle}
        hidden={!showSearch}
        className="ico search-toggle"
        onClick={() => onMobileSearch(true)}
        aria-label={t('topbar.openSearch')}
        aria-keyshortcuts="/"
        aria-expanded={mobileSearchOpen}
      >
        <SearchIcon />
      </button>

      {/* Cosmetic only — the server, not this flag, is what refuses a read-only session's POST. */}
      {canWrite && (
        <button
          className="add-btn"
          onClick={onAdd}
          aria-keyshortcuts="N"
          title={t('shortcuts.hint', { label: t('topbar.addDownload'), key: 'N' })}
        >
          <PlusIcon />
          <span className="lbl">{t('common.add')}</span>
        </button>
      )}

      <button
        className={`ico panel-toggle${panelOpen ? ' active' : ''}`}
        style={showPanelToggle ? undefined : { display: 'none' }}
        onClick={onTogglePanel}
        title={t('topbar.detailPanel')}
        aria-label={t('topbar.detailPanel')}
        aria-pressed={panelOpen}
      >
        <PanelIcon />
      </button>

      <button
        className="user"
        onClick={(e) => onUserMenu(e.currentTarget.getBoundingClientRect())}
        aria-label={t('topbar.accountMenu', { username: BOOT.username })}
        aria-haspopup="menu"
        aria-expanded={userMenuOpen}
      >
        <span className="avatar" aria-hidden="true">{initial}</span>
        <span className="uname">{BOOT.username}</span>
        <ChevronDownIcon />
      </button>

      {mobileSearchOpen && (
        <MobileSearch
          value={search}
          onChange={onSearch}
          onClose={() => onMobileSearch(false)}
          returnFocusTo={searchToggle}
        />
      )}
    </div>
  )
}
