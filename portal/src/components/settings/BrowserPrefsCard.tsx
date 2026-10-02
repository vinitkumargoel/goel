import { useId, useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { ToastTone } from '../../hooks/useToasts'
import i18n, { LANGUAGE_NAMES, LANGUAGES, type Language } from '../../i18n'
import { BOOT } from '../../lib/boot'
import { autoLanguage, browserLanguages, loadLanguage, saveLanguage } from '../../lib/language'
import { loadNotify, notifyPermission, requestNotify, saveNotify, type NotifyPermission } from '../../lib/notify'
import { Switch } from '../ui/Controls'
import { Icon } from '../ui/Icon'

type Toast = (message: string, tone?: ToastTone) => void

/** System notifications for finished and failed downloads, in this browser only. */
export function NotifyRow({ onToast }: { onToast: Toast }) {
  const { t } = useTranslation()
  const id = useId()
  const [notify, setNotify] = useState(loadNotify)
  const [permission, setPermission] = useState<NotifyPermission>(notifyPermission)

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

  const blocked = permission === 'denied' || permission === 'unsupported'
  return (
    <div className="srow">
      <div className="sl">
        <b id={`${id}-t`}>{t('browser.notify')}</b>
        <span id={`${id}-d`}>
          {permission === 'denied'
            ? t('browser.notifyDenied')
            : permission === 'unsupported'
              ? t('browser.notifyUnsupported')
              : t('browser.notifyHint')}
        </span>
      </div>
      <Switch
        checked={notify && permission === 'granted'}
        disabled={blocked}
        labelledBy={`${id}-t`}
        describedBy={`${id}-d`}
        onChange={(on) => void toggleNotify(on)}
      />
    </div>
  )
}

/** The portal's language: Automatic follows the server, then the browser. Kept in this browser. */
export function LanguageRow() {
  const { t } = useTranslation()
  const [language, setLanguage] = useState(loadLanguage)
  const auto = autoLanguage(BOOT.language, browserLanguages(), LANGUAGES, 'en') as Language
  const pickLanguage = (code: string) => {
    saveLanguage(code)
    setLanguage(code)
    void i18n.changeLanguage(code || auto)
  }
  return (
    <div className="srow">
      <div className="sl">
        <b>
          <label htmlFor="portal-language">{t('browser.language')}</label>
        </b>
      </div>
      <div className="field sm select set-select">
        <select id="portal-language" value={language} onChange={(e) => pickLanguage(e.target.value)}>
          <option value="">{t('browser.languageAuto', { name: LANGUAGE_NAMES[auto] })}</option>
          {LANGUAGES.map((code) => (
            <option key={code} value={code} lang={code}>
              {LANGUAGE_NAMES[code]}
            </option>
          ))}
        </select>
        <Icon name="chevronDown" size="s" />
      </div>
    </div>
  )
}
