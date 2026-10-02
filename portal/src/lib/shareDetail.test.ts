import { describe, expect, it } from 'vitest'
import { makeTask } from '../test/makeTask'
import { shareDetail } from './shareDetail'
import type { FileRow, TaskDetail } from './types'

const file = (id: number, progress = 0): FileRow => ({ id, name: `f${id}`, size: 10, done: progress * 10, progress, priority: 'normal' })
const detail = (files: FileRow[]): TaskDetail => ({
  row: makeTask('a'),
  savePath: '/x',
  sequential: false,
  infoHash: null,
  files,
  trackers: [],
  connections: [],
  pieces: [1, 2],
  server: null,
  mimeType: null,
})

describe('shareDetail', () => {
  it('keeps the files array when a refetch changed nothing', () => {
    const prev = detail([file(1), file(2)])
    const next = shareDetail(prev, detail([file(1), file(2)]))
    expect(next.files).toBe(prev.files)
    expect(next.pieces).toBe(prev.pieces)
    expect(next.row).toBe(prev.row)
  })

  it('keeps unchanged file objects and replaces only the changed one', () => {
    const prev = detail([file(1), file(2)])
    const next = shareDetail(prev, detail([file(1), file(2, 0.5)]))
    expect(next.files).not.toBe(prev.files)
    expect(next.files[0]).toBe(prev.files[0])
    expect(next.files[1]).not.toBe(prev.files[1])
  })

  it('never shares across different tasks', () => {
    const prev = detail([file(1)])
    const other = { ...detail([file(1)]), row: makeTask('b') }
    expect(shareDetail(prev, other)).toBe(other)
  })
})
