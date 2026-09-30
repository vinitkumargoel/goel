/**
 * The Add dialog's text and choices, kept in sessionStorage while it is open. A 401 sends the page
 * to `/` to sign in again; without this, thirty pasted links would be lost to an expired session.
 * Torrent files can't be kept — a `File` does not survive the navigation.
 */
export interface AddDraft {
  url: string
  folder: string
  priority: 'normal' | 'high' | 'low'
  paused: boolean
}

const KEY = 'goel.addDraft'

export function saveDraft(draft: AddDraft): void {
  try {
    if (draft.url.trim() === '') sessionStorage.removeItem(KEY)
    else sessionStorage.setItem(KEY, JSON.stringify(draft))
  } catch {
    // Storage blocked (private mode, quota): the draft is a convenience, not a guarantee.
  }
}

export function loadDraft(): AddDraft | null {
  let raw: string | null = null
  try {
    raw = sessionStorage.getItem(KEY)
  } catch {
    return null
  }
  if (!raw) return null
  try {
    const d = JSON.parse(raw) as Partial<AddDraft>
    if (typeof d.url !== 'string' || d.url.trim() === '') return null
    return {
      url: d.url,
      folder: typeof d.folder === 'string' ? d.folder : '',
      priority: d.priority === 'high' || d.priority === 'low' ? d.priority : 'normal',
      paused: d.paused === true,
    }
  } catch {
    return null
  }
}

export function clearDraft(): void {
  try {
    sessionStorage.removeItem(KEY)
  } catch {
    // Nothing to clear if storage is unavailable.
  }
}
