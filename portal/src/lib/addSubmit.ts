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
  /** The new tasks' ids, links first, so the list can select and reveal them. */
  ids: string[]
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
          network: job.options.network,
          sequential: job.options.sequential,
          startAt: job.options.startAt,
        })
      : Promise.resolve(null),
  ])

  const summary: AddSummary = { added: 0, refused: 0, failures: [], ids: [] }
  const errors: unknown[] = []

  if (links.status === 'fulfilled') {
    summary.added += links.value?.added ?? 0
    summary.refused += links.value?.refused ?? 0
    summary.ids.push(...(links.value?.ids ?? []))
  } else {
    errors.push(links.reason)
  }

  if (torrents.status === 'fulfilled') {
    summary.added += torrents.value?.added ?? 0
    summary.refused += torrents.value?.refused ?? 0
    summary.ids.push(...(torrents.value?.ids ?? []))
    for (const f of torrents.value?.errors ?? []) summary.failures.push({ file: f.file, error: f.error })
  } else {
    errors.push(torrents.reason)
  }

  if (errors.length > 0 && summary.added === 0 && summary.refused === 0) throw errors[0]

  if (summary.added === 0 && summary.refused === 0 && summary.failures.length === 0 && errors.length === 0) {
    // e.g. an all-refused 400 envelope without per-file errors: never close silently.
    summary.failures.push({ file: '', error: failureMessage(null) ?? '' })
  }

  for (const e of errors) {
    // Null: a 403 or 401 the api layer already reported.
    const message = failureMessage(e)
    if (message) summary.failures.push({ file: '', error: message })
  }
  return summary
}
