import { describe, expect, it } from 'vitest'
import { blankRule, moved, operatorsFor, ruleProblems, toWire, withField } from './rules'
import type { PortalRule } from './types'

const ok: PortalRule = {
  name: 'Images',
  enabled: true,
  match: 'all',
  conditions: [{ field: 'fileExtension', op: 'isAnyOf', value: 'dmg, pkg' }],
  tag: 'apps',
  startPaused: false,
}

describe('rules', () => {
  it('offers numeric comparisons only for size', () => {
    expect(operatorsFor('size')).toEqual(['largerThan', 'smallerThan'])
    expect(operatorsFor('domain')).toContain('matchesRegex')
    expect(withField({ field: 'fileName', op: 'contains', value: 'x' }, 'size').op).toBe('largerThan')
    expect(withField({ field: 'fileName', op: 'contains', value: 'x' }, 'url').op).toBe('contains')
  })

  it('finds what the server would refuse', () => {
    expect(ruleProblems(ok)).toEqual([])
    expect(ruleProblems(blankRule())).toEqual(expect.arrayContaining(['name', 'condition', 'action']))
    expect(ruleProblems({ ...ok, folder: 'relative' })).toContain('folder')
    expect(ruleProblems({ ...ok, conditions: [{ field: 'size', op: 'largerThan', value: 'lots' }] })).toContain('size')
    expect(ruleProblems({ ...ok, conditions: [{ field: 'size', op: 'largerThan', value: '1.5 GB' }] })).toEqual([])
    expect(ruleProblems({ ...ok, tag: null, whenDone: { kind: 'moveTo', target: '' } })).toContain('moveTo')
    expect(ruleProblems({ ...ok, tag: null })).toContain('action')
  })

  it('leaves a locked when-done out of what it sends, so the server keeps it', () => {
    expect(toWire({ ...ok, whenDone: { kind: 'runScript', locked: true } })).not.toHaveProperty('whenDone')
    expect(toWire({ ...ok, whenDone: { kind: 'moveTo', target: '/srv' } }).whenDone).toEqual({ kind: 'moveTo', target: '/srv' })
  })

  it('moves by one, clamped, without mutating', () => {
    const list = ['a', 'b', 'c']
    expect(moved(list, 2, -1)).toEqual(['a', 'c', 'b'])
    expect(moved(list, 0, -1)).toBe(list)
    expect(moved(list, 2, 1)).toBe(list)
    expect(list).toEqual(['a', 'b', 'c'])
  })
})
