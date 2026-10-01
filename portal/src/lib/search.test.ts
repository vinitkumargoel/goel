import { describe, expect, it } from 'vitest'
import { joinSearch, matchesSearch, parseSearch, sourceHost, splitSearch } from './search'
import type { TaskRow } from './types'

const task = (over: Partial<TaskRow>): TaskRow =>
  ({
    id: 'x',
    name: 'ubuntu-24.04.iso',
    statusToken: 'downloading',
    kind: 'http',
    source: 'https://releases.ubuntu.com/24.04/ubuntu.iso',
    savePath: '/srv/Downloads/ISO',
    ...over,
  }) as TaskRow

const hit = (q: string, t: TaskRow = task({})) => matchesSearch(t, parseSearch(q))

describe('search', () => {
  it('matches free words against name, host and folder', () => {
    expect(hit('ubuntu')).toBe(true)
    expect(hit('releases.ubuntu')).toBe(true)
    expect(hit('downloads/iso')).toBe(true)
    expect(hit('ubuntu fedora')).toBe(false)
  })

  it('narrows with is:, host: and type:', () => {
    expect(hit('is:downloading')).toBe(true)
    expect(hit('is:active')).toBe(true)
    expect(hit('is:failed')).toBe(false)
    expect(hit('is:done', task({ statusToken: 'completed' }))).toBe(true)
    expect(hit('host:ubuntu.com')).toBe(true)
    expect(hit('host:example')).toBe(false)
    expect(hit('type:iso')).toBe(true)
    expect(hit('type:http')).toBe(true)
    expect(hit('type:torrent')).toBe(false)
  })

  it('treats repeats of one key as alternatives', () => {
    expect(hit('is:failed is:downloading')).toBe(true)
    expect(hit('is:failed type:iso')).toBe(false)
  })

  it('has no host for a magnet', () => {
    expect(sourceHost('magnet:?xt=urn:btih:abc')).toBe('')
    expect(sourceHost('not a url')).toBe('')
  })

  it('turns finished tokens into chips and leaves the one being typed', () => {
    expect(splitSearch('is:failed big')).toEqual({ chips: [{ key: 'is', value: 'failed' }], rest: 'big' })
    expect(splitSearch('big is:fai')).toEqual({ chips: [], rest: 'big is:fai' })
    expect(splitSearch('big is:failed ')).toEqual({ chips: [{ key: 'is', value: 'failed' }], rest: 'big ' })
    expect(splitSearch('')).toEqual({ chips: [], rest: '' })
  })

  it('joins chips and text back into one search that splits the same way', () => {
    const chips = [{ key: 'host' as const, value: 'e.com' }]
    const joined = joinSearch(chips, 'movie')
    expect(joined).toBe('host:e.com movie')
    expect(splitSearch(joined)).toEqual({ chips, rest: 'movie' })
    expect(joinSearch([], 'plain')).toBe('plain')
  })
})
