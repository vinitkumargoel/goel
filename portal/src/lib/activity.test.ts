import { describe, expect, it } from 'vitest'
import { APP_TITLE, documentTitle, statusMap, summarise, transitions } from './activity'
import type { StatusToken, TaskRow } from './types'

function row(id: string, statusToken: StatusToken, extra: Partial<TaskRow> = {}): TaskRow {
  return {
    id,
    name: `${id}.iso`,
    status: statusToken,
    statusToken,
    kind: 'http',
    progress: 0,
    downSpeed: 0,
    upSpeed: 0,
    totalBytes: 100,
    doneBytes: 0,
    upBytes: 0,
    ratio: 0,
    seeds: null,
    conns: 0,
    addedAt: 0,
    etaSeconds: null,
    error: null,
    source: '',
    multiFile: false,
    fileCount: 1,
    streamable: false,
    ...extra,
  } as TaskRow
}

const label = (n: number) => `${n} active`

describe('summarise and documentTitle', () => {
  it('is the bare app name when nothing runs', () => {
    const a = summarise([row('a', 'completed'), row('b', 'paused')])
    expect(documentTitle(a, label)).toBe(APP_TITLE)
  })

  it('sums rate and weighted progress over running downloads only', () => {
    const a = summarise([
      row('a', 'downloading', { downSpeed: 1_000_000, totalBytes: 100, doneBytes: 50 }),
      row('b', 'downloading', { downSpeed: 2_000_000, totalBytes: 300, doneBytes: 300 }),
      row('c', 'paused', { totalBytes: 1000, doneBytes: 0 }),
    ])
    expect(a.active).toBe(2)
    expect(a.progress).toBeCloseTo(350 / 400)
    expect(documentTitle(a, label)).toMatch(/^↓ .+ · 87% · 2 active — Goel°$/)
  })

  it('leaves the percentage out when no running size is known', () => {
    const a = summarise([row('a', 'metadata', { totalBytes: null })])
    expect(documentTitle(a, label)).not.toContain('%')
  })

  it('counts failures for the favicon badge', () => {
    expect(summarise([row('a', 'failed'), row('b', 'failed')]).failed).toBe(2)
  })
})

describe('transitions', () => {
  it('reports nothing on the first snapshot', () => {
    expect(transitions(null, [row('a', 'completed')])).toEqual({ finished: [], failed: [] })
  })

  it('reports a download reaching completed or seeding', () => {
    const before = statusMap([row('a', 'downloading'), row('b', 'downloading')])
    const out = transitions(before, [row('a', 'completed'), row('b', 'seeding')])
    expect(out.finished.map((t) => t.id)).toEqual(['a', 'b'])
  })

  it('does not report seeding → completed as a second finish', () => {
    const out = transitions(statusMap([row('a', 'seeding')]), [row('a', 'completed')])
    expect(out.finished).toEqual([])
  })

  it('reports a new failure, and ignores rows seen for the first time', () => {
    const out = transitions(statusMap([row('a', 'downloading')]), [
      row('a', 'failed'),
      row('new', 'completed'),
    ])
    expect(out.failed.map((t) => t.id)).toEqual(['a'])
    expect(out.finished).toEqual([])
  })

  it('ignores a row whose status did not change', () => {
    const out = transitions(statusMap([row('a', 'failed')]), [row('a', 'failed')])
    expect(out.failed).toEqual([])
  })
})
