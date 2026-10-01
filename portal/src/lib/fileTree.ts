import { commonDir, siblingStem } from './names'
import type { FilePriority, FileRow } from './types'

/**
 * A torrent's flat file list as the folders it unpacks into. The folder every file shares is said
 * once above the tree (see `commonDir`), so a single-folder season pack is not one extra level deep.
 */

export interface FileLeaf {
  kind: 'file'
  name: string
  /** `name` without the prefix its folder-mates share ("Show.S01E01.mkv" → "S01E01.mkv"). */
  label: string
  file: FileRow
}

export interface FolderNode {
  kind: 'folder'
  name: string
  /** Relative to the shared folder, with no trailing slash; '' for the root. */
  path: string
  children: TreeNode[]
  /** Every file below this folder, however deep: what its checkbox and totals speak for. */
  files: FileRow[]
}

export type TreeNode = FolderNode | FileLeaf

export type CheckState = 'on' | 'off' | 'mixed'

export interface FileTree {
  shared: string
  root: FolderNode
}

function folder(name: string, path: string): FolderNode {
  return { kind: 'folder', name, path, children: [], files: [] }
}

/** Folders first, then files, each in the order the torrent lists them (usually already sorted). */
export function buildTree(files: readonly FileRow[]): FileTree {
  const shared = commonDir(files.map((f) => f.name))
  const root = folder('', '')
  const index = new Map<string, FolderNode>([['', root]])
  for (const f of files) {
    const parts = f.name.slice(shared.length).split('/')
    const base = parts.pop() ?? f.name
    let parent = root
    parent.files.push(f)
    let path = ''
    for (const part of parts) {
      path = path ? `${path}/${part}` : part
      let next = index.get(path)
      if (!next) {
        next = folder(part, path)
        index.set(path, next)
        parent.children.push(next)
      }
      next.files.push(f)
      parent = next
    }
    parent.children.push({ kind: 'file', name: base, label: base, file: f })
  }
  sortFoldersFirst(root)
  trimStems(root)
  return { shared, root }
}

/** Season packs repeat the show's name on every file, cutting off the episode: drop what siblings share. */
function trimStems(node: FolderNode): void {
  const leaves = node.children.filter((c): c is FileLeaf => c.kind === 'file')
  const stem = siblingStem(leaves.map((l) => l.name))
  for (const leaf of leaves) leaf.label = leaf.name.slice(stem.length)
  for (const c of node.children) if (c.kind === 'folder') trimStems(c)
}

function sortFoldersFirst(node: FolderNode): void {
  const folders = node.children.filter((c): c is FolderNode => c.kind === 'folder')
  const leaves = node.children.filter((c) => c.kind === 'file')
  node.children = [...folders, ...leaves]
  folders.forEach(sortFoldersFirst)
}

export function checkState(files: readonly FileRow[]): CheckState {
  let on = 0
  for (const f of files) if (f.priority !== 'skip') on++
  if (on === 0) return 'off'
  return on === files.length ? 'on' : 'mixed'
}

export interface Totals {
  size: number
  done: number
  count: number
  /** Only the files that will be downloaded. */
  selectedSize: number
}

export function totals(files: readonly FileRow[]): Totals {
  const out: Totals = { size: 0, done: 0, count: files.length, selectedSize: 0 }
  for (const f of files) {
    out.size += f.size
    out.done += Math.min(f.done, f.size)
    if (f.priority !== 'skip') out.selectedSize += f.size
  }
  return out
}

/**
 * The tree with only the files whose path contains `query` (case-insensitive) and the folders
 * leading to them. A folder whose own name matches keeps everything below it.
 */
export function filterTree(node: FolderNode, query: string): FolderNode | null {
  const q = query.trim().toLowerCase()
  if (!q) return node
  return prune(node, q, false)
}

function prune(node: FolderNode, q: string, keepAll: boolean): FolderNode | null {
  const children: TreeNode[] = []
  for (const child of node.children) {
    if (child.kind === 'file') {
      if (keepAll || child.name.toLowerCase().includes(q)) children.push(child)
      continue
    }
    const kept = prune(child, q, keepAll || child.name.toLowerCase().includes(q))
    if (kept) children.push(kept)
  }
  if (children.length === 0 && node.path !== '') return null
  return { ...node, children, files: leaves(children) }
}

function leaves(nodes: readonly TreeNode[]): FileRow[] {
  return nodes.flatMap((n) => (n.kind === 'file' ? [n.file] : n.files))
}

export function extension(name: string): string {
  const base = name.split('/').pop() ?? name
  const dot = base.lastIndexOf('.')
  return dot > 0 ? base.slice(dot + 1).toLowerCase() : ''
}

const VIDEO = new Set(['mkv', 'mp4', 'm4v', 'avi', 'mov', 'webm', 'ts', 'm2ts', 'wmv', 'mpg', 'mpeg', 'flv'])

export function isVideo(name: string): boolean {
  return VIDEO.has(extension(name))
}

/** Extensions present, most files first — the "By extension" submenu. */
export function extensions(files: readonly FileRow[]): { ext: string; count: number }[] {
  const counts = new Map<string, number>()
  for (const f of files) {
    const ext = extension(f.name)
    if (ext) counts.set(ext, (counts.get(ext) ?? 0) + 1)
  }
  return [...counts]
    .map(([ext, count]) => ({ ext, count }))
    .sort((a, b) => b.count - a.count || a.ext.localeCompare(b.ext))
}

export interface SelectionPlan {
  /** Currently skipped, wanted: back to normal. */
  enable: number[]
  /** Currently wanted, not any more: skip. */
  disable: number[]
}

/**
 * The fewest priority changes that make exactly `want` downloaded. A file already wanted keeps
 * its low/high priority — ticking a folder must not flatten choices made inside it.
 */
export function selectionPlan(files: readonly FileRow[], want: (f: FileRow) => boolean): SelectionPlan {
  const plan: SelectionPlan = { enable: [], disable: [] }
  for (const f of files) {
    const skipped = f.priority === 'skip'
    if (want(f) && skipped) plan.enable.push(f.id)
    else if (!want(f) && !skipped) plan.disable.push(f.id)
  }
  return plan
}

/** Clicking a folder's box: all on → all off; off or mixed → all on. */
export function toggleFolder(files: readonly FileRow[]): SelectionPlan {
  const target = checkState(files) !== 'on'
  return selectionPlan(files, () => target)
}

export const ENABLE_PRIORITY: FilePriority = 'normal'
