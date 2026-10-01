import { useEffect, useRef, useState, type CSSProperties } from 'react'
import { useTranslation } from 'react-i18next'
import type { ToastTone } from '../hooks/useToasts'
import { api, ApiError, failureMessage } from '../lib/api'
import {
  cellOpen,
  fmtMinute,
  HOURS,
  paintRange,
  profileColor,
  sameSchedule,
  toggleDay,
  WEEK,
} from '../lib/schedule'
import type { ScheduleState } from '../lib/types'
import { DirtyStrip } from './SettingsParts'

type Load = { status: 'loading' } | { status: 'unsupported' } | { status: 'error' } | { status: 'ready'; saved: ScheduleState }

/**
 * Settings › Server › Schedule: the one download window the Mac's scheduler runs, painted on a
 * week × hour grid in the colour of the profile it switches to. Edits collect in a draft and go to
 * the server on Save, like the other server cards.
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
        // A daemon without a scheduler (the Linux service) answers 404: the card stays away.
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
    return () => window.removeEventListener('pointerup', end)
  }, [])

  if (load.status === 'unsupported' || load.status === 'loading') return null
  if (load.status === 'error' || !draft || !saved) {
    return (
      <div className="card pd">
        <div className="sname">{t('schedule.title')}</div>
        <div className="sdesc">{t('api.actionFailed')}</div>
      </div>
    )
  }

  const edit = (patch: Partial<ScheduleState>) => setDraft((d) => (d ? { ...d, ...patch } : d))
  const color = profileColor(draft.profile, draft.profiles)
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

  return (
    <div className={`card pd sched${draft.enabled ? '' : ' off'}`}>
      <label className="srow" style={{ cursor: disabled ? 'default' : 'pointer' }}>
        <div className="sinfo">
          <div className="sname">{t('schedule.title')}</div>
          <div className="sdesc">{t('schedule.subtitle')}</div>
        </div>
        <div className="sctl">
          <input
            type="checkbox"
            aria-label={t('schedule.enabled')}
            checked={draft.enabled}
            disabled={disabled}
            onChange={(e) => edit({ enabled: e.target.checked })}
          />
        </div>
      </label>

      <div className="sched-controls">
        <label>
          <span className="flabel">{t('schedule.from')}</span>
          <select
            className="finput hkind"
            value={Math.floor(draft.startMinute / 60)}
            disabled={disabled}
            onChange={(e) => edit({ startMinute: Number(e.target.value) * 60 })}
          >
            {HOURS.map((h) => (
              <option key={h} value={h}>
                {fmtMinute(h * 60)}
              </option>
            ))}
          </select>
        </label>
        <label>
          <span className="flabel">{t('schedule.to')}</span>
          <select
            className="finput hkind"
            value={Math.floor(draft.endMinute / 60)}
            disabled={disabled}
            onChange={(e) => edit({ endMinute: Number(e.target.value) * 60 })}
          >
            {HOURS.map((h) => (
              <option key={h} value={h}>
                {fmtMinute(h * 60)}
              </option>
            ))}
          </select>
        </label>
        <label>
          <span className="flabel">{t('schedule.profile')}</span>
          <select
            className="finput hkind"
            value={draft.profile}
            disabled={disabled}
            onChange={(e) => edit({ profile: e.target.value })}
          >
            <option value="">{t('schedule.profileKeep')}</option>
            {draft.profiles.map((p) => (
              <option key={p} value={p}>
                {p}
              </option>
            ))}
          </select>
        </label>
        <span className="sched-sum">
          <i className="sched-swatch" style={{ background: color }} aria-hidden="true" />
          {allDay
            ? t('schedule.allDay')
            : t('schedule.window', { start: fmtMinute(draft.startMinute), end: fmtMinute(draft.endMinute) })}
        </span>
      </div>

      <div
        className="sched-grid"
        role="grid"
        aria-label={t('schedule.title')}
        aria-readonly={disabled}
        style={{ '--sched-color': color } as CSSProperties}
        onPointerMove={(e) => movePaint(e.clientX, e.clientY)}
      >
        <div className="sched-corner" aria-hidden="true" />
        {HOURS.map((h) => (
          <div key={h} className="sched-hour" aria-hidden="true">
            {h % 3 === 0 ? String(h).padStart(2, '0') : ''}
          </div>
        ))}
        {WEEK.map((day) => {
          const on = draft.days.includes(day)
          return (
            <div key={day} className="sched-row" role="row">
              <button
                type="button"
                role="rowheader"
                className={`sched-day${on ? ' on' : ''}`}
                aria-pressed={on}
                disabled={disabled}
                onClick={() => edit({ days: toggleDay(draft.days, day) })}
              >
                {t(`schedule.days.${day}` as 'schedule.days.1')}
              </button>
              {HOURS.map((h) => {
                const open = cellOpen(draft, day, h)
                const label = t('schedule.hourLabel', {
                  day: t(`schedule.days.${day}` as 'schedule.days.1'),
                  hour: String(h).padStart(2, '0'),
                })
                return (
                  <div
                    key={h}
                    role="gridcell"
                    aria-label={`${label}: ${open ? t('schedule.open') : t('schedule.closed')}`}
                    data-hour={h}
                    className={`sched-cell${open ? ' open' : ''}${painting(h) ? ' paint' : ''}`}
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
      <p className="fhint">{t('schedule.hint')}</p>

      {canWrite && (
        <DirtyStrip
          dirty={dirty}
          busy={busy}
          onDiscard={() => setDraft(saved)}
          onSave={() => void save()}
        />
      )}
    </div>
  )
}
