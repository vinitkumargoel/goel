import { useTranslation } from 'react-i18next'
import { StartPicker } from './QueueDialogs'

export interface AddExtrasValue {
  sequential: boolean
  /** Unix seconds; null = start now. */
  startAt: number | null
  /** False while a custom start time is in the past or unreadable. */
  valid: boolean
}

export const NO_EXTRAS: AddExtrasValue = { sequential: false, startAt: null, valid: true }

/** The Add dialog's "download in order" and "start at" — applied by the server to what it queued. */
export function AddExtras({ value, onChange }: { value: AddExtrasValue; onChange: (v: AddExtrasValue) => void }) {
  const { t } = useTranslation()
  return (
    <div className="addx">
      <label className="addx-seq">
        <input
          type="checkbox"
          checked={value.sequential}
          onChange={(e) => onChange({ ...value, sequential: e.target.checked })}
        />
        {t('queue.addSequential')}
      </label>
      <div className="flabel">{t('queue.startLabel')}</div>
      <StartPicker
        initial={value.startAt ? new Date(value.startAt * 1000) : null}
        onChange={(at, valid) => onChange({ ...value, startAt: at ? Math.round(at.getTime() / 1000) : null, valid })}
      />
    </div>
  )
}
