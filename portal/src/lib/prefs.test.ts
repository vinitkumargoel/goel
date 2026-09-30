import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { loadPanelAutoHide, panelVisible, savePanelAutoHide } from './prefs'

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

describe('panel auto-hide preference', () => {
  beforeEach(() => vi.stubGlobal('localStorage', memoryStorage()))
  afterEach(() => vi.unstubAllGlobals())

  it('is off until chosen, then survives a reload', () => {
    expect(loadPanelAutoHide()).toBe(false)
    savePanelAutoHide(true)
    expect(loadPanelAutoHide()).toBe(true)
    savePanelAutoHide(false)
    expect(loadPanelAutoHide()).toBe(false)
  })

  it('falls back to off when storage throws', () => {
    vi.stubGlobal('localStorage', {
      getItem: () => {
        throw new Error('blocked')
      },
      setItem: () => {
        throw new Error('blocked')
      },
    })
    expect(() => savePanelAutoHide(true)).not.toThrow()
    expect(loadPanelAutoHide()).toBe(false)
  })
})

describe('panelVisible', () => {
  it('hides an open panel only while nothing is selected', () => {
    expect(panelVisible(true, true, false)).toBe(false)
    expect(panelVisible(true, true, true)).toBe(true)
    expect(panelVisible(true, false, false)).toBe(true)
  })

  it('never opens a panel the user closed', () => {
    expect(panelVisible(false, false, true)).toBe(false)
    expect(panelVisible(false, true, true)).toBe(false)
  })
})
