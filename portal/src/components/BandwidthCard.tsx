import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { Bandwidth } from '../hooks/useBandwidth'
import type { ToastTone } from '../hooks/useToasts'
import {
  fromField,
  isLocked,
  toField,
  type BandwidthProfile,
  type BandwidthUpdate,
  type CapField,
  type RateUnit,
} from '../lib/bandwidth'

interface Draft {
  name: string
  down: CapField
  up: CapField
}

const toDrafts = (profiles: readonly BandwidthProfile[]): Draft[] =>
  profiles.map((p) => ({ name: p.name, down: toField(p.downBytesPerSec), up: toField(p.upBytesPerSec) }))

interface BandwidthCardProps {
  bandwidth: Bandwidth
  canWrite: boolean
  onToast: (message: string, tone?: ToastTone) => void
}

/**
 * Settings → Bandwidth: the on/off switch and active profile save at once; cap edits wait for
 * Save. Hidden entirely for a daemon without the endpoint.
 */
export function BandwidthCard({ bandwidth, canWrite, onToast }: BandwidthCardProps) {
  const { t } = useTranslation()
  const { status, state, update } = bandwidth
  const [drafts, setDrafts] = useState<Draft[]>([])
  const [dirty, setDirty] = useState(false)
  const [busy, setBusy] = useState(false)

  // Adopt the server's caps as they arrive — but never over edits the user hasn't saved yet.
  useEffect(() => {
    if (state && !dirty) setDrafts(toDrafts(state.profiles))
  }, [state, dirty])

  if (status === 'unsupported') return null
  if (!state) {
    return (
      <div className="card pd">
        <p className="fhint" style={{ padding: 8 }}>
          {status === 'error' ? t('settings.bandwidth.readError') : t('settings.bandwidth.loading')}
        </p>
      </div>
    )
  }

  const enabledLocked = isLocked(state, 'enabled')
  const selectedLocked = isLocked(state, 'selected')
  const managed = <span className="chip chip-d">{t('settings.bandwidth.managed')}</span>

  async function save(body: BandwidthUpdate): Promise<boolean> {
    setBusy(true)
    const error = await update(body)
    setBusy(false)
    if (error === null) {
      onToast(t('settings.bandwidth.saved'))
      return true
    }
    if (error) onToast(error, 'warn')
    return false
  }

  async function saveCaps() {
    const profiles: BandwidthProfile[] = []
    for (const d of drafts) {
      const down = fromField(d.down)
      const up = fromField(d.up)
      if (down === undefined || up === undefined) {
        onToast(t('settings.bandwidth.invalid'), 'warn')
        return
      }
      profiles.push({ name: d.name, downBytesPerSec: down, upBytesPerSec: up })
    }
    if (await save({ profiles })) setDirty(false)
  }

  const edit = (name: string, dir: 'down' | 'up', field: Partial<CapField>) => {
    setDirty(true)
    setDrafts((ds) => ds.map((d) => (d.name === name ? { ...d, [dir]: { ...d[dir], ...field } } : d)))
  }

  return (
    <div className="card pd">
      <div className="srow">
        <div className="sinfo">
          <div className="sname">
            {t('settings.bandwidth.enabledName')}{' '}
            <span className={`chip ${state.enabled ? 'chip-w' : 'chip-d'}`}>
              {state.enabled ? t('common.on') : t('common.off')}
            </span>
            {enabledLocked && managed}
          </div>
          <div className="sdesc">{t('settings.bandwidth.desc')}</div>
        </div>
        <div className="sctl">
          {canWrite && (
            <button
              className={`btn${state.enabled ? '' : ' primary'}`}
              disabled={busy || enabledLocked}
              title={enabledLocked ? t('settings.bandwidth.managed') : undefined}
              onClick={() => void save({ enabled: !state.enabled })}
            >
              {state.enabled ? t('common.turnOff') : t('common.turnOn')}
            </button>
          )}
        </div>
      </div>

      <div className="srow">
        <div className="sinfo">
          <label className="sname" htmlFor="bw-profile">
            {t('settings.bandwidth.profileName')} {selectedLocked && managed}
          </label>
        </div>
        <div className="sctl">
          <select
            id="bw-profile"
            className="finput"
            value={state.selected}
            disabled={!canWrite || busy || selectedLocked}
            title={selectedLocked ? t('settings.bandwidth.managed') : undefined}
            onChange={(e) => void save({ selected: e.target.value })}
          >
            {state.profiles.map((p) => (
              <option key={p.name} value={p.name}>
                {p.name}
              </option>
            ))}
          </select>
        </div>
      </div>

      <div className="srow">
        <div className="sinfo">
          <div className="sname">{t('settings.bandwidth.capsName')}</div>
        </div>
      </div>
      <div className="bw-grid" role="group" aria-label={t('settings.bandwidth.capsName')}>
        <span aria-hidden="true" />
        <span className="bw-h" aria-hidden="true">{t('settings.bandwidth.down')}</span>
        <span className="bw-h" aria-hidden="true">{t('settings.bandwidth.up')}</span>
        {drafts.map((d) => (
          <CapRow key={d.name} draft={d} disabled={!canWrite} onEdit={edit} />
        ))}
      </div>

      {canWrite && (
        <div className="srow">
          <div className="sinfo" />
          <div className="sctl">
            <button className="btn primary" disabled={!dirty || busy} onClick={() => void saveCaps()}>
              {t('common.save')}
            </button>
          </div>
        </div>
      )}
    </div>
  )
}

interface CapRowProps {
  draft: Draft
  disabled: boolean
  onEdit: (name: string, dir: 'down' | 'up', field: Partial<CapField>) => void
}

function CapRow({ draft, disabled, onEdit }: CapRowProps) {
  const { t } = useTranslation()
  const cell = (dir: 'down' | 'up') => {
    const field = draft[dir]
    const label = t(dir === 'down' ? 'settings.bandwidth.downLabel' : 'settings.bandwidth.upLabel', {
      name: draft.name,
    })
    const invalid = fromField(field) === undefined
    return (
      <span className="bw-cap">
        <input
          className="finput"
          inputMode="decimal"
          value={field.value}
          disabled={disabled}
          placeholder={t('settings.bandwidth.unlimitedPlaceholder')}
          aria-label={label}
          aria-invalid={invalid ? true : undefined}
          onChange={(e) => onEdit(draft.name, dir, { value: e.target.value })}
        />
        <select
          className="finput"
          value={field.unit}
          disabled={disabled}
          aria-label={t('settings.bandwidth.unitLabel', { field: label })}
          onChange={(e) => onEdit(draft.name, dir, { unit: e.target.value as RateUnit })}
        >
          <option value="KB">{t('settings.bandwidth.unitKB')}</option>
          <option value="MB">{t('settings.bandwidth.unitMB')}</option>
        </select>
      </span>
    )
  }
  return (
    <>
      <span className="bw-name">{draft.name}</span>
      {cell('down')}
      {cell('up')}
    </>
  )
}
