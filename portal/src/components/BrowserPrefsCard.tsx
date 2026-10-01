import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import i18n, { LANGUAGE_NAMES, LANGUAGES, type Language } from '../i18n'
import { BOOT } from '../lib/boot'
import { autoLanguage, browserLanguages, loadLanguage, saveLanguage } from '../lib/language'
import { loadNotify, notifyPermission, requestNotify, saveNotify, type NotifyPermission } from '../lib/notify'
import type { ToastTone } from '../hooks/useToasts'

/** Settings › This browser: system notifications and the portal's language. Both stay in this browser. */
export function BrowserPrefsCard({ onToast }: { onToast: (message: string, tone?: ToastTone) => void }) {
  const { t } = useTranslation()
  const [notify, setNotify] = useState(loadNotify)
  const [permission, setPermission] = useState<NotifyPermission>(notifyPermission)
  const [language, setLanguage] = useState(loadLanguage)

  const toggleNotify = async (on: boolean) => {
    if (!on) {
      saveNotify(false)
      setNotify(false)
      return
    }
    // Asked from the click itself: browsers ignore a permission prompt that no gesture started.
    const next = await requestNotify()
    setPermission(next)
    const granted = next === 'granted'
    saveNotify(granted)
    setNotify(granted)
    if (granted) onToast(t('browser.notifyOn'))
  }

  const auto = autoLanguage(BOOT.language, browserLanguages(), LANGUAGES, 'en') as Language
  const pickLanguage = (code: string) => {
    saveLanguage(code)
    setLanguage(code)
    void i18n.changeLanguage(code || auto)
  }

  const blocked = permission === 'denied' || permission === 'unsupported'
  return (
    <div className="card pd">
      <label className="srow" style={{ cursor: blocked ? 'default' : 'pointer' }}>
        <div className="sinfo">
          <div className="sname">{t('browser.notify')}</div>
          <div className="sdesc">
            {permission === 'denied'
              ? t('browser.notifyDenied')
              : permission === 'unsupported'
                ? t('browser.notifyUnsupported')
                : t('browser.notifyHint')}
          </div>
        </div>
        <div className="sctl">
          <input
            type="checkbox"
            checked={notify && permission === 'granted'}
            disabled={blocked}
            onChange={(e) => void toggleNotify(e.target.checked)}
          />
        </div>
      </label>
      <div className="srow">
        <div className="sinfo">
          <label className="sname" htmlFor="portal-language">
            {t('browser.language')}
          </label>
        </div>
        <div className="sctl">
          <select
            id="portal-language"
            className="finput hkind"
            value={language}
            onChange={(e) => pickLanguage(e.target.value)}
          >
            <option value="">{t('browser.languageAuto', { name: LANGUAGE_NAMES[auto] })}</option>
            {LANGUAGES.map((code) => (
              <option key={code} value={code} lang={code}>
                {LANGUAGE_NAMES[code]}
              </option>
            ))}
          </select>
        </div>
      </div>
    </div>
  )
}
