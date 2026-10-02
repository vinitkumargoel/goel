import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { Icon, type IconName } from '../ui/Icon'

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
    <span className={`set-saved${shown ? ' on' : ''}`} role="status">
      {shown && (
        <>
          <Icon name="check" size="s" />
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
    <div className="set-dirty" role="group" aria-label={t('settings.unsaved')}>
      <span className="set-dot" aria-hidden="true" />
      <span className="set-dirty-t small">{t('settings.unsaved')}</span>
      <button type="button" className="btn sm ghost" disabled={busy} onClick={onDiscard}>
        {t('settings.discard')}
      </button>
      <button type="button" className="btn sm pri" disabled={busy || saveDisabled} title={saveTitle} onClick={onSave}>
        {t('common.save')}
      </button>
    </div>
  )
}

interface CardProps {
  title: ReactNode
  /** Beside the title: a state pill, a Saved tick. */
  aside?: ReactNode
  icon?: IconName
  wide?: boolean
  className?: string
  children: ReactNode
}

/** One topic as a Studio `.sgroup` card: a heading row, then `.srow`s or free content. */
export function SettingsCard({ title, aside, icon, wide = false, className, children }: CardProps) {
  return (
    <section className={`sgroup set-card${wide ? ' set-wide' : ''}${className ? ` ${className}` : ''}`}>
      <div className="sgroup-h">
        {icon && <Icon name={icon} className="faint" />}
        <h3 className="h3">{title}</h3>
        {aside}
      </div>
      {children}
    </section>
  )
}

/** "Managed by your organization", "Unavailable": a quiet pill beside a title. */
export function Pill({ tone, children }: { tone?: 'acc' | 'good' | 'warn' | 'bad'; children: ReactNode }) {
  return <span className={`pill nodot${tone ? ` ${tone}` : ''}`}>{children}</span>
}
