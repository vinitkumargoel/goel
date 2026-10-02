import { useTranslation } from 'react-i18next'
import type { QueueControls } from '../../hooks/useQueueControls'
import { streamURL } from '../../lib/api'
import { fmtSize, pct } from '../../lib/format'
import { canSave } from '../../lib/saveFile'
import { fileType } from '../../lib/taskKind'
import type { FilePriority, TaskDetail, TaskKind, TaskRow } from '../../lib/types'
import { Art } from '../ui/Art'
import { Icon } from '../ui/Icon'
import { FilesTree } from './FilesTree'
import { NetworkPane, PeersPane } from './NetworkPane'
import { OverviewPane } from './OverviewPane'

export type DetailTab = 'overview' | 'files' | 'peers' | 'network'

export const DETAIL_TABS: readonly DetailTab[] = ['overview', 'files', 'peers', 'network']

/** Peers is a torrent's alone; an HTTP download's connections live under Network. */
export function tabsFor(kind: TaskKind): readonly DetailTab[] {
  return kind === 'torrent' ? DETAIL_TABS : DETAIL_TABS.filter((tab) => tab !== 'peers')
}

/** A tab this download lacks (Peers, kept from a torrent picked before) shows Overview. */
export function shownTab(tab: DetailTab, kind: TaskKind): DetailTab {
  return tabsFor(kind).includes(tab) ? tab : 'overview'
}

export function tabLabelKey(
  tab: DetailTab,
): 'sheet.tabs.overview' | 'detail.tabs.files' | 'detail.tabs.peers' | 'sheet.tabs.network' {
  switch (tab) {
    case 'overview':
      return 'sheet.tabs.overview'
    case 'files':
      return 'detail.tabs.files'
    case 'peers':
      return 'detail.tabs.peers'
    case 'network':
      return 'sheet.tabs.network'
  }
}

export interface PaneProps {
  detail: TaskDetail
  canWrite: boolean
  onCopy: (text: string) => void
  onRetry: () => void
  /** The row menu, anchored above the button that asked for it. */
  onMore: (anchor: { x: number; y: number }) => void
  onStream?: (row: TaskRow) => void
  onSetFiles: (fileIds: readonly number[], priority: FilePriority) => Promise<void>
  onCyclePriority: (fileId: number, current: FilePriority) => void
  /** Present only for a session that may change things. */
  queue?: QueueControls
}

export function Pane({ tab, ...props }: PaneProps & { tab: DetailTab }) {
  switch (tab) {
    case 'overview':
      return <OverviewPane {...props} />
    case 'files':
      return <FilesPane {...props} />
    case 'peers':
      return <PeersPane detail={props.detail} />
    case 'network':
      return <NetworkPane detail={props.detail} queue={props.queue} onCopy={props.onCopy} />
  }
}

/** The tree for a multi-file download; otherwise why there is no tree. */
export function FilesPane({ detail, canWrite, onSetFiles, onCyclePriority }: PaneProps) {
  const { t } = useTranslation()
  const row = detail.row

  if (detail.files.length > 0) {
    return (
      <FilesTree detail={detail} canWrite={canWrite} onSetFiles={onSetFiles} onCyclePriority={onCyclePriority} />
    )
  }

  if (row.statusToken === 'metadata') {
    return (
      <div className="dnote-row">
        <Art kind="magnet" size="s" />
        <p className="small muted">{t('sheet.files.beforeMetadata')}</p>
      </div>
    )
  }

  const done = canSave(row)
  return (
    <>
      <div className="ft-list">
        <div className="ft-row ft-single">
          <span className="ft-check" aria-hidden="true">
            <span className="check on" />
          </span>
          <Art kind={fileType(row)} size="xs" />
          <span className="ft-name" title={row.name}>
            <span className="ell">{row.name}</span>
            <span className="ft-sub mono">
              {fmtSize(row.totalBytes)} · {pct(row.progress).toFixed(0)}%
            </span>
          </span>
          {done ? (
            <a
              className="ibtn sm ft-save"
              href={streamURL(row.id, true)}
              download={row.name}
              aria-label={t('detail.files.save', { name: row.name })}
              title={t('detail.files.saveHint')}
            >
              <Icon name="download" size="s" />
            </a>
          ) : (
            <span className="ft-save-gap" aria-hidden="true" />
          )}
        </div>
      </div>
      <p className="small muted">{t('detail.files.singleFile')}</p>
    </>
  )
}
