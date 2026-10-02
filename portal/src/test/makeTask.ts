import type { TaskRow } from '../lib/types'

/**
 * A complete `TaskRow` with quiet defaults; tests override only what they are about. Also the base
 * of the dev fixtures' rows (dev/fixtures.ts), so a new `TaskRow` field is added in one place.
 */
export function makeTask(id: string, over: Partial<TaskRow> = {}): TaskRow {
  return {
    id,
    name: `${id}.iso`,
    status: 'Queued',
    statusToken: 'queued',
    kind: 'http',
    progress: 0,
    downSpeed: 0,
    upSpeed: 0,
    totalBytes: 1_000_000,
    doneBytes: 0,
    upBytes: 0,
    ratio: 0,
    seeds: null,
    conns: 0,
    addedAt: 1_790_000_000,
    completedAt: null,
    etaSeconds: null,
    error: null,
    source: `https://example.org/${id}.iso`,
    multiFile: false,
    fileCount: 1,
    streamable: false,
    speedLimit: null,
    tags: [],
    queuePosition: null,
    priority: 'normal',
    startAt: null,
    savePath: '/Users/me/Downloads',
    ...over,
  }
}
