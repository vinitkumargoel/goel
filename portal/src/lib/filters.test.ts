import { describe, expect, it } from 'vitest'
import { countFilters, filterTasks, isTypeFilter, matchesFilter } from './filters'
import type { StatusToken, TaskKind, TaskRow } from './types'

function row(id: string, name: string, statusToken: StatusToken, kind: TaskKind = 'http'): TaskRow {
  return {
    id,
    name,
    status: statusToken,
    statusToken,
    kind,
    progress: 0,
    downSpeed: 0,
    upSpeed: 0,
    totalBytes: null,
    doneBytes: 0,
    upBytes: 0,
    ratio: 0,
    seeds: null,
    conns: 0,
    addedAt: 0,
    etaSeconds: null,
    error: null,
    source: `https://example.com/${name}`,
    multiFile: false,
    fileCount: 1,
    streamable: false,
  }
}

const TASKS = [
  row('1', 'ubuntu.iso', 'downloading'),
  row('2', 'movie.mkv', 'paused', 'torrent'),
  row('3', 'stream', 'queued', 'hls'),
  row('4', 'backup.zip', 'completed'),
  row('5', 'Tool.pkg', 'failed'),
  row('6', 'notes.pdf', 'seeding', 'torrent'),
]

describe('matchesFilter', () => {
  it('treats queued as active', () => {
    expect(matchesFilter(TASKS[2]!, 'active')).toBe(true)
  })

  it('classifies the Type group with fileType()', () => {
    expect(TASKS.filter((t) => matchesFilter(t, 'iso')).map((t) => t.id)).toEqual(['1'])
    expect(TASKS.filter((t) => matchesFilter(t, 'video')).map((t) => t.id)).toEqual(['2', '3'])
    expect(TASKS.filter((t) => matchesFilter(t, 'archive')).map((t) => t.id)).toEqual(['4'])
    expect(TASKS.filter((t) => matchesFilter(t, 'app')).map((t) => t.id)).toEqual(['5'])
  })
})

describe('countFilters', () => {
  it('counts statuses and types independently', () => {
    expect(countFilters(TASKS)).toEqual({
      all: 6,
      active: 2,
      paused: 1,
      completed: 1,
      seeding: 1,
      failed: 1,
      video: 2,
      iso: 1,
      archive: 1,
      app: 1,
    })
  })
})

describe('filterTasks', () => {
  it('combines a case-insensitive name search with the filter', () => {
    expect(filterTasks(TASKS, 'all', '  TOOL ').map((t) => t.id)).toEqual(['5'])
    expect(filterTasks(TASKS, 'video', 'movie').map((t) => t.id)).toEqual(['2'])
    expect(filterTasks(TASKS, 'completed', 'movie')).toEqual([])
  })

  it('returns a new array and leaves the input alone', () => {
    const out = filterTasks(TASKS, 'all', '')
    expect(out).not.toBe(TASKS)
    expect(out).toEqual(TASKS)
  })
})

describe('isTypeFilter', () => {
  it('tells the Type group from the Status group', () => {
    expect(isTypeFilter('video')).toBe(true)
    expect(isTypeFilter('paused')).toBe(false)
  })
})
