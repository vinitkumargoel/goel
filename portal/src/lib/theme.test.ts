import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { applyTheme, initialTheme, normalizeTheme, resolveTheme, watchSystemTheme } from './theme'

type Listener = (e: MediaQueryListEvent) => void

/** A controllable `prefers-color-scheme: dark` query. */
function fakeMatchMedia(dark: boolean) {
  const listeners = new Set<Listener>()
  const state = { dark }
  const mm = vi.fn((query: string) => ({
    get matches() {
      return query.includes('dark') ? state.dark : false
    },
    media: query,
    addEventListener: (_: string, l: Listener) => listeners.add(l),
    removeEventListener: (_: string, l: Listener) => listeners.delete(l),
  }))
  vi.stubGlobal('matchMedia', mm)
  return {
    flip(next: boolean) {
      state.dark = next
      for (const l of listeners) l({ matches: next } as MediaQueryListEvent)
    },
    listeners,
  }
}

/** A fresh in-memory Storage: the runtime's own `localStorage` is not reliably present under jsdom. */
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

beforeEach(() => {
  vi.stubGlobal('localStorage', memoryStorage())
})

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('resolveTheme', () => {
  it('maps Auto to the OS appearance and leaves a concrete theme alone', () => {
    expect(resolveTheme('auto', true)).toBe('dark')
    expect(resolveTheme('auto', false)).toBe('light')
    expect(resolveTheme('dark', false)).toBe('dark')
    expect(resolveTheme('light', true)).toBe('light')
  })
})

describe('normalizeTheme', () => {
  it('accepts the Studio values as they are', () => {
    expect(normalizeTheme('light')).toBe('light')
    expect(normalizeTheme('dark')).toBe('dark')
    expect(normalizeTheme('auto')).toBe('auto')
  })

  it('maps every pre-Studio theme to the palette that replaced it', () => {
    expect(normalizeTheme('frost-light')).toBe('light')
    expect(normalizeTheme('frost-dark')).toBe('dark')
    expect(normalizeTheme('dracula')).toBe('dark')
    expect(normalizeTheme('nord')).toBe('dark')
  })

  it('rejects anything else', () => {
    expect(normalizeTheme('neon')).toBeNull()
    expect(normalizeTheme('')).toBeNull()
    expect(normalizeTheme(null)).toBeNull()
  })
})

describe('initialTheme', () => {
  it('defaults to Auto when nothing is stored', () => {
    expect(initialTheme()).toBe('auto')
  })

  it('returns a stored choice, including Auto', () => {
    localStorage.setItem('goel-web-theme', 'light')
    expect(initialTheme()).toBe('light')
    localStorage.setItem('goel-web-theme', 'auto')
    expect(initialTheme()).toBe('auto')
  })

  it('keeps a choice stored before Studio, as the palette that replaced it', () => {
    localStorage.setItem('goel-web-theme', 'dracula')
    expect(initialTheme()).toBe('dark')
    localStorage.setItem('goel-web-theme', 'frost-light')
    expect(initialTheme()).toBe('light')
    localStorage.setItem('goel-web-theme', 'nord')
    expect(initialTheme()).toBe('dark')
  })

  it('ignores a stored value that is not a theme', () => {
    localStorage.setItem('goel-web-theme', 'neon')
    expect(initialTheme()).toBe('auto')
  })
})

describe('applyTheme', () => {
  it('paints Auto with the OS appearance and persists the choice, not the resolution', () => {
    fakeMatchMedia(false)
    applyTheme('auto', true)
    expect(document.documentElement.dataset['theme']).toBe('light')
    expect(localStorage.getItem('goel-web-theme')).toBe('auto')
  })

  it('does not persist when asked not to', () => {
    fakeMatchMedia(true)
    applyTheme('dark', false)
    expect(document.documentElement.dataset['theme']).toBe('dark')
    expect(localStorage.getItem('goel-web-theme')).toBeNull()
  })
})

describe('watchSystemTheme', () => {
  it('reports OS flips until unsubscribed', () => {
    const media = fakeMatchMedia(true)
    const seen: boolean[] = []
    const stop = watchSystemTheme((dark) => seen.push(dark))
    media.flip(false)
    stop()
    media.flip(true)
    expect(seen).toEqual([false])
    expect(media.listeners.size).toBe(0)
  })
})
