import { useId } from 'react'
import { useTranslation } from 'react-i18next'
import { Switch } from '../ui/Controls'
import { StartPicker } from '../dialogs/QueueDialogs'

export interface AddExtrasValue {
  sequential: boolean
  /** Unix seconds; null = start now. */
  startAt: number | null
  /** False while a custom start time is in the past or unreadable. */
  valid: boolean
}

export const NO_EXTRAS: AddExtrasValue = { sequential: false, startAt: null, valid: true }

/** "Download in order" and "Start at" — the server applies them to what it queued. */
export function AddExtras({ value, onChange }: { value: AddExtrasValue; onChange: (v: AddExtrasValue) => void }) {
  const { t } = useTranslation()
  const id = useId()
  return (
    <>
      <div className="col add-opt">
        <span className="lbl">{t('queue.startLabel')}</span>
        <StartPicker
          initial={value.startAt ? new Date(value.startAt * 1000) : null}
          onChange={(at, valid) =>
            onChange({ ...value, startAt: at ? Math.round(at.getTime() / 1000) : null, valid })
          }
        />
      </div>
      <div className="add-switch">
        <div className="col add-switch-t">
          <span className="small" id={`${id}-seq`}>
            {t('queue.sequential')}
          </span>
          <span className="help" id={`${id}-seqh`}>
            {t('queue.sequentialHint')}
          </span>
        </div>
        <Switch
          checked={value.sequential}
          labelledBy={`${id}-seq`}
          describedBy={`${id}-seqh`}
          onChange={(sequential) => onChange({ ...value, sequential })}
        />
      </div>
    </>
  )
}
