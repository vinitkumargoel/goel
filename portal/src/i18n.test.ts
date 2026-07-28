import { describe, expect, it } from 'vitest'
import i18n, { FALLBACK_LANGUAGE, resources } from './i18n'

type Leaf = { path: string; value: string }

function leaves(node: unknown, prefix = ''): Leaf[] {
  if (typeof node === 'string') return [{ path: prefix, value: node }]
  if (node === null || typeof node !== 'object') return []
  return Object.entries(node).flatMap(([k, v]) =>
    leaves(v, prefix ? `${prefix}.${k}` : k),
  )
}

const EN = leaves(resources.en.translation)

/**
 * `i18n.t` is typed to the catalogue, so it rejects a `string`. This sweep is the one
 * place that looks keys up dynamically — the cast is the point of the test, not a leak.
 */
const translate = (key: string): string => (i18n.t as (k: string) => string)(key)

/** i18next's plural suffixes; a key ending in one of these is a member of a plural set. */
const PLURAL_SUFFIXES = ['_zero', '_one', '_two', '_few', '_many', '_other']

describe('en catalogue', () => {
  it('is not empty', () => {
    expect(EN.length).toBeGreaterThan(100)
  })

  it('has no blank or whitespace-only values', () => {
    const blank = EN.filter((l) => l.value.trim() === '')
    expect(blank.map((l) => l.path)).toEqual([])
  })

  it('has no duplicate key paths', () => {
    const seen = new Set<string>()
    const dupes = EN.filter((l) => (seen.has(l.path) ? true : (seen.add(l.path), false)))
    expect(dupes.map((l) => l.path)).toEqual([])
  })

  it('resolves every key to its own value, never to the key path', () => {
    const unresolved = EN.filter((l) => translate(l.path) === l.path && l.value !== l.path)
    expect(unresolved.map((l) => l.path)).toEqual([])
  })

  it('gives every plural key both a _one and an _other form', () => {
    const bases = new Set(
      EN.map((l) => l.path)
        .filter((p) => PLURAL_SUFFIXES.some((s) => p.endsWith(s)))
        .map((p) => p.replace(/_(zero|one|two|few|many|other)$/, '')),
    )
    const paths = new Set(EN.map((l) => l.path))
    for (const base of bases) {
      expect(paths.has(`${base}_one`), `${base}_one is missing`).toBe(true)
      expect(paths.has(`${base}_other`), `${base}_other is missing`).toBe(true)
    }
  })

  it('closes every interpolation and rich-text tag it opens', () => {
    for (const { path, value } of EN) {
      const opens = value.match(/\{\{/g)?.length ?? 0
      const closes = value.match(/\}\}/g)?.length ?? 0
      expect(opens, `${path} has unbalanced {{ }}`).toBe(closes)

      for (const tag of new Set([...value.matchAll(/<(\w+)>/g)].map((m) => m[1]))) {
        expect(value.includes(`</${tag}>`), `${path} never closes <${tag}>`).toBe(true)
      }
    }
  })
})

describe('i18n instance', () => {
  it('starts on the fallback language', () => {
    expect(i18n.language).toBe(FALLBACK_LANGUAGE)
    expect(i18n.options.fallbackLng).toContain(FALLBACK_LANGUAGE)
  })

  it('interpolates without HTML-escaping, since React escapes already', () => {
    expect(i18n.t('settings.theme.toast', { theme: 'Frost & Nord' })).toBe(
      'Theme: Frost & Nord',
    )
  })

  it('selects the plural form from count', () => {
    expect(i18n.t('statusbar.downloads', { count: 1 })).toBe('1 download')
    expect(i18n.t('statusbar.downloads', { count: 4 })).toBe('4 downloads')
  })
})
