import { streamURL, zipURL } from './api'
import type { TaskRow } from './types'

/** Finished data on disk: the only state `/stream` can hand over whole. */
export function canSave(task: Pick<TaskRow, 'statusToken'>): boolean {
  return task.statusToken === 'completed' || task.statusToken === 'seeding'
}

/** A multi-file download comes down as one zip; anything else as the file itself. */
export function saveURL(task: Pick<TaskRow, 'id' | 'multiFile'>): string {
  return task.multiFile ? zipURL(task.id) : streamURL(task.id, true)
}

/** Same-origin, so `download` is honoured and the page is never navigated away. */
export function saveToDevice(url: string, name = ''): void {
  const a = document.createElement('a')
  a.href = url
  a.download = name
  a.rel = 'noopener'
  document.body.appendChild(a)
  a.click()
  a.remove()
}
