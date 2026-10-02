import { useMemo, useState, type ChangeEvent, type CSSProperties } from 'react'
import { useTranslation } from 'react-i18next'
import { fileURL, zipURL } from '../../lib/api'
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
} from '../../lib/fileTree'
import { fmtSize, pct } from '../../lib/format'
import { splitTail } from '../../lib/names'
import { fileType } from '../../lib/taskKind'
import type { FilePriority, FileRow, TaskDetail } from '../../lib/types'
import { Art, type ArtKind } from '../ui/Art'
import { Icon, type IconName } from '../ui/Icon'

/** Past this many files a fully open tree is a wall: start with only the top level open. */
const OPEN_ALL_LIMIT = 200
/** A filter box is noise for a handful of files. */
const FILTER_FROM = 8
/** Subtitles are drawn as a document with a captions glyph, as in the app. */
const SUBTITLES = new Set(['srt', 'ass', 'ssa', 'vtt', 'sub', 'idx'])

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

function fileArt(name: string): { kind: ArtKind; glyph?: IconName } {
  if (SUBTITLES.has(extension(name))) return { kind: 'doc', glyph: 'subs' }
  return { kind: fileType({ name, kind: 'http', statusToken: '' }) }
}

/** Indentation as a custom property, so the stylesheet owns the step (and narrows it on a phone). */
function indent(depth: number): CSSProperties {
  return { '--depth': depth } as CSSProperties
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
  const skipped = detail.files.filter((f) => f.priority === 'skip')
  const skippedBytes = skipped.reduce((sum, f) => sum + f.size, 0)

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
      {(detail.files.length >= FILTER_FROM || canWrite || (row.multiFile && finished > 0)) && (
        <div className="ft-tools">
          {detail.files.length >= FILTER_FROM && (
            <label className="field sm ft-filter">
              <Icon name="search" size="s" className="faint" />
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
            <span className="field sm select ft-select">
              <select defaultValue="" disabled={busy} aria-label={t('files.select')} onChange={onPreset}>
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
              <Icon name="chevronDown" size="s" />
            </span>
          )}
          {row.multiFile && finished > 0 && (
            <a className="btn sm ft-zip" href={zipURL(row.id)} download title={t('detail.downloadAllHint')}>
              <Icon name="download" size="s" />
              {t('detail.files.saveFinished', { count: finished })}
            </a>
          )}
        </div>
      )}

      <div className="ft-head small muted">
        <span className="ft-sum">
          {tree.shared ? (
            <span className="ft-dir ell" title={tree.shared}>
              {tree.shared.replace(/\/$/, '').split('/').join(' / ')}
            </span>
          ) : (
            <span className="ft-dir">{t('files.count', { count: all.count })}</span>
          )}
          <span className="ft-tot">
            {t('files.selected', { selected: fmtSize(all.selectedSize), total: fmtSize(all.size) })}
          </span>
        </span>
      </div>

      <div className="ft-list" role="tree" aria-label={t('detail.tabs.files')} aria-busy={busy}>
        {lines.length === 0 && <p className="small muted ft-none">{t('files.noMatch')}</p>}
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

      {skipped.length > 0 && (
        <div className="note acc">
          <Icon name="info" />
          <span>{t('sheet.files.skipNote', { count: skipped.length, size: fmtSize(skippedBytes) })}</span>
        </div>
      )}
    </>
  )
}

/** A checkbox with a third state: some of a folder's files are in, some skipped. */
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
      className="ft-check"
      disabled={disabled}
      onClick={onClick}
    >
      <span className={`check${state === 'on' ? ' on' : state === 'mixed' ? ' part' : ''}`} aria-hidden="true" />
    </button>
  )
}

function doneText(fraction: number): string {
  return `${pct(fraction).toFixed(0)}%`
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
  const state = checkState(node.files)
  const fraction = sum.size ? sum.done / sum.size : 0
  return (
    <div
      className={`ft-row ft-folder${state === 'off' ? ' skipped' : ''}`}
      role="treeitem"
      aria-expanded={open}
      style={indent(depth)}
    >
      <TriBox
        state={state}
        label={t('files.folderToggle', { name: node.name })}
        disabled={!canWrite}
        onClick={onCheck}
      />
      <button
        type="button"
        className="ft-toggle"
        onClick={onOpen}
        aria-label={t(open ? 'files.collapse' : 'files.expand', { name: node.name })}
      >
        <Icon name={open ? 'chevronDown' : 'chevronRight'} size="s" className="faint" />
        <Art kind={state === 'off' ? 'ghost' : 'dir'} size="xs" glyph="folder" />
        <span className="ft-name">
          <b className="ell" title={node.path}>
            {node.name}
          </b>
          <span className="ft-sub mono">
            {fmtSize(sum.size)} · {t('files.count', { count: sum.count })}
            {state !== 'off' && ` · ${doneText(fraction)}`}
          </span>
        </span>
      </button>
      <span className="ft-save-gap" aria-hidden="true" />
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
  const art = fileArt(name)
  const done = !skipped && file.progress >= 1
  return (
    <div className={`ft-row ft-file${skipped ? ' skipped' : ''}`} role="treeitem" style={indent(depth)}>
      <TriBox
        state={skipped ? 'off' : 'on'}
        label={t('detail.files.download', { name: file.name })}
        disabled={!canWrite}
        onClick={onCheck}
      />
      <span className="ft-ico" aria-hidden="true">
        <span className="ft-lead" />
        <Art kind={skipped ? 'ghost' : art.kind} glyph={art.glyph} size="xs" />
      </span>
      {/* Middle ellipsis: the head truncates, the tail (episode, extension) stays whole. */}
      <span className="ft-name" title={file.name}>
        <span className="ft-label">
          <span className="ft-head-t">{head}</span>
          {tail && <span className="ft-tail">{tail}</span>}
        </span>
        <span className="ft-sub mono">
          {fmtSize(file.size)}
          {!skipped && (
            <>
              {' · '}
              <span className={done ? 'goodc' : undefined}>{doneText(file.progress)}</span>
            </>
          )}
        </span>
      </span>
      {skipped ? (
        <span className="ft-prio small">{t('sheet.files.skipped')}</span>
      ) : (
        <button
          type="button"
          className={`chip sm ft-prio ft-prio-btn ${file.priority}`}
          disabled={!canWrite}
          aria-label={t('detail.files.priority', { name: file.name, priority: t(`task.priority.${file.priority}`) })}
          onClick={() => onCyclePriority(file.id, file.priority)}
        >
          {t(`task.priority.${file.priority}`)}
        </button>
      )}
      {done ? (
        <a
          className="ibtn sm ft-save"
          href={fileURL(taskId, file.id)}
          download={name}
          aria-label={t('detail.files.save', { name: file.name })}
          title={t('detail.files.saveHint')}
        >
          <Icon name="download" size="s" />
        </a>
      ) : (
        <span className="ft-save-gap" aria-hidden="true" />
      )}
    </div>
  )
}
