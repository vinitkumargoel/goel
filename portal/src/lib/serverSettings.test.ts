import { describe, expect, it } from 'vitest'
import { isDirty, settingsDiff, settingsProblems } from './serverSettings'
import type { ServerSettings } from './types'

const SAVED: ServerSettings = {
  general: {
    defaultSaveDirectory: '/srv/downloads',
    defaultFolderRule: 'fixed',
    existingFileReaction: 'rename',
    maxSimultaneousDownloads: 3,
    profile: 'Medium',
  },
  bittorrent: { encryptionMode: 'prefer', dht: true, pex: true, lpd: true, utp: true, autoDeleteTorrent: false },
}

describe('server settings', () => {
  it('diffs only the changed fields', () => {
    expect(settingsDiff(SAVED, SAVED)).toEqual({})
    expect(isDirty(SAVED, SAVED)).toBe(false)
    const draft = {
      general: { ...SAVED.general, maxSimultaneousDownloads: 5 },
      bittorrent: { ...SAVED.bittorrent, dht: false },
    }
    expect(settingsDiff(SAVED, draft)).toEqual({
      general: { maxSimultaneousDownloads: 5 },
      bittorrent: { dht: false },
    })
  })

  it('flags what the server would refuse', () => {
    expect(settingsProblems(SAVED)).toEqual([])
    const bad = { ...SAVED, general: { ...SAVED.general, defaultSaveDirectory: 'downloads', maxSimultaneousDownloads: 0 } }
    expect(settingsProblems(bad)).toEqual(['folder', 'simultaneous'])
    expect(settingsProblems({ ...SAVED, general: { ...SAVED.general, maxSimultaneousDownloads: 2.5 } })).toEqual(['simultaneous'])
  })
})
