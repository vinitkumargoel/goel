import {
  Fragment,
  useEffect,
  useId,
  useRef,
  type CSSProperties,
  type KeyboardEvent,
  type ReactNode,
  type RefObject,
} from 'react'
import { useTranslation } from 'react-i18next'
import { statusLabel } from '../library/itemShared'
import { useDialogFocus } from '../../hooks/useDialogFocus'
import { useMediaQuery } from '../../hooks/useMediaQuery'
import type { QueueControls } from '../../hooks/useQueueControls'
import { useSheetDrag } from '../../hooks/useSheetDrag'
import { NARROW_QUERY, PHONE_QUERY } from '../../lib/breakpoints'
import { fmtEta, fmtSpeed, IDLE_RATE } from '../../lib/format'
import { breakRuns } from '../../lib/names'
import { canSave, saveURL } from '../../lib/saveFile'
import { fileType, kindBadge, kindLabel, rowAction } from '../../lib/taskKind'
import { isFaded, pillClass, stateTone } from '../../lib/tone'
import type { FilePriority, TaskDetail, TaskRow } from '../../lib/types'
import { Art } from '../ui/Art'
import { Icon } from '../ui/Icon'
import { Ring } from '../ui/Meter'
import { Pane, shownTab, tabLabelKey, tabsFor, type DetailTab } from './DetailPanes'
import { anchorAbove, isLive, openStream, showsUpload } from './helpers'

interface DetailPanelProps {
  detail: TaskDetail | null
  open: boolean
  tab: DetailTab
  canWrite: boolean
  onTab: (tab: DetailTab) => void
  onClose: () => void
  onAction: (id: string, action: 'pause' | 'resume' | 'retry') => void
  /** Anchored above the action-bar button: the menu opens upward, over the sheet. */
  onRemove: (id: string, anchor: { x: number; y: number }) => void
  /** Opens the same menu a card's right-click or "⋯" opens, above the button. */
  onMore: (id: string, anchor: { x: number; y: number }) => void
  onCopy: (text: string) => void
  onSetFiles: (fileIds: readonly number[], priority: FilePriority) => Promise<void>
  onCyclePriority: (fileId: number, current: FilePriority) => void
  /** Speed limit, order, tags, start time and "download in order"; absent = read-only display. */
  queue?: QueueControls
  /** Opens the in-page player; absent = a new tab. */
  onStream?: (row: TaskRow) => void
  /** False while a dialog is stacked over the floating sheet: that dialog then owns Tab and Escape. */
  trapFocus?: boolean
  /** Shown with nothing selected, in place of an empty state: the queue at a glance. */
  overview?: ReactNode
}

/**
 * The detail sheet. Wide, it floats beside the board; ≤ 920px it slides over the board from the
 * right, above a scrim, as a modal dialog; ≤ 600px it is a full-height sheet rising from the bottom
 * with a grabber that drags it taller or away.
 */
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
  const phone = useMediaQuery(PHONE_QUERY)
  const narrow = useMediaQuery(NARROW_QUERY)
  const modal = narrow && open
  const drag = useSheetDrag(onClose)
  // A closed sheet reopens at its resting detent.
  const { setExpanded } = drag
  useEffect(() => {
    if (!open) setExpanded(false)
  }, [open, setExpanded])

  const cls = [
    'dsheet',
    open ? 'open' : 'closed',
    narrow ? 'over' : '',
    phone ? 'phone' : '',
    phone && drag.dragging ? 'dragging' : '',
    phone && drag.expanded ? 'expanded' : '',
  ]
    .filter(Boolean)
    .join(' ')

  // Pulled down, the sheet follows the finger; pulled up from rest, it grows with it.
  const dragStyle: CSSProperties | undefined = !phone
    ? undefined
    : drag.offset > 0
      ? { transform: `translateY(${drag.offset}px)` }
      : drag.offset < 0
        ? ({ '--grow': `${-drag.offset}px` } as CSSProperties)
        : undefined

  return (
    <>
      {narrow && <div className={`dscrim${open ? ' open' : ''}`} onClick={onClose} aria-hidden="true" />}
      <aside
        ref={ref}
        className={cls}
        role={modal ? 'dialog' : undefined}
        aria-modal={modal ? true : undefined}
        aria-label={t('detail.label')}
        aria-hidden={open ? undefined : true}
        inert={!open}
        tabIndex={modal ? -1 : undefined}
        style={dragStyle}
      >
        {modal && <SheetFocus target={ref} onEscape={onClose} trap={trapFocus} ready={detail != null} />}
        <div className="dcard">
          {phone && (
            <div className="dgrab" title={t('detail.sheetHandle')} aria-hidden="true" {...drag.handlers}>
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
            <>
              {narrow && (
                <button type="button" className="ibtn sm dx dov-x" onClick={onClose} aria-label={t('detail.closePanel')}>
                  <Icon name="x" size="s" />
                </button>
              )}
              <div className="dscroll dov">{overview}</div>
            </>
          ) : (
            <div className="dloading" role="status">
              <Ring value={null} size={28} />
              <span className="small muted">{t('common.loading')}</span>
            </div>
          )}
        </div>
      </aside>
    </>
  )
}

/** Mounted only while the sheet is modal, so the dialog-focus hook remembers what opened it. */
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
  useDialogFocus(target, { onEscape, trap, initialFocus: false })
  useEffect(() => {
    const root = target.current
    const close = root?.querySelector<HTMLElement>('.dx')
    if (close) close.focus()
    else root?.focus()
  }, [target, ready])
  return null
}

type LoadedProps = Omit<DetailPanelProps, 'open' | 'detail' | 'overview' | 'trapFocus'> & { detail: TaskDetail }

function Loaded({
  detail,
  tab: wanted,
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
}: LoadedProps) {
  const { t } = useTranslation()
  const row = detail.row
  const idBase = useId()
  const tabRefs = useRef(new Map<DetailTab, HTMLButtonElement>())
  const tabs = tabsFor(row.kind)
  const tab = shownTab(wanted, row.kind)
  const tabId = (name: DetailTab) => `${idBase}-tab-${name}`
  const panelId = `${idBase}-panel`
  const live = isLive(row)
  const eta = row.statusToken === 'downloading' ? fmtEta(row.etaSeconds) : null

  // Tablist keyboard model: arrows move and activate, Home/End jump to the ends.
  const onTabKey = (e: KeyboardEvent<HTMLDivElement>) => {
    const at = tabs.indexOf(tab)
    const to =
      e.key === 'ArrowRight' ? at + 1
      : e.key === 'ArrowLeft' ? at - 1
      : e.key === 'Home' ? 0
      : e.key === 'End' ? tabs.length - 1
      : null
    if (to === null) return
    e.preventDefault()
    const next = tabs[(to + tabs.length) % tabs.length]!
    onTab(next)
    tabRefs.current.get(next)?.focus()
  }

  return (
    <>
      <div className="dhead">
        <Art kind={fileType(row)} size="l" faded={isFaded(row)} />
        <div className="dtt">
          <h2 className="dname" title={row.name}>
            {breakRuns(row.name).map((run, i) => (
              <Fragment key={i}>
                {run}
                <wbr />
              </Fragment>
            ))}
          </h2>
          <div className="dsub">
            <span className="badge" title={kindLabel(row.kind)}>
              {kindBadge(row.kind)}
            </span>
            <span className={pillClass(stateTone(row))}>
              {/* `row.status` is server-rendered copy; the daemon owns its wording. */}
              {statusLabel(row, t)}
              {eta && ` · ${t('library.left', { eta })}`}
            </span>
            {live && (
              <span className="mono small dlive">
                <span className="sr-only">
                  {t('sheet.rates', { down: fmtSpeed(row.downSpeed, IDLE_RATE), up: fmtSpeed(row.upSpeed, IDLE_RATE) })}
                </span>
                <span className="acc" aria-hidden="true">
                  ↓ {fmtSpeed(row.downSpeed, IDLE_RATE)}
                </span>
                {showsUpload(row) && (
                  <span className="upc" aria-hidden="true">
                    ↑ {fmtSpeed(row.upSpeed, IDLE_RATE)}
                  </span>
                )}
              </span>
            )}
          </div>
        </div>
        <button type="button" className="ibtn sm dx" onClick={onClose} aria-label={t('detail.closePanel')}>
          <Icon name="x" size="s" />
        </button>
      </div>

      <div className="dtabs">
        <div className="seg full" role="tablist" aria-label={t('detail.tabsLabel')} onKeyDown={onTabKey}>
          {tabs.map((name) => (
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
              onClick={() => onTab(name)}
            >
              {t(tabLabelKey(name))}
            </button>
          ))}
        </div>
      </div>

      <div className="dscroll" role="tabpanel" id={panelId} aria-labelledby={tabId(tab)} tabIndex={0}>
        <Pane
          tab={tab}
          detail={detail}
          canWrite={canWrite}
          onCopy={onCopy}
          onRetry={() => onAction(row.id, 'retry')}
          onMore={(at) => onMore(row.id, at)}
          onStream={onStream}
          onSetFiles={onSetFiles}
          onCyclePriority={onCyclePriority}
          queue={canWrite ? queue : undefined}
        />
      </div>

      <ActionBar row={row} canWrite={canWrite} onAction={onAction} onRemove={onRemove} onMore={onMore} onCopy={onCopy} onStream={onStream} />
    </>
  )
}

/**
 * Pinned under the scrolling body: the one thing to do now fills the bar in the accent; Copy link
 * beside it; Remove and More as icons, their menus opening upward over the sheet.
 */
function ActionBar({
  row,
  canWrite,
  onAction,
  onRemove,
  onMore,
  onCopy,
  onStream,
}: Pick<LoadedProps, 'canWrite' | 'onAction' | 'onRemove' | 'onMore' | 'onCopy' | 'onStream'> & { row: TaskRow }) {
  const { t } = useTranslation()
  const action = canWrite ? rowAction(row.statusToken) : null
  const magnet = row.source.startsWith('magnet:')
  return (
    <div className="actbar" role="group" aria-label={t('detail.actions')}>
      {action ? (
        <button type="button" className="btn pri dprimary" onClick={() => onAction(row.id, action)}>
          <Icon name={action === 'pause' ? 'pause' : action === 'retry' ? 'retry' : 'play'} />
          <span>{t(`common.${action}`)}</span>
        </button>
      ) : canSave(row) ? (
        <a
          className="btn pri dprimary"
          href={saveURL(row)}
          download={row.multiFile ? '' : row.name}
          title={row.multiFile ? t('detail.downloadAllHint') : undefined}
        >
          <Icon name="download" />
          <span>{row.multiFile ? t('detail.downloadAll') : t('menu.saveToDevice')}</span>
        </a>
      ) : row.streamable ? (
        <button type="button" className="btn pri dprimary" onClick={() => openStream(row, onStream)}>
          <Icon name="stream" />
          <span>{t('common.stream')}</span>
        </button>
      ) : null}

      <button type="button" className="btn dcopy-link" onClick={() => onCopy(row.source)} title={t('common.copyLink')}>
        <Icon name={magnet ? 'magnet' : 'link'} />
        <span>{magnet ? t('sheet.copyMagnet') : t('common.copyLink')}</span>
      </button>

      {canWrite && (
        <button
          type="button"
          className="ibtn b dremove"
          aria-haspopup="menu"
          aria-label={t('common.remove')}
          title={t('common.remove')}
          onClick={(e) => onRemove(row.id, anchorAbove(e.currentTarget))}
        >
          <Icon name="trash" />
        </button>
      )}

      <button
        type="button"
        className="ibtn b"
        aria-haspopup="menu"
        aria-label={t('detail.moreActions')}
        title={t('detail.moreActions')}
        onClick={(e) => onMore(row.id, anchorAbove(e.currentTarget))}
      >
        <Icon name="more" />
      </button>
    </div>
  )
}
