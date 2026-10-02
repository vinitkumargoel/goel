import { useId, useState, type FormEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { operatorsFor, RULE_FIELDS, RULE_LIMITS, ruleProblems, withField, replaced, type RuleProblem } from '../../lib/rules'
import type { PortalRule, RuleCondition } from '../../lib/types'
import { FolderPicker } from '../add/FolderPicker'
import { Seg, Switch } from '../ui/Controls'
import { Icon } from '../ui/Icon'
import { Modal } from '../ui/Modal'

interface Props {
  /** The rule to edit, or a blank one for Add. */
  initial: PortalRule
  isNew: boolean
  onSave: (rule: PortalRule) => void
  onClose: () => void
  onWarn: (message: string) => void
}

type DoneKind = 'nothing' | 'open' | 'reveal' | 'moveTo'
const DONE_KINDS: readonly DoneKind[] = ['nothing', 'open', 'reveal', 'moveTo']
const PRIORITIES = ['high', 'normal', 'low'] as const

/** One select as the Studio draws it: a native control, so the keyboard and screen readers just work. */
function Select({ id, value, onChange, children }: { id: string; value: string; onChange: (v: string) => void; children: React.ReactNode }) {
  return (
    <div className="field sm select">
      <select id={id} value={value} onChange={(e) => onChange(e.target.value)}>
        {children}
      </select>
      <Icon name="chevronDown" size="s" />
    </div>
  )
}

/**
 * Add or edit one Download Rule, as the desktop editor lays it out: when these conditions match,
 * do this. It is a real form in the shared Modal, so focus is trapped, Escape closes and Enter saves.
 */
export function RuleEditor({ initial, isNew, onSave, onClose, onWarn }: Props) {
  const { t } = useTranslation()
  const id = useId()
  const [rule, setRule] = useState<PortalRule>(initial)
  const [speed, setSpeed] = useState(initial.speedLimitBytesPerSec ? String(Math.round(initial.speedLimitBytesPerSec / 1000)) : '')
  const [picking, setPicking] = useState<'folder' | 'moveTo' | null>(null)
  const [tried, setTried] = useState(false)

  const locked = rule.whenDone?.locked === true
  const speedKB = speed.trim() === '' ? 0 : Number(speed)
  const speedBad = !Number.isInteger(speedKB) || speedKB < 0 || speedKB > RULE_LIMITS.speedKBps
  const candidate: PortalRule = { ...rule, speedLimitBytesPerSec: speedBad ? 0 : speedKB * 1000 }
  const problems = ruleProblems(candidate)
  const shown = (p: RuleProblem) => tried && problems.includes(p)
  const patch = (p: Partial<PortalRule>) => setRule((r) => ({ ...r, ...p }))
  const editCondition = (i: number, next: RuleCondition) => patch({ conditions: [...replaced(rule.conditions, i, next)] })
  const doneKind: DoneKind = locked ? 'nothing' : ((rule.whenDone?.kind as DoneKind | undefined) ?? 'nothing')

  const submit = (e: FormEvent) => {
    e.preventDefault()
    setTried(true)
    if (problems.length > 0 || speedBad) return
    onSave({
      ...candidate,
      name: rule.name.trim(),
      folder: rule.folder?.trim() || null,
      tag: rule.tag?.trim() || null,
      speedLimitBytesPerSec: speedKB > 0 ? speedKB * 1000 : null,
      priority: rule.priority === 'normal' ? null : (rule.priority ?? null),
    })
  }

  return (
    <>
      <Modal labelledBy={`${id}-title`} onClose={onClose} scrimCloses={false} trap={picking == null} width={600} className="qd rule-ed">
        <form className="qd-form" onSubmit={submit} noValidate>
          <div className="sheet-h">
            <span className="qd-ic">
              <Icon name="filter" />
            </span>
            <div className="col qd-titles">
              <h2 className="h2" id={`${id}-title`}>
                {isNew ? t('rules.editor.addTitle') : t('rules.editor.editTitle')}
              </h2>
              <span className="small muted">{t('rules.editor.subtitle')}</span>
            </div>
          </div>

          <div className="sheet-b rule-body">
            <div className="col rule-f">
              <label htmlFor={`${id}-name`}>
                <b>{t('rules.editor.name')}</b>
              </label>
              <span className="field sm">
                <input
                  id={`${id}-name`}
                  value={rule.name}
                  maxLength={RULE_LIMITS.name}
                  aria-invalid={shown('name')}
                  onChange={(e) => patch({ name: e.target.value })}
                />
              </span>
              {shown('name') && (
                <span className="help bad" role="alert">
                  {t('rules.editor.nameInvalid')}
                </span>
              )}
            </div>

            <fieldset className="rule-set">
              <legend>
                <b>{t('rules.editor.when')}</b>
              </legend>
              <div className="row rule-match">
                <Seg
                  size="sm"
                  label={t('rules.editor.matchLabel')}
                  value={rule.match}
                  options={(['all', 'any'] as const).map((value) => ({ value, label: t(`rules.match.${value}`) }))}
                  onChange={(match) => patch({ match })}
                />
                <span className="small muted">{t('rules.editor.ofThese')}</span>
              </div>
              {rule.conditions.map((c, i) => (
                <div className="rule-cond" key={i} role="group" aria-label={t('rules.editor.conditionN', { n: i + 1 })}>
                  <Select
                    id={`${id}-f${i}`}
                    value={c.field}
                    onChange={(v) => editCondition(i, withField(c, v as RuleCondition['field']))}
                  >
                    {RULE_FIELDS.map((f) => (
                      <option key={f} value={f}>
                        {t(`rules.fields.${f}`)}
                      </option>
                    ))}
                  </Select>
                  <Select id={`${id}-o${i}`} value={c.op} onChange={(v) => editCondition(i, { ...c, op: v as RuleCondition['op'] })}>
                    {operatorsFor(c.field).map((o) => (
                      <option key={o} value={o}>
                        {t(`rules.ops.${o}`)}
                      </option>
                    ))}
                  </Select>
                  <span className="field sm rule-val">
                    <input
                      className="mono"
                      value={c.value}
                      maxLength={RULE_LIMITS.value}
                      spellCheck={false}
                      aria-label={t('rules.editor.valueN', { n: i + 1 })}
                      aria-invalid={shown('condition') && c.value.trim() === ''}
                      placeholder={c.field === 'size' ? t('rules.editor.sizeHint') : undefined}
                      onChange={(e) => editCondition(i, { ...c, value: e.target.value })}
                    />
                  </span>
                  <button
                    type="button"
                    className="btn sm ghost icon"
                    aria-label={t('rules.editor.removeCondition', { n: i + 1 })}
                    disabled={rule.conditions.length <= 1}
                    onClick={() => patch({ conditions: rule.conditions.filter((_, j) => j !== i) })}
                  >
                    <Icon name="minus" size="s" />
                  </button>
                </div>
              ))}
              {(shown('condition') || shown('size')) && (
                <span className="help bad" role="alert">
                  {shown('size') ? t('rules.editor.sizeInvalid') : t('rules.editor.conditionInvalid')}
                </span>
              )}
              <button
                type="button"
                className="btn sm"
                disabled={rule.conditions.length >= RULE_LIMITS.conditions}
                onClick={() => patch({ conditions: [...rule.conditions, { field: 'fileName', op: 'contains', value: '' }] })}
              >
                <Icon name="plus" size="s" />
                {t('rules.editor.addCondition')}
              </button>
            </fieldset>

            <fieldset className="rule-set">
              <legend>
                <b>{t('rules.editor.then')}</b>
              </legend>
              <div className="col rule-f">
                <label htmlFor={`${id}-folder`}>
                  <b>{t('rules.editor.folder')}</b>
                </label>
                <div className="row">
                  <span className="field sm grow">
                    <input
                      id={`${id}-folder`}
                      className="mono"
                      value={rule.folder ?? ''}
                      placeholder={t('rules.editor.folderDefault')}
                      spellCheck={false}
                      aria-invalid={shown('folder')}
                      onChange={(e) => patch({ folder: e.target.value })}
                    />
                  </span>
                  <button type="button" className="btn sm" onClick={() => setPicking('folder')}>
                    <Icon name="folder" size="s" />
                    {t('settings.general.choose')}
                  </button>
                </div>
                {shown('folder') && (
                  <span className="help bad" role="alert">
                    {t('settings.general.folderInvalid')}
                  </span>
                )}
              </div>

              <div className="rule-grid">
                <label className="col rule-f" htmlFor={`${id}-tag`}>
                  <b>{t('rules.editor.tag')}</b>
                  <span className="field sm">
                    <input
                      id={`${id}-tag`}
                      value={rule.tag ?? ''}
                      maxLength={RULE_LIMITS.tag}
                      placeholder={t('rules.editor.none')}
                      onChange={(e) => patch({ tag: e.target.value })}
                    />
                  </span>
                </label>
                <div className="col rule-f">
                  <label htmlFor={`${id}-speed`}>
                    <b>{t('rules.editor.speed')}</b>
                  </label>
                  <span className="field sm">
                    <input
                      id={`${id}-speed`}
                      className="mono"
                      inputMode="numeric"
                      value={speed}
                      placeholder={t('rules.editor.noCap')}
                      aria-invalid={speedBad}
                      onChange={(e) => setSpeed(e.target.value)}
                    />
                  </span>
                  {speedBad && (
                    <span className="help bad" role="alert">
                      {t('rules.editor.speedInvalid')}
                    </span>
                  )}
                </div>
              </div>

              <div className="row rule-opts">
                <Seg
                  size="sm"
                  label={t('rules.editor.priority')}
                  value={rule.priority ?? 'normal'}
                  options={PRIORITIES.map((value) => ({ value, label: t(`rules.priority.${value}`) }))}
                  onChange={(priority) => patch({ priority })}
                />
                <span className="row">
                  <Switch
                    checked={rule.startPaused}
                    labelledBy={`${id}-paused`}
                    onChange={(startPaused) => patch({ startPaused })}
                  />
                  <span id={`${id}-paused`}>{t('rules.editor.startPaused')}</span>
                </span>
              </div>

              {locked ? (
                <p className="small muted" role="note">
                  {t('rules.editor.doneLocked')}
                </p>
              ) : (
                <div className="col rule-f">
                  <label htmlFor={`${id}-done`}>
                    <b>{t('rules.editor.done')}</b>
                  </label>
                  <Select
                    id={`${id}-done`}
                    value={doneKind}
                    onChange={(kind) =>
                      patch({ whenDone: kind === 'nothing' ? null : { kind: kind as DoneKind, target: kind === 'moveTo' ? (rule.whenDone?.target ?? '') : null } })
                    }
                  >
                    {DONE_KINDS.map((k) => (
                      <option key={k} value={k}>
                        {t(`rules.done.${k}`)}
                      </option>
                    ))}
                  </Select>
                  {doneKind === 'moveTo' && (
                    <div className="row">
                      <span className="field sm grow">
                        <input
                          className="mono"
                          value={rule.whenDone?.target ?? ''}
                          aria-label={t('rules.editor.moveTarget')}
                          aria-invalid={shown('moveTo')}
                          spellCheck={false}
                          onChange={(e) => patch({ whenDone: { kind: 'moveTo', target: e.target.value } })}
                        />
                      </span>
                      <button type="button" className="btn sm" onClick={() => setPicking('moveTo')}>
                        <Icon name="folder" size="s" />
                        {t('settings.general.choose')}
                      </button>
                    </div>
                  )}
                  {shown('moveTo') && (
                    <span className="help bad" role="alert">
                      {t('settings.general.folderInvalid')}
                    </span>
                  )}
                </div>
              )}
              {shown('action') && (
                <span className="help bad" role="alert">
                  {t('rules.editor.actionInvalid')}
                </span>
              )}
            </fieldset>
          </div>

          <div className="sheet-f">
            <span className="sp" />
            <button type="button" className="btn" onClick={onClose}>
              {t('common.cancel')}
            </button>
            <button type="submit" className="btn pri">
              {t('rules.editor.save')}
            </button>
          </div>
        </form>
      </Modal>
      {picking && (
        <FolderPicker
          initialPath={(picking === 'folder' ? rule.folder : rule.whenDone?.target) ?? ''}
          canCreate
          onWarn={onWarn}
          onClose={() => setPicking(null)}
          onPick={(path) => {
            if (picking === 'folder') patch({ folder: path })
            else patch({ whenDone: { kind: 'moveTo', target: path } })
            setPicking(null)
          }}
        />
      )}
    </>
  )
}
