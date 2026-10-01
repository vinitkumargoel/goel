import i18n from 'i18next'
import { initReactI18next } from 'react-i18next'
import { BOOT } from './lib/boot'
import { browserLanguages, loadLanguage, pickLanguage } from './lib/language'
import de from './locales/de.json'
import en from './locales/en.json'

/**
 * Adding a language is two lines — an import above and an entry below. Nothing
 * else in the app reads a locale, so no call site changes.
 */
export const resources = {
  en: { translation: en },
  de: { translation: de },
} as const

export type Language = keyof typeof resources

export const FALLBACK_LANGUAGE: Language = 'en'

export const LANGUAGES = Object.keys(resources) as Language[]

/** Each language named in itself, as a language menu lists them. */
export const LANGUAGE_NAMES: Readonly<Record<Language, string>> = { en: 'English', de: 'Deutsch' }

export function initialLanguage(): Language {
  return pickLanguage(loadLanguage(), BOOT.language, browserLanguages(), LANGUAGES, FALLBACK_LANGUAGE) as Language
}

/**
 * Catalogues are statically imported, never fetched. `codegen.mjs` inlines exactly
 * one `portal.js` into `PortalBundle.swift`, and the Swift server serves no
 * `/locales/*` route — an HTTP backend would 404 in production while working in
 * `npm run dev`.
 */
i18n.use(initReactI18next).init({
  resources,
  lng: initialLanguage(),
  fallbackLng: FALLBACK_LANGUAGE,
  // React escapes interpolated values already; escaping here double-encodes them.
  interpolation: { escapeValue: false },
  returnNull: false,
  // Keeps i18next's vendor notice out of the user's browser console and the CI log.
  showSupportNotice: false,
  // Static resources cannot fail to load, so this only fires on a malformed catalogue —
  // where a silent rejection would leave every `t()` returning its own key.
}).then(() => {
  document.documentElement.lang = i18n.language
}).catch((error: unknown) => {
  console.error('i18next failed to initialise; the UI will render raw keys.', error)
})

/** Compile-time key checking: `t('nope')` is a type error, so `tsc` is the missing-key gate. */
declare module 'i18next' {
  interface CustomTypeOptions {
    defaultNS: 'translation'
    resources: (typeof resources)['en']
    returnNull: false
  }
}

i18n.on('languageChanged', (lng) => {
  document.documentElement.lang = lng
})

export default i18n
