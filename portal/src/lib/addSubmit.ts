import { api, failureMessage } from './api'
import type { AddRequest } from './types'

export interface AddFailure {
  /** The torrent file's name, or '' for the pasted links as a whole. */
  file: string
  error: string
}

export interface AddSummary {
  added: number
  /** Links refused as internal-network targets. */
  refused: number
  /** Torrent files (or the link batch) the server turned down while something else was queued. */
  failures: AddFailure[]
}

export interface AddJob {
  /** The textarea as typed; blank lines are fine. */
  text: string
  /** How many lines look like supported links. */
  validLinks: number
  files: readonly File[]
  options: Omit<AddRequest, 'url'>
}

/**
 * Sends links to `/api/add` and torrent files to `/api/add-torrent`, together. Links go only if
 * one looks valid — or if there are no files, so the server can explain what's wrong with the
 * text. Rejects (with the first error) only when nothing at all was queued; otherwise resolves
 * with a summary whose `failures` list the parts that were turned down.
 */
export async function submitAdd(job: AddJob): Promise<AddSummary> {
  const text = job.text.trim()
  const sendLinks = text !== '' && (job.validLinks > 0 || job.files.length === 0)
  const sendFiles = job.files.length > 0

  const [links, torrents] = await Promise.allSettled([
    sendLinks ? api.add({ ...job.options, url: text }) : Promise.resolve(null),
    sendFiles
      ? api.addTorrents(job.files, {
          dir: job.options.folder || undefined,
          priority: job.options.priority,
          paused: job.options.paused,
        })
      : Promise.resolve(null),
  ])

  const summary: AddSummary = { added: 0, refused: 0, failures: [] }
  const errors: unknown[] = []

  if (links.status === 'fulfilled') {
    summary.added += links.value?.added ?? 0
    summary.refused += links.value?.refused ?? 0
  } else {
    errors.push(links.reason)
  }

  if (torrents.status === 'fulfilled') {
    summary.added += torrents.value?.added ?? 0
    summary.refused += torrents.value?.refused ?? 0
    for (const f of torrents.value?.errors ?? []) summary.failures.push({ file: f.file, error: f.error })
  } else {
    errors.push(torrents.reason)
  }

  if (errors.length > 0 && summary.added === 0 && summary.refused === 0) throw errors[0]

  for (const e of errors) {
    // Null: a 403 or 401 the api layer already reported.
    const message = failureMessage(e)
    if (message) summary.failures.push({ file: '', error: message })
  }
  return summary
}
