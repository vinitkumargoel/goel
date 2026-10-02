import { useId, useState, type FormEvent, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { fmtAbsolute } from '../../lib/format'
import {
  allTags,
  fromLocalInput,
  nextAt,
  parseRate,
  parseTags,
  rateParts,
  toLocalInput,
  type RateUnit,
} from '../../lib/queueControls'
import type { TaskRow } from '../../lib/types'
import { Seg } from '../ui/Controls'
import { Icon, type IconName } from '../ui/Icon'
import { Modal } from '../ui/Modal'

/** The small editors a row menu, the detail sheet and the status bar open. */
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
      return <SpeedDialog task={edit.task} onClose={onClose} onSave={(bps) => handlers.onSpeed(edit.task, bps)} />
    case 'tags':
      return (
        <TagsDialog task={edit.task} tasks={tasks} onClose={onClose} onSave={(tags) => handlers.onTags(edit.task, tags)} />
      )
    case 'start':
      return <StartDialog task={edit.task} onClose={onClose} onSave={(at) => handlers.onStart(edit.task, at)} />
    case 'cap':
      return <CapDialog down={edit.down} up={edit.up} onClose={onClose} onSave={edit.onSave} />
  }
}

interface ShellProps {
  title: string
  icon: IconName
  /** The download it edits. */
  subtitle?: string
  onClose: () => void
  onSubmit: () => void
  submitLabel: string
  canSubmit?: boolean
  /** A secondary action at the start of the footer. */
  extra?: ReactNode
  children: ReactNode
}

/** A small sheet with a form: Enter saves, then closes; Escape or Cancel closes without saving. */
function Shell({ title, icon, subtitle, onClose, onSubmit, submitLabel, canSubmit = true, extra, children }: ShellProps) {
  const { t } = useTranslation()
  const titleId = useId()
  const submit = (e: FormEvent) => {
    e.preventDefault()
    if (!canSubmit) return
    onClose()
    onSubmit()
  }
  return (
    <Modal labelledBy={titleId} onClose={onClose} width={420} className="qd">
      <form className="qd-form" onSubmit={submit}>
        <div className="sheet-h">
          <span className="qd-ic">
            <Icon name={icon} />
          </span>
          <div className="col qd-titles">
            <h2 className="h2" id={titleId}>
              {title}
            </h2>
            {subtitle && (
              <span className="small muted ell" title={subtitle}>
                {subtitle}
              </span>
            )}
          </div>
        </div>
        <div className="sheet-b">{children}</div>
        <div className="sheet-f">
          {extra}
          <span className="sp" />
          <button type="button" className="btn" onClick={onClose}>
            {t('common.cancel')}
          </button>
          <button type="submit" className="btn pri" disabled={!canSubmit}>
            {submitLabel}
          </button>
        </div>
      </form>
    </Modal>
  )
}

interface RateFieldProps {
  label: string
  value: string
  unit: RateUnit
  onValue: (v: string) => void
  onUnit: (u: RateUnit) => void
  invalid: boolean
  autoFocus?: boolean
}

/** A rate as a number and a KB/s · MB/s switch; empty or 0 is no limit. */
function RateField({ label, value, unit, onValue, onUnit, invalid, autoFocus = false }: RateFieldProps) {
  const { t } = useTranslation()
  const id = useId()
  return (
    <div className="col qd-rate">
      <label className="lbl" htmlFor={id}>
        {label}
      </label>
      <div className="row qd-rate-row">
        <div className={`field${invalid ? ' invalid' : ''}`}>
          <input
            id={id}
            className="mono"
            inputMode="decimal"
            value={value}
            placeholder={t('queue.unlimited')}
            aria-invalid={invalid}
            autoFocus={autoFocus}
            onChange={(e) => onValue(e.target.value)}
          />
        </div>
        <Seg<RateUnit>
          value={unit}
          label={t('queue.unit')}
          onChange={onUnit}
          options={[
            { value: 'KB', label: 'KB/s' },
            { value: 'MB', label: 'MB/s' },
          ]}
        />
      </div>
    </div>
  )
}

function SpeedDialog({ task, onClose, onSave }: { task: TaskRow; onClose: () => void; onSave: (bps: number | null) => void }) {
  const { t } = useTranslation()
  const initial = rateParts(task.speedLimit)
  const [value, setValue] = useState(initial.value)
  const [unit, setUnit] = useState<RateUnit>(initial.unit)
  const parsed = parseRate(value, unit)
  return (
    <Shell
      title={t('queue.speedTitle')}
      icon="gauge"
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
      <p className="help">{t('queue.speedHint')}</p>
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
      icon="gauge"
      onClose={onClose}
      onSubmit={() => onSave(dp ?? null, upv ?? null)}
      submitLabel={t('common.save')}
      canSubmit={dp !== undefined && upv !== undefined}
    >
      <RateField label={`↓ ${t('chart.down')}`} value={dv} unit={du} onValue={setDv} onUnit={setDu} invalid={dp === undefined} autoFocus />
      <RateField label={`↑ ${t('chart.up')}`} value={uv} unit={uu} onValue={setUv} onUnit={setUu} invalid={upv === undefined} />
      <p className="help">{t('queue.capHint')}</p>
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
      icon="tag"
      subtitle={task.name}
      onClose={onClose}
      onSubmit={() => onSave(current)}
      submitLabel={t('common.save')}
    >
      <div className="col qd-group">
        <label className="lbl" htmlFor={id}>
          {t('queue.tagsLabel')}
        </label>
        <div className="field">
          <input
            id={id}
            value={text}
            placeholder={t('queue.tagsPlaceholder')}
            autoFocus
            onChange={(e) => setText(e.target.value)}
          />
        </div>
      </div>
      {current.length > 0 && (
        <div className="qd-tags" role="group" aria-label={t('queue.tagsCurrent')}>
          {current.map((tag) => (
            <button
              key={tag}
              type="button"
              className="chip on"
              aria-label={t('queue.tagRemove', { tag })}
              onClick={() => setText(current.filter((x) => x !== tag).join(', '))}
            >
              {tag}
              <Icon name="x" size="s" />
            </button>
          ))}
        </div>
      )}
      {suggestions.length > 0 && (
        <div className="col qd-group">
          <span className="eyebrow">{t('queue.tagsSuggested')}</span>
          <div className="qd-tags">
            {suggestions.map((tag) => (
              <button key={tag} type="button" className="chip" onClick={() => setText([...current, tag].join(', '))}>
                <Icon name="plus" size="s" />
                {tag}
              </button>
            ))}
          </div>
        </div>
      )}
    </Shell>
  )
}

function StartDialog({ task, onClose, onSave }: { task: TaskRow; onClose: () => void; onSave: (at: Date | null) => void }) {
  const { t } = useTranslation()
  return (
    <StartPicker
      initial={task.startAt ? new Date(task.startAt * 1000) : null}
      render={(picker, at, valid) => (
        <Shell
          title={t('queue.startTitle')}
          icon="clock"
          subtitle={task.name}
          onClose={onClose}
          onSubmit={() => onSave(at)}
          submitLabel={t('common.save')}
          canSubmit={valid}
        >
          {picker}
          {task.startAt ? <p className="help">{t('queue.startCurrent', { when: fmtAbsolute(task.startAt) })}</p> : null}
        </Shell>
      )}
    />
  )
}

type StartChoice = 'now' | 'tonight' | 'custom'

/** A custom start counts while it is no more than a minute in the past. */
function usable(d: Date | null): d is Date {
  return d != null && d.getTime() > Date.now() - 60_000
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
  const [choice, setChoice] = useState<StartChoice>(initial ? 'custom' : 'now')
  const [custom, setCustom] = useState(() => toLocalInput(initial ?? nextAt(new Date().getHours() + 1)))
  const tonight = nextAt(1)
  const customDate = fromLocalInput(custom)
  const customValid = usable(customDate)
  const at = choice === 'now' ? null : choice === 'tonight' ? tonight : customDate
  const valid = choice !== 'custom' || customValid

  const pick = (next: StartChoice, nextCustom = custom) => {
    setChoice(next)
    setCustom(nextCustom)
    if (!onChange) return
    const d = fromLocalInput(nextCustom)
    onChange(next === 'now' ? null : next === 'tonight' ? tonight : d, next !== 'custom' || usable(d))
  }

  const picker = (
    <div className="col qd-start">
      <Seg<StartChoice>
        value={choice}
        label={t('queue.startLabel')}
        onChange={(c) => pick(c)}
        full
        options={[
          { value: 'now', label: t('queue.startNow') },
          { value: 'tonight', label: t('queue.startTonight', { time: '01:00' }) },
          { value: 'custom', label: t('queue.startCustom') },
        ]}
      />
      {choice === 'custom' && (
        <div className={`field${customValid ? '' : ' invalid'}`}>
          <Icon name="cal" size="s" className="faint" />
          <input
            type="datetime-local"
            value={custom}
            aria-label={t('queue.startCustom')}
            aria-invalid={!customValid}
            onChange={(e) => pick('custom', e.target.value)}
          />
        </div>
      )}
    </div>
  )
  return <>{render ? render(picker, at, valid) : picker}</>
}
