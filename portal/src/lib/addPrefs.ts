/**
 * What the Add dialog remembers per browser: the last folder and priority, and a few recent
 * folders to pick from. Local only; the server's default folder is still the blank choice.
 */
export type AddPriority = 'low' | 'normal' | 'high'

export interface AddPrefs {
  folder: string
  priority: AddPriority
  recent: string[]
}

const KEY = 'goel.add.prefs'
export const MAX_RECENT = 5
const PRIORITIES: readonly string[] = ['low', 'normal', 'high']

export const DEFAULT_ADD_PREFS: AddPrefs = { folder: '', priority: 'normal', recent: [] }

export function loadAddPrefs(): AddPrefs {
  try {
    const raw = JSON.parse(localStorage.getItem(KEY) ?? 'null') as Partial<AddPrefs> | null
    if (!raw || typeof raw !== 'object') return DEFAULT_ADD_PREFS
    return {
      folder: typeof raw.folder === 'string' ? raw.folder : '',
      priority: PRIORITIES.includes(raw.priority as string) ? (raw.priority as AddPriority) : 'normal',
      recent: Array.isArray(raw.recent)
        ? raw.recent.filter((f): f is string => typeof f === 'string' && f !== '').slice(0, MAX_RECENT)
        : [],
    }
  } catch {
    return DEFAULT_ADD_PREFS
  }
}

/** After a successful add: this folder moves to the front of the recent list. */
export function nextAddPrefs(prev: AddPrefs, folder: string, priority: AddPriority): AddPrefs {
  const recent = folder ? [folder, ...prev.recent.filter((f) => f !== folder)] : prev.recent
  return { folder, priority, recent: recent.slice(0, MAX_RECENT) }
}

export function rememberAdd(folder: string, priority: AddPriority): void {
  try {
    localStorage.setItem(KEY, JSON.stringify(nextAddPrefs(loadAddPrefs(), folder, priority)))
  } catch {
    // Storage full or blocked: the dialog just starts from the defaults next time.
  }
}
