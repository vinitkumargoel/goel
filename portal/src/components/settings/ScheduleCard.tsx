import { useEffect, useId, useRef, useState, type CSSProperties } from 'react'
import { useTranslation } from 'react-i18next'
import type { ToastTone } from '../../hooks/useToasts'
import { api, ApiError, failureMessage } from '../../lib/api'
import { cellOpen, fmtMinute, HOURS, paintRange, sameSchedule, toggleDay, WEEK } from '../../lib/schedule'
import type { ScheduleState } from '../../lib/types'
import { Seg, Switch } from '../ui/Controls'
import { Icon } from '../ui/Icon'
import { brushColor } from './scheduleBrush'
import { DirtyStrip, SettingsCard } from './SettingsParts'

type Load = { status: 'loading' } | { status: 'unsupported' } | { status: 'error' } | { status: 'ready'; saved: ScheduleState }

const dayKey = (day: number) => `schedule.days.${day}` as 'schedule.days.1'

/**
 * Settings › Schedule: the one download window the Mac's scheduler runs, painted on a week × hour
 * grid in the colour of the profile it switches to. Edits collect in a draft and go to the server
 * on Save, like the other server cards. A server without a scheduler (404) shows nothing; the Linux daemon runs the same one.
 */
export function ScheduleCard({
  canWrite,
  onToast,
  onDirty,
}: {
  canWrite: boolean
  onToast: (message: string, tone?: ToastTone) => void
  onDirty: (dirty: boolean) => void
}) {
  const { t } = useTranslation()
  const id = useId()
  const [load, setLoad] = useState<Load>({ status: 'loading' })
  const [draft, setDraft] = useState<ScheduleState | null>(null)
  const [busy, setBusy] = useState(false)
  const drag = useRef<{ from: number } | null>(null)
  const [hover, setHover] = useState<{ from: number; to: number } | null>(null)
  const hoverRef = useRef(hover)
  hoverRef.current = hover
  const commitRef = useRef<(from: number, to: number) => void>(() => {})

  useEffect(() => {
    let live = true
    api
      .schedule()
      .then((s) => {
        if (!live) return
        setLoad({ status: 'ready', saved: s })
        setDraft(s)
      })
      .catch((e: unknown) => {
        if (!live) return
        // A server without a scheduler answers 404: the card stays away.
        setLoad(e instanceof ApiError && e.status === 404 ? { status: 'unsupported' } : { status: 'error' })
      })
    return () => {
      live = false
    }
  }, [])

  const saved = load.status === 'ready' ? load.saved : null
  const dirty = saved != null && draft != null && !sameSchedule(saved, draft)
  useEffect(() => onDirty(dirty), [dirty, onDirty])

  // Painting ends wherever the pointer is let go, even outside the grid.
  useEffect(() => {
    const end = () => {
      const range = hoverRef.current
      if (drag.current && range) commitRef.current(range.from, range.to)
      drag.current = null
      setHover(null)
    }
    window.addEventListener('pointerup', end)
    window.addEventListener('pointercancel', end)
    return () => {
      window.removeEventListener('pointerup', end)
      window.removeEventListener('pointercancel', end)
    }
  }, [])

  if (load.status === 'unsupported' || load.status === 'loading') return null
  if (load.status === 'error' || !draft || !saved) {
    return (
      <SettingsCard title={t('schedule.title')} icon="cal" wide>
        <p className="srow small muted" role="alert">
          {t('api.actionFailed')}
        </p>
      </SettingsCard>
    )
  }

  const edit = (patch: Partial<ScheduleState>) => setDraft((d) => (d ? { ...d, ...patch } : d))
  const color = brushColor(draft.profile, draft.profiles)
  const allDay = draft.startMinute === draft.endMinute
  const disabled = !canWrite || busy

  const save = async () => {
    setBusy(true)
    try {
      const next = await api.updateSchedule({
        enabled: draft.enabled,
        startMinute: draft.startMinute,
        endMinute: draft.endMinute,
        days: draft.days,
        profile: draft.profile,
      })
      setLoad({ status: 'ready', saved: next })
      setDraft(next)
      onToast(t('schedule.saved'))
    } catch (e) {
      const message = failureMessage(e)
      if (message) onToast(message, 'warn')
    } finally {
      setBusy(false)
    }
  }

  const startPaint = (hour: number) => {
    if (disabled) return
    drag.current = { from: hour }
    setHover({ from: hour, to: hour })
  }
  const overPaint = (hour: number) => {
    if (drag.current) setHover({ from: drag.current.from, to: hour })
  }
  commitRef.current = (from, to) => edit({ ...paintRange(from, to), enabled: true })
  // Touch pointers are captured by the cell they started on, so find the one under the finger.
  const movePaint = (x: number, y: number) => {
    if (!drag.current) return
    const hour = (document.elementFromPoint(x, y) as HTMLElement | null)?.dataset.hour
    if (hour != null) overPaint(Number(hour))
  }
  const painting = (hour: number) =>
    hover != null && hour >= Math.min(hover.from, hover.to) && hour <= Math.max(hover.from, hover.to)

  const hourSelect = (key: 'startMinute' | 'endMinute', label: string) => (
    <label className="col set-sched-f">
      <span className="lbl">{label}</span>
      <span className="field sm select">
        <select
          value={Math.floor(draft[key] / 60)}
          disabled={disabled}
          onChange={(e) => {
            const minute = Number(e.target.value) * 60
            edit(key === 'startMinute' ? { startMinute: minute } : { endMinute: minute })
          }}
        >
          {HOURS.map((h) => (
            <option key={h} value={h}>
              {fmtMinute(h * 60)}
            </option>
          ))}
        </select>
        <Icon name="chevronDown" size="s" />
      </span>
    </label>
  )

  return (
    <SettingsCard title={t('schedule.title')} icon="cal" wide className={`set-sched${draft.enabled ? '' : ' off'}`}>
      <div className="srow">
        <div className="sl">
          <b id={`${id}-on`}>{t('schedule.enabled')}</b>
          <span id={`${id}-ond`}>{t('schedule.subtitle')}</span>
        </div>
        <Switch
          checked={draft.enabled}
          disabled={disabled}
          labelledBy={`${id}-on`}
          describedBy={`${id}-ond`}
          onChange={(on) => edit({ enabled: on })}
        />
      </div>

      <div className="set-block">
        <div className="set-sched-ctl">
          {hourSelect('startMinute', t('schedule.from'))}
          {hourSelect('endMinute', t('schedule.to'))}
          <div className="col set-sched-f">
            <span className="lbl" aria-hidden="true">
              {t('schedule.profile')}
            </span>
            <Seg
              size="sm"
              className="set-wrap"
              label={t('schedule.profile')}
              value={draft.profile}
              options={[
                ...draft.profiles.map((p) => ({ value: p, label: p, disabled })),
                { value: '', label: t('schedule.profileKeep'), disabled },
              ]}
              onChange={(profile) => edit({ profile })}
            />
          </div>
          <span className="set-sched-sum small">
            <i className="set-swatch" style={{ background: color }} aria-hidden="true" />
            {allDay
              ? t('schedule.allDay')
              : t('schedule.window', { start: fmtMinute(draft.startMinute), end: fmtMinute(draft.endMinute) })}
          </span>
        </div>

        <div
          className="set-grid"
          role="grid"
          aria-label={t('schedule.title')}
          aria-readonly={disabled}
          style={{ '--sched-color': color } as CSSProperties}
          onPointerMove={(e) => movePaint(e.clientX, e.clientY)}
        >
          <div className="set-grid-row set-grid-hours" aria-hidden="true">
            <span />
            {HOURS.map((h) => (
              <span key={h}>{h % 3 === 0 ? String(h).padStart(2, '0') : ''}</span>
            ))}
          </div>
          {WEEK.map((day) => {
            const on = draft.days.includes(day)
            const dayName = t(dayKey(day))
            return (
              <div key={day} className="set-grid-row" role="row">
                <button
                  type="button"
                  role="rowheader"
                  className={`set-day${on ? ' on' : ''}`}
                  aria-pressed={on}
                  disabled={disabled}
                  onClick={() => edit({ days: toggleDay(draft.days, day) })}
                >
                  {dayName}
                </button>
                {HOURS.map((h) => {
                  const open = cellOpen(draft, day, h)
                  const label = t('schedule.hourLabel', { day: dayName, hour: String(h).padStart(2, '0') })
                  return (
                    <div
                      key={h}
                      role="gridcell"
                      aria-label={`${label}: ${open ? t('schedule.open') : t('schedule.closed')}`}
                      data-hour={h}
                      className={`set-cell${open ? ' open' : ''}${painting(h) ? ' paint' : ''}`}
                      onPointerDown={(e) => {
                        e.preventDefault()
                        startPaint(h)
                      }}
                    />
                  )
                })}
              </div>
            )
          })}
        </div>
        <p className="help">{t('schedule.hint')}</p>
      </div>

      {canWrite && (
        <DirtyStrip dirty={dirty} busy={busy} onDiscard={() => setDraft(saved)} onSave={() => void save()} />
      )}
    </SettingsCard>
  )
}
