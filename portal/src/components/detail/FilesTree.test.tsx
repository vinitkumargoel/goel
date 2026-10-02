import { fireEvent, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import en from '../../locales/en.json'
import sheet from '../../locales/en.json'
import type { FileRow, TaskDetail } from '../../lib/types'
import { makeTask } from '../../test/makeTask'
import { renderWithI18n } from '../../test/renderWithI18n'
import { FilesTree } from './FilesTree'

function file(id: number, name: string, priority: FileRow['priority'] = 'normal', progress = 0): FileRow {
  return { id, name, size: 1000, done: progress * 1000, progress, priority }
}

function detail(files: FileRow[]): TaskDetail {
  return {
    row: makeTask('t1', { name: 'Pack', kind: 'torrent', multiFile: true, statusToken: 'downloading' }),
    savePath: '/d',
    sequential: false,
    infoHash: null,
    files,
    trackers: [],
    connections: [],
    pieces: [],
    server: null,
    mimeType: null,
  }
}

const FILES = [
  file(0, 'Pack/S01/e01.mkv'),
  file(1, 'Pack/S01/e01.srt', 'skip'),
  file(2, 'Pack/S02/e01.mkv', 'skip'),
  file(3, 'Pack/nfo.txt', 'high', 1),
]

function renderTree(files: FileRow[], over: Partial<Parameters<typeof FilesTree>[0]> = {}) {
  const props = {
    detail: detail(files),
    canWrite: true,
    onSetFiles: vi.fn(() => Promise.resolve()),
    onCyclePriority: vi.fn(),
    ...over,
  }
  renderWithI18n(<FilesTree {...props} />)
  return props
}

describe('FilesTree', () => {
  it('shows folders with tri-state boxes and ticks a mixed folder fully in one request', async () => {
    const { onSetFiles } = renderTree(FILES)
    const s01 = screen.getByRole('checkbox', { name: /everything in S01/ })
    expect(s01).toHaveAttribute('aria-checked', 'mixed')
    expect(s01.querySelector('.check')).toHaveClass('part')
    expect(screen.getByRole('checkbox', { name: /everything in S02/ })).toHaveAttribute('aria-checked', 'false')
    await userEvent.click(s01)
    expect(onSetFiles).toHaveBeenCalledWith([1], 'normal')
  })

  it('unticks a fully included folder by skipping all of it', async () => {
    const { onSetFiles } = renderTree([file(0, 'Pack/A/a.mkv'), file(1, 'Pack/A/b.mkv'), file(2, 'Pack/c.txt')])
    await userEvent.click(screen.getByRole('checkbox', { name: /everything in A/ }))
    expect(onSetFiles).toHaveBeenCalledWith([0, 1], 'skip')
  })

  it('toggles a single file between skipped and included', async () => {
    const { onSetFiles } = renderTree(FILES)
    await userEvent.click(screen.getByRole('checkbox', { name: 'Download Pack/S01/e01.srt' }))
    expect(onSetFiles).toHaveBeenLastCalledWith([1], 'normal')
    await userEvent.click(screen.getByRole('checkbox', { name: 'Download Pack/S01/e01.mkv' }))
    expect(onSetFiles).toHaveBeenLastCalledWith([0], 'skip')
  })

  it('collapses and reopens a folder', async () => {
    renderTree(FILES)
    expect(screen.getByTitle('Pack/S01/e01.srt')).toBeInTheDocument()
    const s01 = screen.getByRole('button', { name: 'Close S01' })
    expect(s01.closest('[role="treeitem"]')).toHaveAttribute('aria-expanded', 'true')
    await userEvent.click(s01)
    expect(screen.queryByTitle('Pack/S01/e01.srt')).toBeNull()
    await userEvent.click(screen.getByRole('button', { name: 'Open S01' }))
    expect(screen.getByTitle('Pack/S01/e01.srt')).toBeInTheDocument()
  })

  it('starts a very large tree with its folders closed', () => {
    const many = Array.from({ length: 201 }, (_, i) => file(i, `Pack/Disc ${i % 3}/t${i}.flac`))
    renderTree(many)
    expect(screen.getAllByRole('treeitem')).toHaveLength(3)
    expect(screen.getByRole('button', { name: 'Open Disc 0' })).toBeInTheDocument()
  })

  it('cycles a file’s priority and refuses for a skipped one', async () => {
    const { onCyclePriority } = renderTree(FILES)
    await userEvent.click(screen.getByRole('button', { name: 'Priority for Pack/nfo.txt: High' }))
    expect(onCyclePriority).toHaveBeenCalledWith(3, 'high')
    expect(screen.queryByRole('button', { name: /Priority for Pack\/S01\/e01\.srt/ })).toBeNull()
    expect(screen.getAllByText(sheet.sheet.files.skipped).length).toBeGreaterThan(0)
  })

  it('selects only video through the Select menu', () => {
    const { onSetFiles } = renderTree(FILES)
    fireEvent.change(screen.getByRole('combobox', { name: en.files.select }), { target: { value: 'video' } })
    expect(onSetFiles).toHaveBeenCalledWith([2], 'normal')
  })

  it('selects all, none, or one extension', async () => {
    const { onSetFiles } = renderTree(FILES)
    const select = screen.getByRole('combobox', { name: en.files.select })
    fireEvent.change(select, { target: { value: 'all' } })
    await vi.waitFor(() => expect(onSetFiles).toHaveBeenCalledWith([1, 2], 'normal'))
    await vi.waitFor(() => expect(select).not.toBeDisabled())
    fireEvent.change(select, { target: { value: 'none' } })
    await vi.waitFor(() => expect(onSetFiles).toHaveBeenCalledWith([0, 3], 'skip'))
    await vi.waitFor(() => expect(select).not.toBeDisabled())
    expect(screen.getByRole('option', { name: 'Only .mkv (2 files)' })).toBeInTheDocument()
    fireEvent.change(select, { target: { value: 'ext:srt' } })
    await vi.waitFor(() => expect(onSetFiles).toHaveBeenLastCalledWith([0, 3], 'skip'))
  })

  it('filters by name, keeps the path to each match, and scopes All to what is shown', async () => {
    const many = Array.from({ length: 9 }, (_, i) => file(i, `Pack/Disc ${i % 2}/track${i}.flac`, 'skip'))
    const { onSetFiles } = renderTree(many)
    await userEvent.type(screen.getByRole('searchbox', { name: en.files.filter }), 'track3')
    const tree = screen.getByRole('tree')
    expect(within(tree).getAllByRole('treeitem')).toHaveLength(2) // Disc 1 and its one match
    expect(screen.getByRole('option', { name: en.files.allShown })).toBeInTheDocument()
    fireEvent.change(screen.getByRole('combobox', { name: en.files.select }), { target: { value: 'all' } })
    expect(onSetFiles).toHaveBeenCalledWith([3], 'normal')
  })

  it('says when the filter matches nothing', async () => {
    renderTree(Array.from({ length: 8 }, (_, i) => file(i, `Pack/t${i}.flac`)))
    await userEvent.type(screen.getByRole('searchbox', { name: en.files.filter }), 'zzz')
    expect(screen.getByText(en.files.noMatch)).toBeInTheDocument()
  })

  it('has no filter for a handful of files', () => {
    renderTree(FILES)
    expect(screen.queryByRole('searchbox')).toBeNull()
  })

  it('totals what is selected and says how much skipping saves', () => {
    renderTree(FILES)
    expect(screen.getByText('2.0 KB of 3.9 KB selected')).toBeInTheDocument()
    expect(screen.getByText(/^Skipping 2 files saves 2\.0 KB\./)).toBeInTheDocument()
  })

  it('offers no controls to a read-only session', () => {
    renderTree(FILES, { canWrite: false })
    expect(screen.queryByRole('combobox', { name: en.files.select })).toBeNull()
    expect(screen.getByRole('checkbox', { name: /everything in S01/ })).toBeDisabled()
    expect(screen.getByRole('button', { name: /Priority for Pack\/nfo\.txt/ })).toBeDisabled()
  })

  it('locks the tree while a selection is being applied', async () => {
    let finish: () => void = () => {}
    const onSetFiles = vi.fn(() => new Promise<void>((resolve) => (finish = resolve)))
    renderTree(FILES, { onSetFiles })
    await userEvent.click(screen.getByRole('checkbox', { name: /everything in S01/ }))
    expect(screen.getByRole('tree')).toHaveAttribute('aria-busy', 'true')
    expect(screen.getByRole('checkbox', { name: /everything in S02/ })).toBeDisabled()
    finish()
    await vi.waitFor(() => expect(screen.getByRole('tree')).toHaveAttribute('aria-busy', 'false'))
  })

  it('draws a long list in pages and adds more on request', async () => {
    const many = Array.from({ length: 450 }, (_, i) => file(i, `Pack/e${String(i).padStart(3, '0')}.mkv`))
    renderTree(many)
    expect(screen.getAllByRole('treeitem')).toHaveLength(200)
    await userEvent.click(screen.getByRole('button', { name: /Show 200 more of 250 remaining/ }))
    expect(screen.getAllByRole('treeitem')).toHaveLength(400)
  })
})
