import { useMemo, useState, type ChangeEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { fileURL, zipURL } from '../lib/api'
import {
  buildTree,
  checkState,
  ENABLE_PRIORITY,
  extension,
  extensions,
  filterTree,
  isVideo,
  selectionPlan,
  toggleFolder,
  totals,
  type CheckState,
  type FolderNode,
  type SelectionPlan,
  type TreeNode,
} from '../lib/fileTree'
import { fmtSize, pct } from '../lib/format'
import { splitTail } from '../lib/names'
import type { FilePriority, FileRow, TaskDetail } from '../lib/types'
import { CheckIcon, ChevronDownIcon, DownloadIcon, FolderIcon, SearchIcon } from './Icons'

/** Past this many files a fully open tree is a wall: start with only the top level open. */
const OPEN_ALL_LIMIT = 200
/** A filter box is noise for a handful of files. */
const FILTER_FROM = 8

interface Props {
  detail: TaskDetail
  canWrite: boolean
  /** One request per priority; resolves once the panel has the new state. */
  onSetFiles: (fileIds: readonly number[], priority: FilePriority) => Promise<void>
  onCyclePriority: (fileId: number, current: FilePriority) => void
}

interface Line {
  node: TreeNode
  depth: number
}

/** Rows to draw, depth-first; a collapsed folder hides what is under it unless a filter is on. */
function flatten(root: FolderNode, collapsed: ReadonlySet<string>, filtering: boolean): Line[] {
  const out: Line[] = []
  const walk = (node: FolderNode, depth: number) => {
    for (const child of node.children) {
      out.push({ node: child, depth })
      if (child.kind === 'folder' && (filtering || !collapsed.has(child.path))) walk(child, depth + 1)
    }
  }
  walk(root, 0)
  return out
}

function initialCollapsed(root: FolderNode): Set<string> {
  if (root.files.length <= OPEN_ALL_LIMIT) return new Set()
  const out = new Set<string>()
  const walk = (node: FolderNode) => {
    for (const c of node.children) {
      if (c.kind !== 'folder') continue
      out.add(c.path)
      walk(c)
    }
  }
  walk(root)
  return out
}

export function FilesTree({ detail, canWrite, onSetFiles, onCyclePriority }: Props) {
  const { t } = useTranslation()
  const row = detail.row
  const tree = useMemo(() => buildTree(detail.files), [detail.files])
  const [collapsed, setCollapsed] = useState(() => initialCollapsed(tree.root))
  const [query, setQuery] = useState('')
  const [busy, setBusy] = useState(false)

  const visible = useMemo(() => filterTree(tree.root, query), [tree, query])
  const filtering = query.trim() !== ''
  const lines = visible ? flatten(visible, collapsed, filtering) : []
  const all = totals(detail.files)
  const exts = useMemo(() => extensions(detail.files), [detail.files])
  const finished = detail.files.filter((f) => f.priority !== 'skip' && f.progress >= 1).length

  const apply = async (plan: SelectionPlan) => {
    if (!canWrite || busy) return
    setBusy(true)
    try {
      if (plan.enable.length) await onSetFiles(plan.enable, ENABLE_PRIORITY)
      if (plan.disable.length) await onSetFiles(plan.disable, 'skip')
    } finally {
      setBusy(false)
    }
  }

  const onPreset = (e: ChangeEvent<HTMLSelectElement>) => {
    const value = e.target.value
    e.target.value = ''
    // The filter narrows what "All" and "None" mean: they act on what is shown.
    const scope = visible?.files ?? detail.files
    const outside = (f: FileRow) => !scope.includes(f) && f.priority !== 'skip'
    if (value === 'all') void apply(selectionPlan(detail.files, (f) => scope.includes(f) || outside(f)))
    else if (value === 'none') void apply(selectionPlan(detail.files, outside))
    else if (value === 'video') void apply(selectionPlan(detail.files, (f) => isVideo(f.name)))
    else if (value.startsWith('ext:')) {
      const ext = value.slice(4)
      void apply(selectionPlan(detail.files, (f) => extension(f.name) === ext))
    }
  }

  const toggleOpen = (path: string) =>
    setCollapsed((prev) => {
      const next = new Set(prev)
      if (next.has(path)) next.delete(path)
      else next.add(path)
      return next
    })

  return (
    <>
      <div className="fhead">
        {tree.shared ? (
          <span className="fdir" title={tree.shared}>
            <FolderIcon aria-hidden="true" />
            <span className="ell">{tree.shared.replace(/\/$/, '').split('/').join(' / ')}</span>
          </span>
        ) : (
          <span className="fdir">{t('files.count', { count: all.count })}</span>
        )}
        <span className="ftot">
          {t('files.selected', { selected: fmtSize(all.selectedSize), total: fmtSize(all.size) })}
        </span>
      </div>

      <div className="ftools">
        {detail.files.length >= FILTER_FROM && (
          <label className="ffilter">
            <SearchIcon aria-hidden="true" />
            <input
              type="search"
              value={query}
              placeholder={t('files.filter')}
              aria-label={t('files.filter')}
              onChange={(e) => setQuery(e.target.value)}
            />
          </label>
        )}
        {canWrite && (
          <select
            className="fselect"
            defaultValue=""
            disabled={busy}
            aria-label={t('files.select')}
            onChange={onPreset}
          >
            <option value="" disabled>
              {t('files.select')}
            </option>
            <option value="all">{filtering ? t('files.allShown') : t('files.all')}</option>
            <option value="none">{filtering ? t('files.noneShown') : t('files.none')}</option>
            <option value="video">{t('files.onlyVideo')}</option>
            {exts.length > 1 && (
              <optgroup label={t('files.byExtension')}>
                {exts.map(({ ext, count }) => (
                  <option key={ext} value={`ext:${ext}`}>
                    {t('files.onlyExt', { ext, count })}
                  </option>
                ))}
              </optgroup>
            )}
          </select>
        )}
        {row.multiFile && finished > 0 && (
          <a className="linkbtn fzip" href={zipURL(row.id)} download title={t('detail.downloadAllHint')}>
            {t('detail.files.saveFinished', { count: finished })}
          </a>
        )}
      </div>

      <div className="ftree" role="tree" aria-label={t('detail.tabs.files')} aria-busy={busy}>
        {lines.length === 0 && <p className="fhint">{t('files.noMatch')}</p>}
        {lines.map(({ node, depth }) =>
          node.kind === 'folder' ? (
            <FolderLine
              key={`d:${node.path}`}
              node={node}
              depth={depth}
              open={filtering || !collapsed.has(node.path)}
              canWrite={canWrite && !busy}
              onOpen={() => toggleOpen(node.path)}
              onCheck={() => void apply(toggleFolder(node.files))}
            />
          ) : (
            <FileLine
              key={node.file.id}
              taskId={row.id}
              file={node.file}
              name={node.name}
              label={node.label}
              depth={depth}
              canWrite={canWrite && !busy}
              onCheck={() =>
                void onSetFiles([node.file.id], node.file.priority === 'skip' ? ENABLE_PRIORITY : 'skip')
              }
              onCyclePriority={onCyclePriority}
            />
          ),
        )}
      </div>
    </>
  )
}

function TriBox({
  state,
  label,
  disabled,
  onClick,
}: {
  state: CheckState
  label: string
  disabled: boolean
  onClick: () => void
}) {
  return (
    <button
      type="button"
      role="checkbox"
      aria-checked={state === 'mixed' ? 'mixed' : state === 'on'}
      aria-label={label}
      className={`fchk${state === 'off' ? '' : ' on'}${state === 'mixed' ? ' mixed' : ''}`}
      disabled={disabled}
      onClick={onClick}
    >
      {state === 'mixed' ? <i className="fdash" aria-hidden="true" /> : <CheckIcon />}
    </button>
  )
}

function FolderLine({
  node,
  depth,
  open,
  canWrite,
  onOpen,
  onCheck,
}: {
  node: FolderNode
  depth: number
  open: boolean
  canWrite: boolean
  onOpen: () => void
  onCheck: () => void
}) {
  const { t } = useTranslation()
  const sum = totals(node.files)
  return (
    <div className="frow fdirrow" role="treeitem" aria-expanded={open} style={{ paddingLeft: depth * 14 }}>
      <TriBox
        state={checkState(node.files)}
        label={t('files.folderToggle', { name: node.name })}
        disabled={!canWrite}
        onClick={onCheck}
      />
      <div className="finfo">
        <button type="button" className="ftoggle" onClick={onOpen} aria-label={t(open ? 'files.collapse' : 'files.expand', { name: node.name })}>
          <ChevronDownIcon className={open ? '' : 'shut'} aria-hidden="true" />
          <FolderIcon aria-hidden="true" />
          <span className="ell" title={node.path}>
            {node.name}
          </span>
        </button>
        <div className="fbar">
          <i style={{ width: `${pct(sum.size ? sum.done / sum.size : 0).toFixed(0)}%` }} />
        </div>
      </div>
      <span className="fsz">{fmtSize(sum.size)}</span>
      <span className="fcount">{t('files.count', { count: sum.count })}</span>
      <span className="fdl-gap" aria-hidden="true" />
    </div>
  )
}

function FileLine({
  taskId,
  file,
  name,
  label,
  depth,
  canWrite,
  onCheck,
  onCyclePriority,
}: {
  taskId: string
  file: FileRow
  name: string
  label: string
  depth: number
  canWrite: boolean
  onCheck: () => void
  onCyclePriority: (fileId: number, current: FilePriority) => void
}) {
  const { t } = useTranslation()
  const skipped = file.priority === 'skip'
  const { head, tail } = splitTail(label)
  return (
    <div className="frow" role="treeitem" style={{ paddingLeft: depth * 14 }}>
      <TriBox
        state={skipped ? 'off' : 'on'}
        label={t('detail.files.download', { name: file.name })}
        disabled={!canWrite}
        onClick={onCheck}
      />
      <div className="finfo">
        {/* Middle ellipsis: the head truncates, the tail (episode, extension) stays whole. */}
        <div className={`fname${skipped ? ' skipped' : ''}`} title={file.name}>
          <span className="fhead-t">{head}</span>
          {tail && <span className="ftail">{tail}</span>}
        </div>
        <div className="fbar">
          <i style={{ width: `${pct(file.progress).toFixed(0)}%` }} />
        </div>
      </div>
      <span className="fsz">{fmtSize(file.size)}</span>
      <button
        type="button"
        className={`fprio ${file.priority}`}
        disabled={!canWrite || skipped}
        aria-label={t('detail.files.priority', { name: file.name, priority: t(`task.priority.${file.priority}`) })}
        onClick={() => onCyclePriority(file.id, file.priority)}
      >
        {t(`task.priority.${file.priority}`)}
      </button>
      {!skipped && file.progress >= 1 ? (
        <a
          className="fdl"
          href={fileURL(taskId, file.id)}
          download={name}
          aria-label={t('detail.files.save', { name: file.name })}
          title={t('detail.files.saveHint')}
        >
          <DownloadIcon />
        </a>
      ) : (
        <span className="fdl-gap" aria-hidden="true" />
      )}
    </div>
  )
}
