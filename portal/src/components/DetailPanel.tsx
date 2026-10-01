import { Fragment, useEffect, useId, useRef, type KeyboardEvent, type ReactNode, type RefObject } from 'react'
import { useTranslation } from 'react-i18next'
import { useDialogFocus } from '../hooks/useDialogFocus'
import { useMediaQuery } from '../hooks/useMediaQuery'
import { useSheetDrag } from '../hooks/useSheetDrag'
import { streamURL } from '../lib/api'
import { fmtEta } from '../lib/format'
import { breakRuns } from '../lib/names'
import { canSave, saveURL } from '../lib/saveFile'
import { fileType, kindBadge, kindLabel, rowAction } from '../lib/taskKind'
import type { QueueControls } from '../hooks/useQueueControls'
import type { FilePriority, TaskDetail, TaskRow } from '../lib/types'
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
  /** Anchored above the footer button: the menu opens upward, over the panel. */
  onRemove: (id: string, anchor: { x: number; y: number }) => void
  /** Opens the same menu a row's right-click or "⋯" opens, above the footer button. */
  onMore: (id: string, anchor: { x: number; y: number }) => void
  onCopy: (text: string) => void
  onSetFiles: (fileIds: readonly number[], priority: FilePriority) => Promise<void>
  onCyclePriority: (fileId: number, current: FilePriority) => void
  /** Speed limit, order, tags, start time and "download in order"; absent = read-only display. */
  queue?: QueueControls
  /** Opens the in-page player; absent = a new tab. */
  onStream?: (row: TaskRow) => void
  /** False while a dialog is stacked over the phone sheet: that dialog then owns Tab and Escape. */
  trapFocus?: boolean
  /** Shown with nothing selected, in place of an empty state: the queue at a glance. */
  overview?: ReactNode
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
  onSetFiles,
  onCyclePriority,
  queue,
  onStream,
  trapFocus = true,
  overview,
}: DetailPanelProps) {
  const { t } = useTranslation()
  const ref = useRef<HTMLElement>(null)
  // ≤680px the panel is a bottom sheet: modal, focus-trapped, dismissed by Esc, the scrim or a drag.
  const phone = useMediaQuery('(max-width: 680px)')
  // 681–920px the panel floats over the list; the scrim dims that list and closes the panel.
  const overlay = useMediaQuery('(min-width: 681px) and (max-width: 920px)')
  const sheet = phone && open
  const drag = useSheetDrag(onClose)
  // A closed sheet reopens at its resting detent.
  const { setExpanded } = drag
  useEffect(() => {
    if (!open) setExpanded(false)
  }, [open, setExpanded])

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
        className={`detail${open ? '' : ' hidden'}${phone ? ' sheet' : ''}${drag.dragging ? ' dragging' : ''}${phone && drag.expanded ? ' expanded' : ''}`}
        role={sheet ? 'dialog' : undefined}
        aria-modal={sheet ? true : undefined}
        aria-label={t('detail.label')}
        aria-hidden={open ? undefined : true}
        inert={!open}
        tabIndex={sheet ? -1 : undefined}
        style={
          drag.offset > 0
            ? { transform: `translateY(${drag.offset}px)` }
            : drag.offset < 0
              ? // Pulled up from the resting detent: the sheet grows with the finger.
                { height: `calc(60dvh + ${-drag.offset}px)` }
              : undefined
        }
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
            onSetFiles={onSetFiles}
            onCyclePriority={onCyclePriority}
            queue={queue}
            onStream={onStream}
          />
        ) : overview ? (
          <div className="tbody">{overview}</div>
        ) : (
          <p className="fhint" role="status" style={{ padding: '24px 20px' }}>
            {t('common.loading')}
          </p>
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
  onSetFiles,
  onCyclePriority,
  queue,
  onStream,
}: Omit<DetailPanelProps, 'open' | 'detail' | 'overview'> & { detail: TaskDetail }) {
  const { t } = useTranslation()
  const row = detail.row
  const type = fileType(row)
  const idBase = useId()
  const tabRefs = useRef(new Map<DetailTab, HTMLButtonElement>())
  const tabId = (name: DetailTab) => `${idBase}-tab-${name}`
  const panelId = `${idBase}-panel`
  const action = canWrite ? rowAction(row.statusToken) : null
  const eta = row.statusToken === 'downloading' ? fmtEta(row.etaSeconds) : null

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
            <h2 className="dname" title={row.name}>
              {breakRuns(row.name).map((run, i) => (
                <Fragment key={i}>
                  {run}
                  <wbr />
                </Fragment>
              ))}
            </h2>
            <div className="dsub">
              <span className={`kb kb-${row.kind}`} title={kindLabel(row.kind)}>
                {kindBadge(row.kind)}
              </span>
              <span className={`dpill${row.statusToken === 'failed' ? ' bad' : ''}`}>
                <span className={`sdot st-${row.statusToken}`} aria-hidden="true" />
                {/* `row.status` is server-rendered copy; the daemon owns its wording. */}
                {row.status}
                {eta && ` · ${t('library.left', { eta })}`}
              </span>
            </div>
          </div>
          <button className="dx" onClick={onClose} aria-label={t('detail.closePanel')}>
            <CloseIcon />
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
          onSetFiles={onSetFiles}
          onCyclePriority={onCyclePriority}
          queue={canWrite ? queue : undefined}
        />
      </div>

      {/* Pinned under the scrolling body, where the native panel keeps its buttons: the one thing
          to do now fills the row and is always the accent; the rest are icons (Stream and single
          file saves while running live in ⋯, with every other row action). */}
      <div className="dfoot" role="group" aria-label={t('detail.actions')}>
        {action ? (
          <button className="mbtn accent dprimary" onClick={() => onAction(row.id, action)}>
            {action === 'pause' ? <PauseIcon /> : action === 'retry' ? <RetryIcon /> : <PlayIcon />}
            {t(`common.${action}`)}
          </button>
        ) : canSave(row) ? (
          <a
            className="mbtn accent dprimary"
            href={saveURL(row)}
            download={row.multiFile ? '' : row.name}
            title={row.multiFile ? t('detail.downloadAllHint') : undefined}
          >
            <DownloadIcon />
            {row.multiFile ? t('detail.downloadAll') : t('menu.saveToDevice')}
          </a>
        ) : row.streamable ? (
          <button
            className="mbtn accent dprimary"
            onClick={() =>
              onStream ? onStream(row) : window.open(streamURL(row.id), '_blank', 'noopener,noreferrer')
            }
          >
            <StreamIcon />
            {t('common.stream')}
          </button>
        ) : (
          <span className="dprimary-gap" />
        )}

        <button
          className="mbtn icon"
          onClick={() => onCopy(row.source)}
          aria-label={t('common.copyLink')}
          title={t('common.copyLink')}
        >
          <LinkIcon />
        </button>

        {canWrite && (
          <button
            className="mbtn icon danger"
            aria-haspopup="menu"
            aria-label={t('common.remove')}
            title={t('common.remove')}
            onClick={(e) => {
              const r = e.currentTarget.getBoundingClientRect()
              onRemove(row.id, { x: r.left, y: r.top - 6 })
            }}
          >
            <TrashIcon />
          </button>
        )}

        <button
          className="mbtn icon"
          aria-haspopup="menu"
          aria-label={t('detail.moreActions')}
          title={t('detail.moreActions')}
          onClick={(e) => {
            const r = e.currentTarget.getBoundingClientRect()
            onMore(row.id, { x: r.left, y: r.top - 6 })
          }}
        >
          <MoreIcon />
        </button>
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
  onSetFiles,
  onCyclePriority,
  queue,
}: {
  tab: DetailTab
  detail: TaskDetail
  canWrite: boolean
  onCopy: (text: string) => void
  onRetry: () => void
  onSetFiles: (fileIds: readonly number[], priority: FilePriority) => Promise<void>
  onCyclePriority: (fileId: number, current: FilePriority) => void
  queue?: QueueControls
}) {
  switch (tab) {
    case 'general':
      return <GeneralPane detail={detail} onCopy={onCopy} canWrite={canWrite} onRetry={onRetry} />
    case 'details':
      return <DetailsPane detail={detail} queue={queue} />
    case 'progress':
      return <ProgressPane detail={detail} />
    case 'files':
      return (
        <FilesPane
          detail={detail}
          canWrite={canWrite}
          onSetFiles={onSetFiles}
          onCyclePriority={onCyclePriority}
        />
      )
    case 'peers':
      return <PeersPane detail={detail} />
  }
}
