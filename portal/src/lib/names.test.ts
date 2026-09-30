import { describe, expect, it } from 'vitest'
import { breakRuns, commonDir, fileLabels, siblingStem, splitTail } from './names'
import { pieceRuns, piecesHave } from './pieces'

describe('breakRuns', () => {
  it('ends each run at a separator and keeps every character', () => {
    const name = 'Big.Buck.Bunny_2160p-HDR.mkv'
    const runs = breakRuns(name)
    expect(runs).toEqual(['Big.', 'Buck.', 'Bunny_', '2160p-', 'HDR.', 'mkv'])
    expect(runs.join('')).toBe(name)
  })

  it('leaves a name with no separators whole', () => {
    expect(breakRuns('README')).toEqual(['README'])
  })
})

describe('splitTail', () => {
  it('keeps the distinguishing end of a long name', () => {
    const { head, tail } = splitTail('Big.Buck.Bunny.2008.Season.01.S01E12.2160p.mkv')
    expect(tail).toBe('S01E12.2160p.mkv')
    expect(head + tail).toBe('Big.Buck.Bunny.2008.Season.01.S01E12.2160p.mkv')
  })

  it('does not split a short name', () => {
    expect(splitTail('poster.jpg')).toEqual({ head: 'poster.jpg', tail: '' })
  })
})

describe('commonDir', () => {
  it('finds the folder every file shares', () => {
    expect(
      commonDir(['Show/Season 01/E01.mkv', 'Show/Season 01/E02.mkv', 'Show/Season 01/Subs/en.srt']),
    ).toBe('Show/Season 01/')
  })

  it('stops at the first folder that differs', () => {
    expect(commonDir(['Show/Season 01/E01.mkv', 'Show/Extras/Making.mkv'])).toBe('Show/')
  })

  it('never treats a file name as a folder', () => {
    expect(commonDir(['Show/a.mkv', 'Show/a.mkv'])).toBe('Show/')
    expect(commonDir(['a.mkv', 'b.mkv'])).toBe('')
  })

  it('has nothing to strip for one file', () => {
    expect(commonDir(['Show/a.mkv'])).toBe('')
  })
})

describe('siblingStem', () => {
  it('finds the repeated prefix, ending on a separator', () => {
    expect(siblingStem(['Show.Name.S01E01.1080p.mkv', 'Show.Name.S01E02.1080p.mkv'])).toBe('Show.Name.')
  })

  it('declines a short prefix, a lone file, or one that would leave a stub', () => {
    expect(siblingStem(['a.mkv', 'a.srt'])).toBe('')
    expect(siblingStem(['Show.Name.S01E01.mkv'])).toBe('')
    expect(siblingStem(['Some.Release.mkv', 'Some.Release.nfo'])).toBe('')
  })
})

describe('fileLabels', () => {
  it('splits each path into its subfolder and the part of its name that differs', () => {
    const paths = [
      'Pack/Season 01/Show.Name.S01E01.2160p.mkv',
      'Pack/Season 01/Show.Name.S01E02.2160p.mkv',
      'Pack/Extras/Making.Of.mkv',
      'Pack/poster.jpg',
    ]
    expect(fileLabels(paths, 'Pack/')).toEqual([
      { dir: 'Season 01', label: 'S01E01.2160p.mkv' },
      { dir: 'Season 01', label: 'S01E02.2160p.mkv' },
      { dir: 'Extras', label: 'Making.Of.mkv' },
      { dir: '', label: 'poster.jpg' },
    ])
  })
})

describe('pieceRuns', () => {
  it('merges neighbouring buckets of one state', () => {
    expect(pieceRuns([1, 1, 0.5, 0, 0, 1])).toEqual([
      { start: 0, length: 2, state: 'have' },
      { start: 2, length: 1, state: 'partial' },
      { start: 3, length: 2, state: 'missing' },
      { start: 5, length: 1, state: 'have' },
    ])
  })

  it('covers every bucket exactly once', () => {
    const pieces = Array.from({ length: 720 }, (_, i) => (i % 7 === 0 ? 1 : i % 5 === 0 ? 0.3 : 0))
    const runs = pieceRuns(pieces)
    expect(runs.reduce((n, r) => n + r.length, 0)).toBe(720)
    expect(piecesHave(pieces)).toBe(pieces.filter((p) => p >= 1).length)
  })

  it('is empty for no pieces', () => {
    expect(pieceRuns([])).toEqual([])
  })
})
