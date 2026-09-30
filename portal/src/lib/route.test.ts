import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { formatRoute, HOME, loadSort, parseRoute, saveSort } from './route'
import { UNSORTED } from './sort'

/** The runtime's own `localStorage` is not reliably present under jsdom. */
function memoryStorage(): Storage {
  const data = new Map<string, string>()
  return {
    get length() {
      return data.size
    },
    clear: () => data.clear(),
    getItem: (k) => data.get(k) ?? null,
    key: (i) => [...data.keys()][i] ?? null,
    removeItem: (k) => void data.delete(k),
    setItem: (k, v) => void data.set(k, String(v)),
  }
}

describe('route', () => {
  beforeEach(() => vi.stubGlobal('localStorage', memoryStorage()))
  afterEach(() => vi.unstubAllGlobals())

  it('round-trips views, filters and the selected download', () => {
    for (const r of [
      HOME,
      { ...HOME, filter: 'failed' as const },
      { ...HOME, filter: 'video' as const, task: 'a b' },
      { ...HOME, view: 'history' as const },
      { ...HOME, view: 'settings' as const },
    ]) {
      expect(parseRoute(formatRoute(r))).toEqual(r)
    }
    expect(formatRoute({ ...HOME, filter: 'failed', task: 'x' })).toBe('#/library/failed?task=x')
  })

  it('falls back to the whole library for anything unknown', () => {
    expect(parseRoute('')).toEqual(HOME)
    expect(parseRoute('#/nope')).toEqual(HOME)
    expect(parseRoute('#/library/<script>')).toEqual(HOME)
  })

  it('remembers a sort and forgets garbage', () => {
    saveSort({ key: 'eta', dir: 'desc' })
    expect(loadSort()).toEqual({ key: 'eta', dir: 'desc' })
    saveSort(UNSORTED)
    expect(loadSort()).toEqual(UNSORTED)
    localStorage.setItem('goel.sort', '{"key":"evil","dir":"desc"}')
    expect(loadSort()).toEqual(UNSORTED)
  })
})
