import { beforeEach, describe, expect, it, vi } from 'vitest'
import { submitAdd } from './addSubmit'

const api = vi.hoisted(() => ({ add: vi.fn(), addTorrents: vi.fn() }))

vi.mock('./api', async (importOriginal) => {
  const real = await importOriginal<typeof import('./api')>()
  return { ...real, api }
})

const torrent = new File(['d'], 'a.torrent')
const options = { folder: '/srv/dl', priority: 'normal' as const, paused: false, network: 'auto' }

beforeEach(() => {
  api.add.mockReset().mockResolvedValue({ added: 2, refused: 1, ids: [] })
  api.addTorrents.mockReset().mockResolvedValue({ added: 1, errors: [] })
})

describe('submitAdd', () => {
  it('sends links and files together and sums the results', async () => {
    const out = await submitAdd({ text: ' https://a/x \n', validLinks: 1, files: [torrent], options })
    expect(api.add).toHaveBeenCalledWith({ ...options, url: 'https://a/x' })
    expect(api.addTorrents).toHaveBeenCalledWith([torrent], {
      dir: '/srv/dl',
      priority: 'normal',
      paused: false,
    })
    expect(out).toEqual({ added: 3, refused: 1, failures: [] })
  })

  it('skips the link call when only files and unusable text are present', async () => {
    await submitAdd({ text: 'nonsense', validLinks: 0, files: [torrent], options })
    expect(api.add).not.toHaveBeenCalled()
  })

  it('still sends unusable text alone, so the server can explain it', async () => {
    await submitAdd({ text: 'nonsense', validLinks: 0, files: [], options })
    expect(api.add).toHaveBeenCalled()
    expect(api.addTorrents).not.toHaveBeenCalled()
  })

  it('omits dir for the default folder', async () => {
    await submitAdd({ text: '', validLinks: 0, files: [torrent], options: { ...options, folder: '' } })
    expect(api.addTorrents).toHaveBeenCalledWith([torrent], expect.objectContaining({ dir: undefined }))
  })

  it('reports per-file refusals alongside what was queued', async () => {
    api.addTorrents.mockResolvedValue({ added: 1, errors: [{ file: 'b.torrent', error: 'Not a torrent' }] })
    const out = await submitAdd({ text: '', validLinks: 0, files: [torrent, torrent], options })
    expect(out.failures).toEqual([{ file: 'b.torrent', error: 'Not a torrent' }])
  })

  it('turns a failed half into a failure when the other half queued something', async () => {
    api.addTorrents.mockRejectedValue(new Error('boom'))
    const out = await submitAdd({ text: 'https://a/x', validLinks: 1, files: [torrent], options })
    expect(out.added).toBe(2)
    expect(out.failures).toHaveLength(1)
    expect(out.failures[0]?.file).toBe('')
  })

  it('explains an upload that queued nothing and named no file', async () => {
    api.addTorrents.mockResolvedValue({ added: 0 })
    const out = await submitAdd({ text: '', validLinks: 0, files: [torrent], options })
    expect(out.failures).toHaveLength(1)
    expect(out.failures[0]?.error).not.toBe('')
  })

  it('rejects when nothing was queued at all', async () => {
    api.add.mockRejectedValue(new Error('down'))
    await expect(submitAdd({ text: 'https://a/x', validLinks: 1, files: [], options })).rejects.toThrow('down')
  })
})
