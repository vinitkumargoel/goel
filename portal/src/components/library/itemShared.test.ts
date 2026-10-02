import { afterEach, describe, expect, it } from 'vitest'
import i18n from '../../i18n'
import { makeTask } from '../../test/makeTask'
import { itemLabel, statusLabel, statusText } from './itemShared'

describe('status wording follows the chosen language', () => {
  afterEach(() => i18n.changeLanguage('en'))

  it('translates the server token, not its English copy', async () => {
    await i18n.changeLanguage('de')
    const task = makeTask('a', { status: 'Paused', statusToken: 'paused', progress: 0.5 })
    expect(statusLabel(task, i18n.t)).toBe(i18n.t('workflow.group.status.paused'))
    expect(statusLabel(task, i18n.t)).not.toBe('Paused')
    expect(statusText(task, i18n.t)).toContain('50%')
    expect(statusText(task, i18n.t)).not.toContain('Paused')
    expect(itemLabel(task, i18n.t)).not.toContain('Paused')
  })

  it('falls back to the server copy for an unknown token', () => {
    const task = makeTask('b', { status: 'Mystery', statusToken: 'mystery' as never })
    expect(statusLabel(task, i18n.t)).toBe('Mystery')
  })
})
