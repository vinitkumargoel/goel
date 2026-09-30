import { useCallback, useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { CheckIcon } from './Icons'

/** A "Saved" tick that shows for a moment beside a control that applies at once. */
export function useSavedFlash(ms = 2400): [boolean, () => void] {
  const [shown, setShown] = useState(false)
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined)
  useEffect(() => () => clearTimeout(timer.current), [])
  const flash = useCallback(() => {
    clearTimeout(timer.current)
    setShown(true)
    timer.current = setTimeout(() => setShown(false), ms)
  }, [ms])
  return [shown, flash]
}

/** Always mounted, so the "Saved" it gains is announced by the live region. */
export function SavedTick({ shown }: { shown: boolean }) {
  const { t } = useTranslation()
  return (
    <span className={`saved-tick${shown ? ' on' : ''}`} role="status">
      {shown && (
        <>
          <CheckIcon aria-hidden="true" />
          {t('settings.saved')}
        </>
      )}
    </span>
  )
}

interface DirtyStripProps {
  dirty: boolean
  busy: boolean
  onDiscard: () => void
  onSave: () => void
  saveDisabled?: boolean
  saveTitle?: string
}

/** The one place a card's pending edits live: nothing to save, no strip. */
export function DirtyStrip({ dirty, busy, onDiscard, onSave, saveDisabled, saveTitle }: DirtyStripProps) {
  const { t } = useTranslation()
  if (!dirty) return null
  return (
    <div className="dirty-strip" role="group" aria-label={t('settings.unsaved')}>
      <span className="dirty-dot" aria-hidden="true" />
      <span className="dirty-t">{t('settings.unsaved')}</span>
      <button className="btn ghost" disabled={busy} onClick={onDiscard}>
        {t('settings.discard')}
      </button>
      <button className="btn primary" disabled={busy || saveDisabled} title={saveTitle} onClick={onSave}>
        {t('common.save')}
      </button>
    </div>
  )
}
