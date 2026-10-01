import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { DEFAULT_ADD_PREFS, loadAddPrefs, MAX_RECENT, nextAddPrefs, rememberAdd } from './addPrefs'

import { memoryStorage } from '../test/memoryStorage'

beforeEach(() => vi.stubGlobal('localStorage', memoryStorage()))
afterEach(() => vi.unstubAllGlobals())

describe('addPrefs', () => {
  it('starts from the defaults', () => {
    expect(loadAddPrefs()).toEqual(DEFAULT_ADD_PREFS)
  })

  it('remembers the last folder and priority, most recent folder first, without repeats', () => {
    rememberAdd('/a', 'high')
    rememberAdd('/b', 'low')
    rememberAdd('/a', 'normal')
    expect(loadAddPrefs()).toEqual({ folder: '/a', priority: 'normal', recent: ['/a', '/b'] })
  })

  it('keeps the default folder out of the recent list', () => {
    expect(nextAddPrefs({ ...DEFAULT_ADD_PREFS, recent: ['/x'] }, '', 'normal').recent).toEqual(['/x'])
  })

  it('caps the recent list', () => {
    let prefs = DEFAULT_ADD_PREFS
    for (let i = 0; i < 9; i++) prefs = nextAddPrefs(prefs, `/f${i}`, 'normal')
    expect(prefs.recent).toHaveLength(MAX_RECENT)
    expect(prefs.recent[0]).toBe('/f8')
  })

  it('shrugs off junk in storage', () => {
    localStorage.setItem('goel.add.prefs', '{"priority":"urgent","recent":[1,"/ok"],"folder":5}')
    expect(loadAddPrefs()).toEqual({ folder: '', priority: 'normal', recent: ['/ok'] })
  })
})
