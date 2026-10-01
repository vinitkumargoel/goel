import { fireEvent, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import type { FileRow, TaskDetail } from '../lib/types'
import { renderWithI18n } from '../test/renderWithI18n'
import { FilesTree } from './FilesTree'

function file(id: number, name: string, priority: FileRow['priority'] = 'normal'): FileRow {
  return { id, name, size: 1000, done: 0, progress: 0, priority }
}

function detail(files: FileRow[]): TaskDetail {
  return {
    row: { id: 't1', name: 'Pack', multiFile: true, statusToken: 'downloading' } as TaskDetail['row'],
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
  file(3, 'Pack/nfo.txt'),
]

describe('FilesTree', () => {
  it('shows folders with tri-state boxes and ticks a mixed folder fully in one request', async () => {
    const onSetFiles = vi.fn(() => Promise.resolve())
    renderWithI18n(<FilesTree detail={detail(FILES)} canWrite onSetFiles={onSetFiles} onCyclePriority={vi.fn()} />)
    const s01 = screen.getByRole('checkbox', { name: /everything in S01/ })
    expect(s01).toHaveAttribute('aria-checked', 'mixed')
    expect(screen.getByRole('checkbox', { name: /everything in S02/ })).toHaveAttribute('aria-checked', 'false')
    await userEvent.click(s01)
    expect(onSetFiles).toHaveBeenCalledWith([1], 'normal')
  })

  it('collapses a folder', async () => {
    renderWithI18n(<FilesTree detail={detail(FILES)} canWrite onSetFiles={vi.fn()} onCyclePriority={vi.fn()} />)
    expect(screen.getByTitle('Pack/S01/e01.srt')).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Close S01' }))
    expect(screen.queryByTitle('Pack/S01/e01.srt')).toBeNull()
  })

  it('selects only video through the Select menu', () => {
    const onSetFiles = vi.fn(() => Promise.resolve())
    renderWithI18n(<FilesTree detail={detail(FILES)} canWrite onSetFiles={onSetFiles} onCyclePriority={vi.fn()} />)
    fireEvent.change(screen.getByRole('combobox', { name: 'Select…' }), { target: { value: 'video' } })
    expect(onSetFiles).toHaveBeenCalledWith([2], 'normal')
  })

  it('filters by name and keeps the path to each match', async () => {
    const many = Array.from({ length: 9 }, (_, i) => file(i, `Pack/Disc ${i % 2}/track${i}.flac`))
    renderWithI18n(<FilesTree detail={detail(many)} canWrite onSetFiles={vi.fn()} onCyclePriority={vi.fn()} />)
    await userEvent.type(screen.getByRole('searchbox', { name: 'Filter files' }), 'track3')
    const tree = screen.getByRole('tree')
    expect(within(tree).getAllByRole('treeitem')).toHaveLength(2) // Disc 1 and its one match
  })

  it('offers no controls to a read-only session', () => {
    renderWithI18n(<FilesTree detail={detail(FILES)} canWrite={false} onSetFiles={vi.fn()} onCyclePriority={vi.fn()} />)
    expect(screen.queryByRole('combobox', { name: 'Select…' })).toBeNull()
    expect(screen.getByRole('checkbox', { name: /everything in S01/ })).toBeDisabled()
  })
})
