import { afterEach, describe, expect, it } from 'vitest'
import { clearDraft, loadDraft, saveDraft } from './addDraft'

describe('addDraft', () => {
  afterEach(() => sessionStorage.clear())

  it('round-trips the typed links and choices', () => {
    saveDraft({ url: 'https://a/x.iso\nhttps://b/y.iso', folder: '/srv', priority: 'high', paused: true })
    expect(loadDraft()).toEqual({
      url: 'https://a/x.iso\nhttps://b/y.iso',
      folder: '/srv',
      priority: 'high',
      paused: true,
    })
  })

  it('drops a blank draft instead of restoring an empty dialog', () => {
    saveDraft({ url: 'https://a/x.iso', folder: '', priority: 'normal', paused: false })
    saveDraft({ url: '   ', folder: '', priority: 'normal', paused: false })
    expect(loadDraft()).toBeNull()
  })

  it('ignores garbage and unknown priorities', () => {
    sessionStorage.setItem('goel.addDraft', '{nope')
    expect(loadDraft()).toBeNull()
    sessionStorage.setItem('goel.addDraft', JSON.stringify({ url: 'x', priority: 'urgent' }))
    expect(loadDraft()?.priority).toBe('normal')
    clearDraft()
    expect(loadDraft()).toBeNull()
  })
})
