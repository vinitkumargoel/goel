import { describe, expect, it } from 'vitest'
import {
  buildTree,
  checkState,
  extensions,
  filterTree,
  isVideo,
  selectionPlan,
  toggleFolder,
  totals,
  type FolderNode,
} from './fileTree'
import type { FilePriority, FileRow } from './types'

let nextId = 0
function file(name: string, priority: FilePriority = 'normal', size = 100, done = 0): FileRow {
  return { id: nextId++, name, size, done, progress: size ? done / size : 0, priority }
}

function names(node: FolderNode): string[] {
  return node.children.map((c) => (c.kind === 'folder' ? `${c.name}/` : c.name))
}

describe('buildTree', () => {
  it('says the shared folder once and nests the rest, folders first', () => {
    const files = [
      file('Show/readme.txt'),
      file('Show/S01/e01.mkv'),
      file('Show/S01/e02.mkv'),
      file('Show/Extras/a.mkv'),
    ]
    const { shared, root } = buildTree(files)
    expect(shared).toBe('Show/')
    expect(names(root)).toEqual(['S01/', 'Extras/', 'readme.txt'])
    const s01 = root.children[0] as FolderNode
    expect(s01.path).toBe('S01')
    expect(s01.files.map((f) => f.name)).toEqual(['Show/S01/e01.mkv', 'Show/S01/e02.mkv'])
    expect(root.files).toHaveLength(4)
  })

  it('labels files without the prefix their folder-mates share', () => {
    const { root } = buildTree([file('Show/Big.Buck.Bunny.S01E01.mkv'), file('Show/Big.Buck.Bunny.S01E02.mkv')])
    expect(root.children.map((c) => (c.kind === 'file' ? c.label : ''))).toEqual(['S01E01.mkv', 'S01E02.mkv'])
  })

  it('keeps files at the top level when nothing is shared', () => {
    const { shared, root } = buildTree([file('a.iso'), file('b/c.iso')])
    expect(shared).toBe('')
    expect(names(root)).toEqual(['b/', 'a.iso'])
  })
})

describe('check states and totals', () => {
  it('is on, off or mixed', () => {
    expect(checkState([file('a'), file('b')])).toBe('on')
    expect(checkState([file('a', 'skip'), file('b', 'skip')])).toBe('off')
    expect(checkState([file('a'), file('b', 'skip')])).toBe('mixed')
  })

  it('sums size, done and the selected size', () => {
    expect(totals([file('a', 'normal', 100, 40), file('b', 'skip', 50, 0)])).toEqual({
      size: 150,
      done: 40,
      count: 2,
      selectedSize: 100,
    })
  })
})

describe('filterTree', () => {
  const tree = buildTree([
    file('Pack/S01/e01.mkv'),
    file('Pack/S01/e01.srt'),
    file('Pack/Extras/making-of.mkv'),
    file('Pack/nfo.txt'),
  ]).root

  it('keeps matching files and the folders leading to them', () => {
    const out = filterTree(tree, 'SRT')!
    expect(names(out)).toEqual(['S01/'])
    expect(out.files.map((f) => f.name)).toEqual(['Pack/S01/e01.srt'])
  })

  it('keeps a whole folder whose name matches', () => {
    expect(filterTree(tree, 'extras')!.files.map((f) => f.name)).toEqual(['Pack/Extras/making-of.mkv'])
  })

  it('returns an empty root for no match and the tree itself for a blank query', () => {
    expect(filterTree(tree, 'zzz')!.children).toEqual([])
    expect(filterTree(tree, '  ')).toBe(tree)
  })
})

describe('selection', () => {
  it('plans the fewest changes and leaves wanted files alone', () => {
    const files = [file('a.mkv', 'high'), file('b.srt'), file('c.mkv', 'skip')]
    const plan = selectionPlan(files, (f) => isVideo(f.name))
    expect(plan.enable).toEqual([files[2]!.id])
    expect(plan.disable).toEqual([files[1]!.id])
  })

  it('toggles a folder: all on → off, mixed → on', () => {
    const on = [file('a'), file('b')]
    expect(toggleFolder(on).disable).toHaveLength(2)
    const mixed = [file('a'), file('b', 'skip')]
    expect(toggleFolder(mixed)).toEqual({ enable: [mixed[1]!.id], disable: [] })
  })

  it('lists extensions by count', () => {
    expect(extensions([file('a.mkv'), file('b.MKV'), file('c.srt'), file('noext')])).toEqual([
      { ext: 'mkv', count: 2 },
      { ext: 'srt', count: 1 },
    ])
  })
})
