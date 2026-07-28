import { useTranslation } from 'react-i18next'
import { streamURL } from '../lib/api'
import { fileType, isActive, kindLabel } from '../lib/taskKind'
import type { FilePriority, TaskDetail } from '../lib/types'
import {
  DETAIL_TABS,
  DetailsPane,
  FilesPane,
  GeneralPane,
  PeersPane,
  ProgressPane,
  type DetailTab,
} from './DetailPanes'
import {
  CloseIcon,
  DownloadIcon,
  FileIcon,
  FileTypeIcon,
  LinkIcon,
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
  onCopy: (text: string) => void
  onToggleFile: (fileId: number, wasSkipped: boolean) => void
  onCyclePriority: (fileId: number, current: FilePriority) => void
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
  onCopy,
  onToggleFile,
  onCyclePriority,
}: DetailPanelProps) {
  const { t } = useTranslation()

  return (
    <div className={`detail${open ? '' : ' hidden'}`}>
      {detail ? (
        <Loaded
          detail={detail}
          tab={tab}
          canWrite={canWrite}
          onTab={onTab}
          onClose={onClose}
          onAction={onAction}
          onRemove={onRemove}
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
    </div>
  )
}

function Loaded({
  detail,
  tab,
  canWrite,
  onTab,
  onClose,
  onAction,
  onRemove,
  onCopy,
  onToggleFile,
  onCyclePriority,
}: Omit<DetailPanelProps, 'open' | 'detail'> & { detail: TaskDetail }) {
  const { t } = useTranslation()
  const row = detail.row
  const type = fileType(row)

  return (
    <div>
      <div className="dhead">
        <div className="dtop">
          <div className={`ftype ft-${type}`}>
            <FileTypeIcon type={type} />
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
              <a className="mbtn" href={streamURL(row.id)} download>
                <DownloadIcon />
                {t('common.download')}
              </a>
            </>
          )}

          <button className="mbtn" onClick={() => onCopy(row.source)}>
            <LinkIcon />
            {t('common.copyLink')}
          </button>

          {canWrite && (
            <button
              className="mbtn danger"
              onClick={(e) => onRemove(row.id, { x: e.clientX, y: e.clientY })}
            >
              <TrashIcon />
              {t('common.remove')}
            </button>
          )}
        </div>
      </div>

      <div className="tabs">
        {DETAIL_TABS.map((name) => (
          <div
            key={name}
            className={`tab${name === tab ? ' active' : ''}`}
            onClick={() => onTab(name)}
          >
            {t(`detail.tabs.${name}`)}
          </div>
        ))}
      </div>

      <div className="tbody">
        <Pane
          tab={tab}
          detail={detail}
          canWrite={canWrite}
          onCopy={onCopy}
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
  onToggleFile,
  onCyclePriority,
}: {
  tab: DetailTab
  detail: TaskDetail
  canWrite: boolean
  onCopy: (text: string) => void
  onToggleFile: (fileId: number, wasSkipped: boolean) => void
  onCyclePriority: (fileId: number, current: FilePriority) => void
}) {
  switch (tab) {
    case 'general':
      return <GeneralPane detail={detail} onCopy={onCopy} />
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
