import { useEffect, useId, useRef, type KeyboardEvent, type RefObject } from 'react'
import { useTranslation } from 'react-i18next'
import { useDialogFocus } from '../hooks/useDialogFocus'
import { useMediaQuery } from '../hooks/useMediaQuery'
import { useSheetDrag } from '../hooks/useSheetDrag'
import { streamURL, zipURL } from '../lib/api'
import { fileType, isActive, kindLabel } from '../lib/taskKind'
import type { FilePriority, TaskDetail } from '../lib/types'
import {
  DETAIL_TABS,
  DetailsPane,
  FilesPane,
  GeneralPane,
  PeersPane,
  ProgressPane,
  tabLabelKey,
  type DetailTab,
} from './DetailPanes'
import {
  CloseIcon,
  DownloadIcon,
  FileIcon,
  FileTypeIcon,
  LinkIcon,
  MoreIcon,
  PauseIcon,
  PlayIcon,
  RetryIcon,
  StreamIcon,
  TrashIcon,
} from './Icons'

interface DetailPanelProps {
  detail: TaskDetail | null
  open: boolean
  tab: DetailTab
  canWrite: boolean
  onTab: (tab: DetailTab) => void
  onClose: () => void
  onAction: (id: string, action: 'pause' | 'resume' | 'retry') => void
  onRemove: (id: string, anchor: { x: number; y: number }) => void
  /** Opens the same menu a row's right-click or "⋯" opens, anchored under the button. */
  onMore: (id: string, anchor: { x: number; y: number }) => void
  onCopy: (text: string) => void
  onToggleFile: (fileId: number, wasSkipped: boolean) => void
  onCyclePriority: (fileId: number, current: FilePriority) => void
  /** False while a dialog is stacked over the phone sheet: that dialog then owns Tab and Escape. */
  trapFocus?: boolean
}

export function DetailPanel({
  detail,
  open,
  tab,
  canWrite,
  onTab,
  onClose,
  onAction,
  onRemove,
  onMore,
  onCopy,
  onToggleFile,
  onCyclePriority,
  trapFocus = true,
}: DetailPanelProps) {
  const { t } = useTranslation()
  const ref = useRef<HTMLElement>(null)
  // ≤680px the panel is a bottom sheet: modal, focus-trapped, dismissed by Esc, the scrim or a drag.
  const phone = useMediaQuery('(max-width: 680px)')
  // 681–920px the panel floats over the list; the scrim dims that list and closes the panel.
  const overlay = useMediaQuery('(min-width: 681px) and (max-width: 920px)')
  const sheet = phone && open
  const drag = useSheetDrag(onClose)

  return (
    <>
      {phone && (
        <div className={`sheet-scrim${open ? ' open' : ''}`} onClick={onClose} aria-hidden="true" />
      )}
      {overlay && (
        <div className={`panel-scrim${open ? ' open' : ''}`} onClick={onClose} aria-hidden="true" />
      )}
      <aside
        ref={ref}
        className={`detail${open ? '' : ' hidden'}${phone ? ' sheet' : ''}${drag.dragging ? ' dragging' : ''}`}
        role={sheet ? 'dialog' : undefined}
        aria-modal={sheet ? true : undefined}
        aria-label={t('detail.label')}
        aria-hidden={open ? undefined : true}
        inert={!open}
        tabIndex={sheet ? -1 : undefined}
        style={drag.offset > 0 ? { transform: `translateY(${drag.offset}px)` } : undefined}
      >
        {sheet && <SheetFocus target={ref} onEscape={onClose} trap={trapFocus} ready={detail != null} />}
        {phone && (
          <div className="grabber" title={t('detail.sheetHandle')} aria-hidden="true" {...drag.handlers}>
            <span />
          </div>
        )}
        {detail ? (
          <Loaded
            detail={detail}
            tab={tab}
            canWrite={canWrite}
            onTab={onTab}
            onClose={onClose}
            onAction={onAction}
            onRemove={onRemove}
            onMore={onMore}
            onCopy={onCopy}
            onToggleFile={onToggleFile}
            onCyclePriority={onCyclePriority}
          />
        ) : (
          <div className="empty" style={{ padding: '40px 26px' }}>
            <FileIcon />
            <h4>{t('detail.emptyTitle')}</h4>
            <p>{t('detail.emptyBody')}</p>
          </div>
        )}
      </aside>
    </>
  )
}

/** Mounted only while the sheet is up, so the dialog-focus hook remembers the row that opened it. */
function SheetFocus({
  target,
  onEscape,
  trap,
  ready,
}: {
  target: RefObject<HTMLElement | null>
  onEscape: () => void
  trap: boolean
  /** The download has loaded, so its Close button exists; until then the sheet itself takes focus. */
  ready: boolean
}) {
  useDialogFocus(target, { onEscape, trap })
  useEffect(() => {
    const root = target.current
    const close = root?.querySelector<HTMLElement>('.dx')
    if (close) close.focus()
    else root?.focus()
  }, [target, ready])
  return null
}

function Loaded({
  detail,
  tab,
  canWrite,
  onTab,
  onClose,
  onAction,
  onRemove,
  onMore,
  onCopy,
  onToggleFile,
  onCyclePriority,
}: Omit<DetailPanelProps, 'open' | 'detail'> & { detail: TaskDetail }) {
  const { t } = useTranslation()
  const row = detail.row
  const type = fileType(row)
  const idBase = useId()
  const tabRefs = useRef(new Map<DetailTab, HTMLButtonElement>())
  const tabId = (name: DetailTab) => `${idBase}-tab-${name}`
  const panelId = `${idBase}-panel`
  const zippable =
    row.multiFile && detail.files.some((f) => f.priority !== 'skip' && f.progress >= 1)

  // Tablist keyboard model: arrows move and activate, Home/End jump to the ends.
  const onTabKey = (e: KeyboardEvent<HTMLDivElement>) => {
    const at = DETAIL_TABS.indexOf(tab)
    const to =
      e.key === 'ArrowRight' ? at + 1
      : e.key === 'ArrowLeft' ? at - 1
      : e.key === 'Home' ? 0
      : e.key === 'End' ? DETAIL_TABS.length - 1
      : null
    if (to === null) return
    e.preventDefault()
    const next = DETAIL_TABS[(to + DETAIL_TABS.length) % DETAIL_TABS.length]!
    onTab(next)
    tabRefs.current.get(next)?.focus()
  }

  return (
    // A flex column, so `.tbody` is bounded and scrolls instead of running under the status bar.
    <div className="dload">
      <div className="dhead">
        <div className="dtop">
          <div className={`ftype ft-${type}`}>
            <FileTypeIcon type={type} ink="currentColor" />
          </div>
          <div style={{ minWidth: 0 }}>
            <div className="dname">{row.name}</div>
            {/* `row.status` is server-rendered copy; the daemon owns its wording. */}
            <div className="dsub">
              {row.status} · {kindLabel(row.kind)}
            </div>
          </div>
          <button className="dx" onClick={onClose} aria-label={t('detail.closePanel')}>
            <CloseIcon />
          </button>
        </div>

        <div className="dact">
          {canWrite && isActive(row.statusToken) && (
            <button className="mbtn" onClick={() => onAction(row.id, 'pause')}>
              <PauseIcon />
              {t('common.pause')}
            </button>
          )}
          {canWrite && row.statusToken === 'paused' && (
            <button className="mbtn accent" onClick={() => onAction(row.id, 'resume')}>
              <PlayIcon />
              {t('common.resume')}
            </button>
          )}
          {canWrite && row.statusToken === 'failed' && (
            <button className="mbtn accent" onClick={() => onAction(row.id, 'retry')}>
              <RetryIcon />
              {t('common.retry')}
            </button>
          )}

          {row.streamable && (
            <>
              <button
                className="mbtn"
                onClick={() => window.open(streamURL(row.id), '_blank', 'noopener,noreferrer')}
              >
                <StreamIcon />
                {t('common.stream')}
              </button>
              {!row.multiFile && (
                <a className="mbtn" href={streamURL(row.id, true)} download={row.name}>
                  <DownloadIcon />
                  {t('common.download')}
                </a>
              )}
            </>
          )}

          {zippable && (
            <a className="mbtn" href={zipURL(row.id)} download title={t('detail.downloadAllHint')}>
              <DownloadIcon />
              {t('detail.downloadAll')}
            </a>
          )}

          <button className="mbtn" onClick={() => onCopy(row.source)}>
            <LinkIcon />
            {t('common.copyLink')}
          </button>

          {canWrite && (
            <button
              className="mbtn danger"
              aria-haspopup="menu"
              onClick={(e) => {
                const r = e.currentTarget.getBoundingClientRect()
                onRemove(row.id, { x: r.left, y: r.bottom })
              }}
            >
              <TrashIcon />
              {t('common.remove')}
            </button>
          )}

          <button
            className="mbtn"
            aria-haspopup="menu"
            aria-label={t('detail.moreActions')}
            onClick={(e) => {
              const r = e.currentTarget.getBoundingClientRect()
              onMore(row.id, { x: r.left, y: r.bottom + 4 })
            }}
          >
            <MoreIcon />
          </button>
        </div>
      </div>

      <div className="tabs">
        <div
          className="seg dtabs"
          role="tablist"
          aria-label={t('detail.tabsLabel')}
          onKeyDown={onTabKey}
        >
          {DETAIL_TABS.map((name) => (
            <button
              key={name}
              type="button"
              role="tab"
              id={tabId(name)}
              ref={(el) => {
                if (el) tabRefs.current.set(name, el)
                else tabRefs.current.delete(name)
              }}
              aria-selected={name === tab}
              aria-controls={panelId}
              tabIndex={name === tab ? 0 : -1}
              className={name === tab ? 'on' : undefined}
              onClick={() => onTab(name)}
            >
              {t(tabLabelKey(name, row.kind))}
            </button>
          ))}
        </div>
      </div>

      <div className="tbody" role="tabpanel" id={panelId} aria-labelledby={tabId(tab)} tabIndex={0}>
        <Pane
          tab={tab}
          detail={detail}
          canWrite={canWrite}
          onCopy={onCopy}
          onRetry={() => onAction(row.id, 'retry')}
          onToggleFile={onToggleFile}
          onCyclePriority={onCyclePriority}
        />
      </div>
    </div>
  )
}

function Pane({
  tab,
  detail,
  canWrite,
  onCopy,
  onRetry,
  onToggleFile,
  onCyclePriority,
}: {
  tab: DetailTab
  detail: TaskDetail
  canWrite: boolean
  onCopy: (text: string) => void
  onRetry: () => void
  onToggleFile: (fileId: number, wasSkipped: boolean) => void
  onCyclePriority: (fileId: number, current: FilePriority) => void
}) {
  switch (tab) {
    case 'general':
      return <GeneralPane detail={detail} onCopy={onCopy} canWrite={canWrite} onRetry={onRetry} />
    case 'details':
      return <DetailsPane detail={detail} />
    case 'progress':
      return <ProgressPane detail={detail} />
    case 'files':
      return (
        <FilesPane
          detail={detail}
          canWrite={canWrite}
          onToggleFile={onToggleFile}
          onCyclePriority={onCyclePriority}
        />
      )
    case 'peers':
      return <PeersPane detail={detail} />
  }
}
