import type { PortalRule, RuleCondition, RuleField, RuleOperator } from './types'

export const RULE_FIELDS: readonly RuleField[] = ['fileName', 'fileExtension', 'domain', 'url', 'size']

const TEXT_OPS: readonly RuleOperator[] = ['isEqual', 'contains', 'beginsWith', 'endsWith', 'isAnyOf', 'matchesRegex']
const SIZE_OPS: readonly RuleOperator[] = ['largerThan', 'smallerThan']

/** Size compares numbers, every other field compares text (as the desktop editor offers them). */
export function operatorsFor(field: RuleField): readonly RuleOperator[] {
  return field === 'size' ? SIZE_OPS : TEXT_OPS
}

export const RULE_LIMITS = { name: 120, conditions: 10, value: 512, tag: 64, rules: 100, speedKBps: 100_000_000 } as const

export function blankRule(): PortalRule {
  return {
    name: '',
    enabled: true,
    match: 'all',
    conditions: [{ field: 'fileExtension', op: 'isAnyOf', value: '' }],
    startPaused: false,
  }
}

/** Switching between text and size resets the operator to one the new field offers. */
export function withField(c: RuleCondition, field: RuleField): RuleCondition {
  const ops = operatorsFor(field)
  return { ...c, field, op: ops.includes(c.op) ? c.op : ops[0]! }
}

const SIZE = /^\d+(\.\d+)?\s*[kmgt]?b?$/i

export type RuleProblem = 'name' | 'condition' | 'size' | 'action' | 'folder' | 'moveTo'

const absolute = (p: string) => p.trim().startsWith('/')

/** Mirrors what the server enforces, so a slip is caught before the round trip. */
export function ruleProblems(rule: PortalRule): RuleProblem[] {
  const out: RuleProblem[] = []
  const name = rule.name.trim()
  if (name === '' || name.length > RULE_LIMITS.name) out.push('name')
  const values = rule.conditions.map((c) => c.value.trim())
  if (rule.conditions.length === 0 || values.some((v) => v === '' || v.length > RULE_LIMITS.value)) out.push('condition')
  if (rule.conditions.some((c) => c.field === 'size' && c.value.trim() !== '' && !SIZE.test(c.value.trim()))) out.push('size')
  if (rule.folder && rule.folder.trim() !== '' && !absolute(rule.folder)) out.push('folder')
  const done = rule.whenDone
  if (done?.kind === 'moveTo' && !(done.target && absolute(done.target))) out.push('moveTo')
  const hasAction =
    !!rule.folder?.trim() ||
    !!rule.tag?.trim() ||
    (rule.speedLimitBytesPerSec ?? 0) > 0 ||
    (rule.priority != null && rule.priority !== 'normal') ||
    rule.startPaused ||
    (done != null && done.kind !== 'nothing')
  if (!hasAction) out.push('action')
  return out
}

/** What goes back to the server: a locked when-done is left out, which tells the server to keep it. */
export function toWire(rule: PortalRule): PortalRule {
  const { whenDone, ...rest } = rule
  if (!whenDone || whenDone.locked) return rest
  return { ...rest, whenDone: { kind: whenDone.kind, ...(whenDone.kind === 'moveTo' ? { target: whenDone.target } : {}) } }
}

/** A new list with the rule at `from` moved by `delta`, clamped; the same list when nothing moves. */
export function moved<T>(list: readonly T[], from: number, delta: number): readonly T[] {
  const to = Math.min(Math.max(from + delta, 0), list.length - 1)
  if (from < 0 || from >= list.length || to === from) return list
  const next = [...list]
  next.splice(to, 0, next.splice(from, 1)[0]!)
  return next
}

export function replaced<T>(list: readonly T[], at: number, item: T): readonly T[] {
  return list.map((x, i) => (i === at ? item : x))
}
