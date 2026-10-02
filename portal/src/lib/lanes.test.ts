import { describe, expect, it } from 'vitest'
import { makeTask } from '../test/makeTask'
import {
  allFinishedToday,
  boardLanes,
  cardStyle,
  columnCount,
  estimatedHeight,
  flattenLanes,
  laneColumns,
  laneNeighbor,
  laneOf,
} from './lanes'
import type { StatusToken } from './types'

const NOW = new Date(2026, 9, 2, 15).getTime()
const TODAY = NOW / 1000 - 3600
const YESTERDAY = NOW / 1000 - 30 * 3600

describe('laneOf', () => {
  it('puts every state in the lane the app puts it in', () => {
    const cases: [StatusToken, string][] = [
      ['downloading', 'downloading'],
      ['verifying', 'downloading'],
      ['metadata', 'downloading'],
      ['queued', 'upNext'],
      ['paused', 'needsYou'],
      ['failed', 'needsYou'],
      ['completed', 'done'],
      ['seeding', 'done'],
    ]
    for (const [statusToken, lane] of cases) expect(laneOf({ statusToken }), statusToken).toBe(lane)
  })
})

describe('cardStyle', () => {
  it('draws the tall card only while bytes are moving', () => {
    expect(cardStyle({ statusToken: 'downloading' })).toBe('large')
    expect(cardStyle({ statusToken: 'verifying' })).toBe('large')
    expect(cardStyle({ statusToken: 'metadata' })).toBe('compact')
    expect(cardStyle({ statusToken: 'queued' })).toBe('compact')
    expect(cardStyle({ statusToken: 'completed' })).toBe('compact')
  })
})

describe('boardLanes', () => {
  const rows = [
    makeTask('done1', { statusToken: 'completed', completedAt: TODAY }),
    makeTask('q2', { statusToken: 'queued', queuePosition: 1 }),
    makeTask('dl', { statusToken: 'downloading' }),
    makeTask('q1', { statusToken: 'queued', queuePosition: 0 }),
    makeTask('bad', { statusToken: 'failed' }),
  ]

  it('orders lanes Downloading, Up next, Needs you, Done and leaves empty ones out', () => {
    const lanes = boardLanes(rows, 'none', NOW)
    expect(lanes.map((l) => l.kind)).toEqual(['downloading', 'upNext', 'needsYou', 'done'])
    expect(boardLanes([rows[2]!], 'none', NOW).map((l) => l.kind)).toEqual(['downloading'])
  })

  it('reads Up next in queue order', () => {
    const upNext = boardLanes(rows, 'none', NOW).find((l) => l.kind === 'upNext')!
    expect(upNext.tasks.map((t) => t.id)).toEqual(['q1', 'q2'])
  })

  it('says Done today only when every card finished today', () => {
    expect(boardLanes(rows, 'none', NOW).find((l) => l.kind === 'done')!.doneToday).toBe(true)
    const mixed = [...rows, makeTask('old', { statusToken: 'seeding', completedAt: YESTERDAY })]
    expect(boardLanes(mixed, 'none', NOW).find((l) => l.kind === 'done')!.doneToday).toBe(false)
  })

  it('lanes by the Group by sections when one is on', () => {
    const lanes = boardLanes(rows, 'status', NOW)
    expect(lanes.every((l) => l.kind === null && l.group != null)).toBe(true)
    expect(lanes.map((l) => l.group!.key)).toEqual(['downloading', 'queued', 'failed', 'completed'])
  })
})

describe('allFinishedToday', () => {
  it('is false for an empty lane or a card with no finish time', () => {
    expect(allFinishedToday([], NOW)).toBe(false)
    expect(allFinishedToday([makeTask('a', { completedAt: null })], NOW)).toBe(false)
  })
})

describe('board keyboard order', () => {
  const lanes = boardLanes(
    [
      makeTask('a1', { statusToken: 'downloading' }),
      makeTask('a2', { statusToken: 'downloading' }),
      makeTask('a3', { statusToken: 'downloading' }),
      makeTask('b1', { statusToken: 'queued' }),
      makeTask('c1', { statusToken: 'completed' }),
      makeTask('c2', { statusToken: 'completed' }),
    ],
    'none',
    NOW,
  )

  it('flattens lane by lane', () => {
    expect(flattenLanes(lanes).map((t) => t.id)).toEqual(['a1', 'a2', 'a3', 'b1', 'c1', 'c2'])
  })

  it('moves sideways at the same height, clamped to the next lane', () => {
    expect(laneNeighbor(lanes, 'a3', 1)).toBe('b1')
    expect(laneNeighbor(lanes, 'b1', 1)).toBe('c1')
    expect(laneNeighbor(lanes, 'a2', -1)).toBe('a2')
    expect(laneNeighbor(lanes, 'c2', -1)).toBe('b1')
  })

  it('starts from an edge when nothing is current', () => {
    expect(laneNeighbor(lanes, null, 1)).toBe('a1')
    expect(laneNeighbor(lanes, null, -1)).toBe('c1')
    expect(laneNeighbor([], null, 1)).toBeNull()
  })
})

describe('board layout', () => {
  it('fits as many 236px columns as the width allows, at most one per lane', () => {
    expect(columnCount(1000, 4, 18)).toBe(4)
    expect(columnCount(800, 4, 18)).toBe(3)
    expect(columnCount(300, 4, 18)).toBe(1)
    expect(columnCount(2000, 2, 18)).toBe(2)
    expect(columnCount(0, 3, 18)).toBe(3)
    expect(columnCount(800, 0, 18)).toBe(0)
  })

  it('estimates a lane from its cards, failed ones taller', () => {
    const lane = { tasks: [makeTask('a', { statusToken: 'downloading' }), makeTask('b', { statusToken: 'failed' })] }
    expect(estimatedHeight(lane, 10)).toBe(30 + 170 + 62 + 30 + 20)
  })

  it('stacks Up next over Needs you when four lanes share three columns', () => {
    expect(laneColumns([400, 100, 100, 300], 3)).toEqual([[0], [1, 2], [3]])
  })

  it('keeps lanes in reading order and balances the tallest column', () => {
    expect(laneColumns([100, 100, 100, 500], 2)).toEqual([[0, 1, 2], [3]])
    expect(laneColumns([100, 200], 1)).toEqual([[0, 1]])
    expect(laneColumns([100, 200], 4)).toEqual([[0], [1]])
    expect(laneColumns([], 3)).toEqual([])
  })
})
