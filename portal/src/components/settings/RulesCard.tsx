import { useEffect, useId, useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { ToastTone } from '../../hooks/useToasts'
import { api, ApiError, failureMessage } from '../../lib/api'
import { blankRule, moved, toWire } from '../../lib/rules'
import type { PortalRule } from '../../lib/types'
import { ConfirmDialog, type ConfirmRequest } from '../dialogs/ConfirmDialog'
import { Switch } from '../ui/Controls'
import { Icon } from '../ui/Icon'
import { RuleEditor } from './RuleEditor'
import { Pill, SettingsCard } from './SettingsParts'

type Load = { status: 'loading' } | { status: 'unsupported' } | { status: 'error' } | { status: 'ready' }
type Editing = { index: number | null; rule: PortalRule }

interface Props {
  canWrite: boolean
  onToast: (message: string, tone?: ToastTone) => void
}

/**
 * Settings › Download Rules: the auto-sort rules the desktop app edits, checked in this order with
 * the first enabled match winning. Every change (add, edit, enable, reorder, delete) saves the whole
 * list at once and shows what the server stored, so the portal never shows a rule that did not save.
 * A server without editable rules (404) shows nothing.
 */
export function RulesCard({ canWrite, onToast }: Props) {
  const { t } = useTranslation()
  const id = useId()
  const [load, setLoad] = useState<Load>({ status: 'loading' })
  const [rules, setRules] = useState<readonly PortalRule[]>([])
  const [busy, setBusy] = useState(false)
  const [editing, setEditing] = useState<Editing | null>(null)
  const [confirm, setConfirm] = useState<ConfirmRequest | null>(null)

  useEffect(() => {
    let live = true
    api
      .rules()
      .then((s) => {
        if (!live) return
        setRules(s.rules)
        setLoad({ status: 'ready' })
      })
      .catch((e: unknown) => {
        if (live) setLoad(e instanceof ApiError && e.status === 404 ? { status: 'unsupported' } : { status: 'error' })
      })
    return () => {
      live = false
    }
  }, [])

  if (load.status === 'loading' || load.status === 'unsupported') return null
  if (load.status === 'error') {
    return (
      <SettingsCard title={t('rules.title')} icon="filter">
        <p className="srow small muted" role="alert">
          {t('api.actionFailed')}
        </p>
      </SettingsCard>
    )
  }

  const commit = async (next: readonly PortalRule[], done?: string) => {
    setBusy(true)
    try {
      const echo = await api.updateRules(next.map(toWire))
      setRules(echo.rules)
      if (done) onToast(done)
      return true
    } catch (e) {
      const message = failureMessage(e)
      if (message) onToast(message, 'warn')
      return false
    } finally {
      setBusy(false)
    }
  }

  const disabled = !canWrite || busy
  const at = (i: number, patch: Partial<PortalRule>) => rules.map((r, j) => (j === i ? { ...r, ...patch } : r))

  const save = async (rule: PortalRule) => {
    if (!editing) return
    const next = editing.index == null ? [...rules, rule] : rules.map((r, j) => (j === editing.index ? rule : r))
    if (await commit(next, t('rules.saved'))) setEditing(null)
  }

  const askDelete = (i: number) => {
    const rule = rules[i]!
    setConfirm({
      title: t('rules.delete.title'),
      body: t('rules.delete.body', { name: rule.name }),
      confirmLabel: t('rules.delete.confirm'),
      onConfirm: () => void commit(rules.filter((_, j) => j !== i), t('rules.deleted')),
    })
  }

  const summary = (r: PortalRule) =>
    r.conditions
      .map((c) => `${t(`rules.fields.${c.field}`)} ${t(`rules.ops.${c.op}`)} ${c.value}`)
      .join(r.match === 'all' ? t('rules.and') : t('rules.or'))

  return (
    <SettingsCard
      title={t('rules.title')}
      icon="filter"
      aside={canWrite ? undefined : <Pill tone="warn">{t('settings.access.readOnly')}</Pill>}
    >
      <div className="srow set-col">
        <p className="small muted">{t('rules.desc')}</p>
      </div>
      {rules.length === 0 ? (
        <p className="srow small muted">{t('rules.empty')}</p>
      ) : (
        <ol className="rule-list" aria-label={t('rules.title')}>
          {rules.map((r, i) => (
            <li className={`srow rule-row${r.enabled ? '' : ' off'}`} key={r.id ?? i}>
              <div className="sl">
                <b id={`${id}-n${i}`}>{r.name}</b>
                <span className="mono small">{summary(r)}</span>
              </div>
              <div className="row rule-acts">
                <Switch
                  checked={r.enabled}
                  disabled={disabled}
                  labelledBy={`${id}-n${i}`}
                  onChange={(enabled) => void commit(at(i, { enabled }))}
                />
                <button
                  type="button"
                  className="btn sm ghost icon"
                  aria-label={t('rules.moveUp', { name: r.name })}
                  disabled={disabled || i === 0}
                  onClick={() => void commit(moved(rules, i, -1))}
                >
                  <Icon name="up" size="s" />
                </button>
                <button
                  type="button"
                  className="btn sm ghost icon"
                  aria-label={t('rules.moveDown', { name: r.name })}
                  disabled={disabled || i === rules.length - 1}
                  onClick={() => void commit(moved(rules, i, 1))}
                >
                  <Icon name="down" size="s" />
                </button>
                <button type="button" className="btn sm" disabled={disabled} aria-label={t('rules.edit', { name: r.name })} onClick={() => setEditing({ index: i, rule: r })}>
                  {t('rules.editBtn')}
                </button>
                <button type="button" className="btn sm ghost icon" disabled={disabled} aria-label={t('rules.remove', { name: r.name })} onClick={() => askDelete(i)}>
                  <Icon name="trash" size="s" />
                </button>
              </div>
            </li>
          ))}
        </ol>
      )}
      {canWrite && (
        <div className="srow">
          <button type="button" className="btn sm" disabled={busy} onClick={() => setEditing({ index: null, rule: blankRule() })}>
            <Icon name="plus" size="s" />
            {t('rules.add')}
          </button>
        </div>
      )}
      {editing && (
        <RuleEditor
          initial={editing.rule}
          isNew={editing.index == null}
          onSave={(rule) => void save(rule)}
          onClose={() => setEditing(null)}
          onWarn={(m) => onToast(m, 'warn')}
        />
      )}
      <ConfirmDialog request={confirm} onClose={() => setConfirm(null)} />
    </SettingsCard>
  )
}
