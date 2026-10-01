import { describe, expect, it } from 'vitest'
import { autoLanguage, pickLanguage } from './language'

const SUPPORTED = ['en', 'de']

describe('pickLanguage', () => {
  it('prefers the stored choice, then the server, then the browser, then the fallback', () => {
    expect(pickLanguage('de', 'en', ['en-US'], SUPPORTED, 'en')).toBe('de')
    expect(pickLanguage('', 'de', ['en-US'], SUPPORTED, 'en')).toBe('de')
    expect(pickLanguage('', '', ['fr-FR', 'de-AT'], SUPPORTED, 'en')).toBe('de')
    expect(pickLanguage('', 'ja', ['fr'], SUPPORTED, 'en')).toBe('en')
  })

  it('ignores a stored language this build no longer ships', () => {
    expect(pickLanguage('fr', 'de', [], SUPPORTED, 'en')).toBe('de')
  })

  it('matches region and underscore variants by their base', () => {
    expect(autoLanguage('de_CH', [], SUPPORTED, 'en')).toBe('de')
  })
})
