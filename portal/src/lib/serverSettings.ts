import type { ServerSettings, ServerSettingsUpdate } from './types'

export const SIMULTANEOUS_RANGE = { min: 1, max: 20 } as const

/** Only what changed, so Save never rewrites a setting somebody else changed meanwhile. */
export function settingsDiff(saved: ServerSettings, draft: ServerSettings): ServerSettingsUpdate {
  const out: ServerSettingsUpdate = {}
  for (const group of ['general', 'bittorrent'] as const) {
    const changed: Record<string, unknown> = {}
    for (const key of Object.keys(draft[group]) as string[]) {
      if (key === 'profile') continue
      const was = (saved[group] as Record<string, unknown>)[key]
      const now = (draft[group] as Record<string, unknown>)[key]
      if (was !== now) changed[key] = now
    }
    if (Object.keys(changed).length > 0) (out as Record<string, unknown>)[group] = changed
  }
  return out
}

export function isDirty(saved: ServerSettings, draft: ServerSettings): boolean {
  return Object.keys(settingsDiff(saved, draft)).length > 0
}

export type SettingsProblem = 'folder' | 'simultaneous'

/** The same shape rules the server enforces, so a bad value is caught before the round trip. */
export function settingsProblems(draft: ServerSettings): SettingsProblem[] {
  const problems: SettingsProblem[] = []
  const folder = draft.general.defaultSaveDirectory.trim()
  if (!folder.startsWith('/') || folder.length > 1024) problems.push('folder')
  const n = draft.general.maxSimultaneousDownloads
  if (!Number.isInteger(n) || n < SIMULTANEOUS_RANGE.min || n > SIMULTANEOUS_RANGE.max) problems.push('simultaneous')
  return problems
}
