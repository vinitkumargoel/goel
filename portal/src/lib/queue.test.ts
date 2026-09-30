import { describe, expect, it } from 'vitest'
import { fmtFinishAt, queueEstimate } from './queue'
import type { StatusToken, TaskRow } from './types'

function row(statusToken: StatusToken, total: number | null, done: number, down = 0): TaskRow {
  return {
    id: Math.random().toString(36),
    name: 'x',
    status: statusToken,
    statusToken,
    kind: 'http',
    progress: 0,
    downSpeed: down,
    upSpeed: 0,
    totalBytes: total,
    doneBytes: done,
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
  }
}

describe('queueEstimate', () => {
  it('divides the bytes left by the combined rate', () => {
    const est = queueEstimate([row('downloading', 1000, 400, 100), row('downloading', 500, 100, 100)])
    expect(est.remainingBytes).toBe(1000)
    expect(est.rate).toBe(200)
    expect(est.seconds).toBe(5)
  })

  it('counts queued work in the bytes but not the rate', () => {
    const est = queueEstimate([row('downloading', 100, 0, 50), row('queued', 300, 0)])
    expect(est.remainingBytes).toBe(400)
    expect(est.seconds).toBe(8)
  })

  it('leaves out paused, failed, finished and seeding rows', () => {
    const est = queueEstimate([
      row('paused', 1000, 0),
      row('failed', 1000, 0),
      row('completed', 1000, 1000),
      row('seeding', 1000, 1000, 0),
    ])
    expect(est).toEqual({ remainingBytes: 0, rate: 0, seconds: null, unknown: 0 })
  })

  it('reports unknown sizes instead of guessing them', () => {
    const est = queueEstimate([row('metadata', null, 0), row('downloading', 100, 0, 10)])
    expect(est.unknown).toBe(1)
    expect(est.remainingBytes).toBe(100)
    expect(est.seconds).toBe(10)
  })

  it('treats a zero size as not known yet, as the Mac app does', () => {
    const est = queueEstimate([row('downloading', 0, 0, 10), row('queued', 100, 0)])
    expect(est.unknown).toBe(1)
    expect(est.remainingBytes).toBe(100)
  })

  it('has no ETA when nothing is moving', () => {
    expect(queueEstimate([row('queued', 100, 0)]).seconds).toBeNull()
  })

  it('never counts negative remainders or bogus rates', () => {
    const est = queueEstimate([row('verifying', 100, 150, Number.POSITIVE_INFINITY)])
    expect(est.remainingBytes).toBe(0)
    expect(est.rate).toBe(0)
    expect(est.seconds).toBeNull()
  })
})

describe('fmtFinishAt', () => {
  it('is a bare time on the same day and gains the weekday past midnight', () => {
    const noon = new Date(2026, 8, 30, 12, 0).getTime()
    const same = fmtFinishAt(3600, noon)
    const tomorrow = fmtFinishAt(86400, noon)
    expect(same).not.toMatch(/\s\S+\s/)
    expect(tomorrow.length).toBeGreaterThan(same.length)
    expect(tomorrow.endsWith(fmtFinishAt(0, noon + 86400_000))).toBe(true)
  })
})
