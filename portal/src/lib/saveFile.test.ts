import { describe, expect, it, vi } from 'vitest'
import { canSave, saveToDevice, saveURL } from './saveFile'

describe('saveFile', () => {
  it('saves only finished data', () => {
    expect(canSave({ statusToken: 'completed' })).toBe(true)
    expect(canSave({ statusToken: 'seeding' })).toBe(true)
    expect(canSave({ statusToken: 'downloading' })).toBe(false)
    expect(canSave({ statusToken: 'failed' })).toBe(false)
  })

  it('zips a multi-file download and attaches a single file', () => {
    expect(saveURL({ id: 'a b', multiFile: true })).toBe('/stream?id=a%20b&zip=1')
    expect(saveURL({ id: 'x', multiFile: false })).toBe('/stream?id=x&dl=1')
  })

  it('clicks a transient download link and removes it', () => {
    const click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {})
    saveToDevice('/stream?id=x&dl=1', 'x.iso')
    expect(click).toHaveBeenCalledTimes(1)
    const a = click.mock.contexts[0] as HTMLAnchorElement
    expect(a.getAttribute('download')).toBe('x.iso')
    expect(document.querySelector('a[download]')).toBeNull()
    click.mockRestore()
  })
})
