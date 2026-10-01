import { useId, useRef, useState, type FormEvent, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { useDialogFocus } from '../hooks/useDialogFocus'
import { fmtAbsolute } from '../lib/format'
import {
  allTags,
  fromLocalInput,
  nextAt,
  parseRate,
  parseTags,
  rateParts,
  toLocalInput,
  type RateUnit,
} from '../lib/queueControls'
import type { TaskRow } from '../lib/types'

/** The small editors a row menu, the detail panel and the status bar open. */
export type QueueEdit =
  | { kind: 'speed'; task: TaskRow }
  | { kind: 'tags'; task: TaskRow }
  | { kind: 'start'; task: TaskRow }
  | {
      kind: 'cap'
      down: number | null
      up: number | null
      onSave: (down: number | null, up: number | null) => void
    }

export interface QueueDialogHandlers {
  onSpeed: (task: TaskRow, bytesPerSec: number | null) => void
  onTags: (task: TaskRow, tags: string[]) => void
  onStart: (task: TaskRow, at: Date | null) => void
}

export function QueueDialog({
  edit,
  tasks,
  onClose,
  handlers,
}: {
  edit: QueueEdit | null
  tasks: readonly TaskRow[]
  onClose: () => void
  handlers: QueueDialogHandlers
}) {
  if (!edit) return null
  switch (edit.kind) {
    case 'speed':
      return (
        <SpeedDialog
          task={edit.task}
          onClose={onClose}
          onSave={(bps) => handlers.onSpeed(edit.task, bps)}
        />
      )
    case 'tags':
      return (
        <TagsDialog
          task={edit.task}
          tasks={tasks}
          onClose={onClose}
          onSave={(tags) => handlers.onTags(edit.task, tags)}
        />
      )
    case 'start':
      return (
        <StartDialog task={edit.task} onClose={onClose} onSave={(at) => handlers.onStart(edit.task, at)} />
      )
    case 'cap':
      return <CapDialog down={edit.down} up={edit.up} onClose={onClose} onSave={edit.onSave} />
  }
}

function Shell({
  title,
  subtitle,
  onClose,
  onSubmit,
  submitLabel,
  canSubmit = true,
  extra,
  children,
}: {
  title: string
  subtitle?: string
  onClose: () => void
  onSubmit: () => void
  submitLabel: string
  canSubmit?: boolean
  extra?: ReactNode
  children: ReactNode
}) {
  const { t } = useTranslation()
  const ref = useRef<HTMLFormElement>(null)
  const titleId = useId()
  useDialogFocus(ref, { onEscape: onClose })
  const submit = (e: FormEvent) => {
    e.preventDefault()
    if (!canSubmit) return
    onClose()
    onSubmit()
  }
  return (
    <div
      className="scrim open"
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose()
      }}
    >
      <form className="modal qdialog" ref={ref} role="dialog" aria-modal="true" aria-labelledby={titleId} onSubmit={submit}>
        <div className="mhead">
          <h3 id={titleId}>{title}</h3>
        </div>
        <div className="mbody">
          {subtitle && (
            <p className="qsub ell" title={subtitle}>
              {subtitle}
            </p>
          )}
          {children}
        </div>
        <div className="mfoot">
          {extra}
          <span className="sp" />
          <button type="button" className="btn" onClick={onClose}>
            {t('common.cancel')}
          </button>
          <button type="submit" className="btn primary" disabled={!canSubmit}>
            {submitLabel}
          </button>
        </div>
      </form>
    </div>
  )
}

function RateField({
  label,
  value,
  unit,
  onValue,
  onUnit,
  invalid,
  autoFocus = false,
}: {
  label: string
  value: string
  unit: RateUnit
  onValue: (v: string) => void
  onUnit: (u: RateUnit) => void
  invalid: boolean
  autoFocus?: boolean
}) {
  const { t } = useTranslation()
  const id = useId()
  return (
    <div className="qrate">
      <label className="flabel" htmlFor={id}>
        {label}
      </label>
      <div className="qrate-row">
        <input
          id={id}
          className="finput"
          inputMode="decimal"
          value={value}
          placeholder={t('queue.unlimited')}
          aria-invalid={invalid}
          autoFocus={autoFocus}
          onChange={(e) => onValue(e.target.value)}
        />
        <select
          className="finput"
          value={unit}
          aria-label={t('queue.unit')}
          onChange={(e) => onUnit(e.target.value as RateUnit)}
        >
          <option value="KB">KB/s</option>
          <option value="MB">MB/s</option>
        </select>
      </div>
    </div>
  )
}

function SpeedDialog({
  task,
  onClose,
  onSave,
}: {
  task: TaskRow
  onClose: () => void
  onSave: (bytesPerSec: number | null) => void
}) {
  const { t } = useTranslation()
  const initial = rateParts(task.speedLimit)
  const [value, setValue] = useState(initial.value)
  const [unit, setUnit] = useState<RateUnit>(initial.unit)
  const parsed = parseRate(value, unit)
  return (
    <Shell
      title={t('queue.speedTitle')}
      subtitle={task.name}
      onClose={onClose}
      onSubmit={() => onSave(parsed ?? null)}
      submitLabel={t('common.save')}
      canSubmit={parsed !== undefined}
      extra={
        task.speedLimit ? (
          <button
            type="button"
            className="btn ghost"
            onClick={() => {
              onClose()
              onSave(null)
            }}
          >
            {t('queue.noLimit')}
          </button>
        ) : undefined
      }
    >
      <RateField
        label={t('queue.speedLabel')}
        value={value}
        unit={unit}
        onValue={setValue}
        onUnit={setUnit}
        invalid={parsed === undefined}
        autoFocus
      />
      <p className="fhint">{t('queue.speedHint')}</p>
    </Shell>
  )
}

function CapDialog({
  down,
  up,
  onClose,
  onSave,
}: {
  down: number | null
  up: number | null
  onClose: () => void
  onSave: (down: number | null, up: number | null) => void
}) {
  const { t } = useTranslation()
  const d0 = rateParts(down)
  const u0 = rateParts(up)
  const [dv, setDv] = useState(d0.value)
  const [du, setDu] = useState<RateUnit>(d0.unit)
  const [uv, setUv] = useState(u0.value)
  const [uu, setUu] = useState<RateUnit>(u0.unit)
  const dp = parseRate(dv, du)
  const upv = parseRate(uv, uu)
  return (
    <Shell
      title={t('queue.capTitle')}
      onClose={onClose}
      onSubmit={() => onSave(dp ?? null, upv ?? null)}
      submitLabel={t('common.save')}
      canSubmit={dp !== undefined && upv !== undefined}
    >
      <div className="qcap">
        <RateField label={`↓ ${t('chart.down')}`} value={dv} unit={du} onValue={setDv} onUnit={setDu} invalid={dp === undefined} autoFocus />
        <RateField label={`↑ ${t('chart.up')}`} value={uv} unit={uu} onValue={setUv} onUnit={setUu} invalid={upv === undefined} />
      </div>
      <p className="fhint">{t('queue.capHint')}</p>
    </Shell>
  )
}

function TagsDialog({
  task,
  tasks,
  onClose,
  onSave,
}: {
  task: TaskRow
  tasks: readonly TaskRow[]
  onClose: () => void
  onSave: (tags: string[]) => void
}) {
  const { t } = useTranslation()
  const id = useId()
  const [text, setText] = useState((task.tags ?? []).join(', '))
  const current = parseTags(text)
  const keys = new Set(current.map((x) => x.toLowerCase()))
  const suggestions = allTags(tasks)
    .map((x) => x.tag)
    .filter((tag) => !keys.has(tag.toLowerCase()))
    .slice(0, 12)
  return (
    <Shell
      title={t('queue.tagsTitle')}
      subtitle={task.name}
      onClose={onClose}
      onSubmit={() => onSave(current)}
      submitLabel={t('common.save')}
    >
      <label className="flabel" htmlFor={id}>
        {t('queue.tagsLabel')}
      </label>
      <input
        id={id}
        className="finput"
        value={text}
        placeholder={t('queue.tagsPlaceholder')}
        autoFocus
        onChange={(e) => setText(e.target.value)}
      />
      {current.length > 0 && (
        <div className="qtags" aria-label={t('queue.tagsCurrent')}>
          {current.map((tag) => (
            <button
              key={tag}
              type="button"
              className="qtag on"
              aria-label={t('queue.tagRemove', { tag })}
              onClick={() => setText(current.filter((x) => x !== tag).join(', '))}
            >
              {tag} ×
            </button>
          ))}
        </div>
      )}
      {suggestions.length > 0 && (
        <>
          <div className="flabel qsugg">{t('queue.tagsSuggested')}</div>
          <div className="qtags">
            {suggestions.map((tag) => (
              <button
                key={tag}
                type="button"
                className="qtag"
                onClick={() => setText([...current, tag].join(', '))}
              >
                + {tag}
              </button>
            ))}
          </div>
        </>
      )}
    </Shell>
  )
}

type StartChoice = 'now' | 'tonight' | 'custom'

function StartDialog({
  task,
  onClose,
  onSave,
}: {
  task: TaskRow
  onClose: () => void
  onSave: (at: Date | null) => void
}) {
  const { t } = useTranslation()
  return (
    <StartPicker
      initial={task.startAt ? new Date(task.startAt * 1000) : null}
      render={(picker, at, valid) => (
        <Shell
          title={t('queue.startTitle')}
          subtitle={task.name}
          onClose={onClose}
          onSubmit={() => onSave(at)}
          submitLabel={t('common.save')}
          canSubmit={valid}
        >
          {picker}
          {task.startAt ? (
            <p className="fhint">{t('queue.startCurrent', { when: fmtAbsolute(task.startAt) })}</p>
          ) : null}
        </Shell>
      )}
    />
  )
}

/**
 * "Start at: Now / Tonight 01:00 / Custom" — the Add dialog uses it too. `render` gets the picker,
 * the chosen time (null = now) and whether a custom time is usable.
 */
export function StartPicker({
  initial,
  render,
  onChange,
}: {
  initial: Date | null
  render?: (picker: ReactNode, at: Date | null, valid: boolean) => ReactNode
  onChange?: (at: Date | null, valid: boolean) => void
}) {
  const { t } = useTranslation()
  const name = useId()
  const [choice, setChoice] = useState<StartChoice>(initial ? 'custom' : 'now')
  const [custom, setCustom] = useState(() => toLocalInput(initial ?? nextAt(new Date().getHours() + 1)))
  const tonight = nextAt(1)
  const customDate = fromLocalInput(custom)
  const customValid = customDate != null && customDate.getTime() > Date.now() - 60_000
  const at = choice === 'now' ? null : choice === 'tonight' ? tonight : customDate
  const valid = choice !== 'custom' || customValid

  const pick = (next: StartChoice, nextCustom = custom) => {
    setChoice(next)
    setCustom(nextCustom)
    if (!onChange) return
    const d = fromLocalInput(nextCustom)
    const ok = next !== 'custom' || (d != null && d.getTime() > Date.now() - 60_000)
    onChange(next === 'now' ? null : next === 'tonight' ? tonight : d, ok)
  }

  const picker = (
    <div className="qstart" role="radiogroup" aria-label={t('queue.startLabel')}>
      {(['now', 'tonight', 'custom'] as const).map((c) => (
        <label key={c} className={`qopt${choice === c ? ' on' : ''}`}>
          <input type="radio" name={name} checked={choice === c} onChange={() => pick(c)} />
          {c === 'now'
            ? t('queue.startNow')
            : c === 'tonight'
              ? t('queue.startTonight', { time: '01:00' })
              : t('queue.startCustom')}
        </label>
      ))}
      {choice === 'custom' && (
        <input
          type="datetime-local"
          className="finput"
          value={custom}
          aria-label={t('queue.startCustom')}
          aria-invalid={!customValid}
          onChange={(e) => pick('custom', e.target.value)}
        />
      )}
    </div>
  )
  return <>{render ? render(picker, at, valid) : picker}</>
}
