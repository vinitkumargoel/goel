import { describe, expect, it } from 'vitest'
import { sameTask, shareTasks } from './shareTasks'
import type { TaskRow } from './types'

function task(id: string, over: Partial<TaskRow> = {}): TaskRow {
  return {
    id,
    name: `${id}.iso`,
    status: 'Downloading',
    statusToken: 'downloading',
    kind: 'http',
    progress: 0.5,
    downSpeed: 100,
    upSpeed: 0,
    totalBytes: 1000,
    doneBytes: 500,
    upBytes: 0,
    ratio: 0,
    seeds: null,
    conns: 1,
    addedAt: 1,
    etaSeconds: 5,
    error: null,
    source: `https://x/${id}`,
    multiFile: false,
    fileCount: 1,
    streamable: false,
    ...over,
  }
}

describe('sameTask', () => {
  it('compares every field', () => {
    expect(sameTask(task('a'), task('a'))).toBe(true)
    expect(sameTask(task('a'), task('a', { progress: 0.6 }))).toBe(false)
    expect(sameTask(task('a'), task('a', { error: 'x' }))).toBe(false)
  })
})

describe('shareTasks', () => {
  it('returns the previous array itself when nothing changed', () => {
    const prev = [task('a'), task('b')]
    expect(shareTasks(prev, [task('a'), task('b')])).toBe(prev)
  })

  it('keeps unchanged rows by identity and replaces only the changed one', () => {
    const prev = [task('a'), task('b'), task('c')]
    const next = shareTasks(prev, [task('a'), task('b', { progress: 0.9 }), task('c')])
    expect(next).not.toBe(prev)
    expect(next[0]).toBe(prev[0])
    expect(next[1]).not.toBe(prev[1])
    expect(next[1]!.progress).toBe(0.9)
    expect(next[2]).toBe(prev[2])
  })

  it('reuses rows across a reorder, an addition and a removal', () => {
    const prev = [task('a'), task('b'), task('c')]
    const fresh = task('d')
    const next = shareTasks(prev, [task('c'), task('a'), fresh])
    expect(next).toEqual([prev[2], prev[0], fresh])
    expect(next[0]).toBe(prev[2])
    expect(next[1]).toBe(prev[0])
  })

  it('notices a pure removal from the end', () => {
    const prev = [task('a'), task('b')]
    const next = shareTasks(prev, [task('a')])
    expect(next).toHaveLength(1)
    expect(next[0]).toBe(prev[0])
  })

  it('treats a freshly parsed tags array with the same strings as unchanged', () => {
    const prev = [task('a', { tags: ['x', 'y'] })]
    expect(shareTasks(prev, [task('a', { tags: ['x', 'y'] })])).toBe(prev)
    expect(sameTask(prev[0]!, task('a', { tags: ['x', 'z'] }))).toBe(false)
  })
})
