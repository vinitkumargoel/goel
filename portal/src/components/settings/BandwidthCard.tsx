import { useEffect, useId, useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { Bandwidth } from '../../hooks/useBandwidth'
import type { ToastTone } from '../../hooks/useToasts'
import {
  capSummary,
  fromField,
  isLocked,
  toField,
  type BandwidthProfile,
  type BandwidthUpdate,
  type CapField,
  type RateUnit,
} from '../../lib/bandwidth'
import { Seg, Switch } from '../ui/Controls'
import { Icon, type IconName } from '../ui/Icon'
import { DirtyStrip, Pill, SavedTick, SettingsCard, useSavedFlash } from './SettingsParts'

interface Draft {
  name: string
  down: CapField
  up: CapField
}

type Dir = 'down' | 'up'

const toDrafts = (profiles: readonly BandwidthProfile[]): Draft[] =>
  profiles.map((p) => ({ name: p.name, down: toField(p.downBytesPerSec), up: toField(p.upBytesPerSec) }))

/** Slowest first is the usual order: a snail for the first, a bolt for the last, a gauge between. */
function profileIcon(index: number, count: number): IconName {
  if (count > 1 && index === 0) return 'snail'
  if (count > 1 && index === count - 1) return 'bolt'
  return 'gauge'
}

interface BandwidthCardProps {
  bandwidth: Bandwidth
  canWrite: boolean
  onToast: (message: string, tone?: ToastTone) => void
  /** Unsaved cap edits exist; Settings guards leaving while any card has some. */
  onDirty?: (dirty: boolean) => void
}

/**
 * Settings › Bandwidth: the limit switch and the profile in use save at once (and say so beside
 * themselves); profiles are cards you pick between. Cap edits wait in a strip with Save and
 * Discard. Hidden for a daemon without the feature.
 */
export function BandwidthCard({ bandwidth, canWrite, onToast, onDirty }: BandwidthCardProps) {
  const { t } = useTranslation()
  const id = useId()
  const { status, state, update } = bandwidth
  const [drafts, setDrafts] = useState<Draft[]>([])
  const [dirty, setDirty] = useState(false)
  const [busy, setBusy] = useState(false)
  const [editing, setEditing] = useState<string | null>(null)
  const [enabledSaved, flashEnabled] = useSavedFlash()
  const [profileSaved, flashProfile] = useSavedFlash()
  const [capsSaved, flashCaps] = useSavedFlash()

  useEffect(() => onDirty?.(dirty), [dirty, onDirty])

  // Adopt the server's caps as they arrive — but never over edits the user hasn't saved yet.
  useEffect(() => {
    if (state && !dirty) setDrafts(toDrafts(state.profiles))
  }, [state, dirty])

  if (status === 'unsupported') return null
  if (!state) {
    return (
      <SettingsCard title={t('settings.bandwidth.name')} icon="gauge" wide>
        <p className="srow small muted" role={status === 'error' ? 'alert' : 'status'}>
          {status === 'error' ? t('settings.bandwidth.readError') : t('settings.bandwidth.loading')}
        </p>
      </SettingsCard>
    )
  }

  const enabledLocked = isLocked(state, 'enabled')
  const selectedLocked = isLocked(state, 'selected')
  const managed = <Pill tone="warn">{t('settings.bandwidth.managed')}</Pill>
  const shownName = editing && drafts.some((d) => d.name === editing) ? editing : state.selected
  const draft = drafts.find((d) => d.name === shownName) ?? drafts[0]

  async function save(body: BandwidthUpdate, flash: () => void): Promise<boolean> {
    setBusy(true)
    const error = await update(body)
    setBusy(false)
    if (error === null) {
      flash()
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
        setEditing(d.name)
        onToast(t('settings.bandwidth.invalid'), 'warn')
        return
      }
      profiles.push({ name: d.name, downBytesPerSec: down, upBytesPerSec: up })
    }
    if (await save({ profiles }, flashCaps)) setDirty(false)
  }

  const discard = () => {
    setDrafts(toDrafts(state.profiles))
    setDirty(false)
  }

  const edit = (name: string, dir: Dir, field: Partial<CapField>) => {
    setDirty(true)
    setDrafts((ds) => ds.map((d) => (d.name === name ? { ...d, [dir]: { ...d[dir], ...field } } : d)))
  }

  const pickProfile = (name: string) => {
    setEditing(name)
    if (name !== state.selected) void save({ selected: name }, flashProfile)
  }

  return (
    <SettingsCard title={t('settings.bandwidth.name')} icon="gauge" wide className="set-bw">
      <div className="srow">
        <div className="sl">
          <b id={`${id}-on`}>
            {t('settings.bandwidth.enabledName')} {enabledLocked && managed}
          </b>
          <span id={`${id}-ond`}>{t('settings.bandwidth.desc')}</span>
        </div>
        <SavedTick shown={enabledSaved} />
        <Switch
          checked={state.enabled}
          disabled={!canWrite || busy || enabledLocked}
          labelledBy={`${id}-on`}
          describedBy={`${id}-ond`}
          onChange={(on) => void save({ enabled: on }, flashEnabled)}
        />
      </div>

      <div className="set-block">
        <div className="row set-block-h">
          <span className="lbl" id={`${id}-prof`}>
            {t('settings.bandwidth.profileName')}
          </span>
          {selectedLocked && managed}
          <span className="sp" />
          <SavedTick shown={profileSaved} />
        </div>
        <div className="set-profiles" role="group" aria-labelledby={`${id}-prof`}>
          {state.profiles.map((p, i) => {
            const inUse = p.name === state.selected
            return (
              <button
                key={p.name}
                type="button"
                className={`set-profile${inUse ? ' on' : ''}`}
                aria-pressed={inUse}
                disabled={!canWrite || busy || selectedLocked}
                title={selectedLocked ? t('settings.bandwidth.managed') : undefined}
                onClick={() => pickProfile(p.name)}
              >
                <span className="row">
                  <Icon name={profileIcon(i, state.profiles.length)} size="l" className={inUse ? 'acc' : 'faint'} />
                  <span className="h3">{p.name}</span>
                  <span className="sp" />
                  {inUse && <span className="pill acc">{t('pages.settings.inUse')}</span>}
                </span>
                <span className="mono small muted">{capSummary(p, t('settings.bandwidth.noCap'))}</span>
              </button>
            )
          })}
        </div>
      </div>

      {draft && (
        <div className="set-block">
          <div className="row set-block-h">
            <span className="lbl">{t('settings.bandwidth.capsName')}</span>
            <span className="sp" />
            <SavedTick shown={capsSaved} />
            {drafts.length > 1 && (
              <Seg
                size="sm"
                label={t('pages.settings.editProfile')}
                value={draft.name}
                options={drafts.map((d) => ({ value: d.name, label: d.name }))}
                onChange={setEditing}
                className="set-wrap"
              />
            )}
          </div>
          <div className="set-caps" role="group" aria-label={t('pages.settings.editing', { name: draft.name })}>
            <CapField draft={draft} dir="down" disabled={!canWrite} onEdit={edit} />
            <CapField draft={draft} dir="up" disabled={!canWrite} onEdit={edit} />
          </div>
        </div>
      )}

      {canWrite && <DirtyStrip dirty={dirty} busy={busy} onDiscard={discard} onSave={() => void saveCaps()} />}
    </SettingsCard>
  )
}

interface CapFieldProps {
  draft: Draft
  dir: Dir
  disabled: boolean
  onEdit: (name: string, dir: Dir, field: Partial<CapField>) => void
}

function CapField({ draft, dir, disabled, onEdit }: CapFieldProps) {
  const { t } = useTranslation()
  const field = draft[dir]
  const label = t(dir === 'down' ? 'settings.bandwidth.downLabel' : 'settings.bandwidth.upLabel', { name: draft.name })
  const invalid = fromField(field) === undefined
  return (
    <div className="col set-cap">
      <span className="lbl" aria-hidden="true">
        {t(dir === 'down' ? 'settings.bandwidth.down' : 'settings.bandwidth.up')}
      </span>
      <div className="row set-cap-row">
        <div className={`field sm mono${invalid ? ' invalid' : ''}`}>
          <input
            inputMode="decimal"
            value={field.value}
            disabled={disabled}
            placeholder={t('settings.bandwidth.unlimitedPlaceholder')}
            aria-label={label}
            aria-invalid={invalid ? true : undefined}
            onChange={(e) => onEdit(draft.name, dir, { value: e.target.value })}
          />
        </div>
        <div className="field sm select set-unit">
          <select
            value={field.unit}
            disabled={disabled}
            aria-label={t('settings.bandwidth.unitLabel', { field: label })}
            onChange={(e) => onEdit(draft.name, dir, { unit: e.target.value as RateUnit })}
          >
            <option value="KB">{t('settings.bandwidth.unitKB')}</option>
            <option value="MB">{t('settings.bandwidth.unitMB')}</option>
          </select>
          <Icon name="chevronDown" size="s" />
        </div>
      </div>
    </div>
  )
}
