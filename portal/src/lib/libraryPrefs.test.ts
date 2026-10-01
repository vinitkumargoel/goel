import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { memoryStorage } from '../test/memoryStorage'
import { DEFAULT_LIBRARY_PREFS, loadLibraryPrefs, saveLibraryPref } from './libraryPrefs'

beforeEach(() => vi.stubGlobal('localStorage', memoryStorage()))
afterEach(() => vi.unstubAllGlobals())

describe('libraryPrefs', () => {
  it('defaults, then remembers each choice', () => {
    expect(loadLibraryPrefs()).toEqual(DEFAULT_LIBRARY_PREFS)
    saveLibraryPref('group', 'host')
    saveLibraryPref('density', 'compact')
    saveLibraryPref('layout', 'cards')
    expect(loadLibraryPrefs()).toEqual({ group: 'host', density: 'compact', layout: 'cards' })
  })

  it('ignores values it does not know', () => {
    localStorage.setItem('goel.library.group', 'colour')
    expect(loadLibraryPrefs().group).toBe('none')
  })
})
