import { fileType, isActive } from './taskKind'
import type { TaskRow } from './types'

/**
 * Library search: free words match a download's name, its source host or its save folder; tokens
 * narrow further. `is:failed`, `host:example.com`, `type:video` (a file type or a protocol).
 * Several tokens of one key are alternatives; different keys and free words must all match.
 */
export type TokenKey = 'is' | 'host' | 'type'

export interface SearchToken {
  key: TokenKey
  value: string
}

export interface ParsedSearch {
  tokens: SearchToken[]
  words: string[]
}

const TOKEN = /^(is|host|type):(\S+)$/i

function asToken(word: string): SearchToken | null {
  const m = TOKEN.exec(word)
  return m ? { key: m[1]!.toLowerCase() as TokenKey, value: m[2]!.toLowerCase() } : null
}

export function formatToken(token: SearchToken): string {
  return `${token.key}:${token.value}`
}

export function parseSearch(input: string): ParsedSearch {
  const tokens: SearchToken[] = []
  const words: string[] = []
  for (const word of input.trim().toLowerCase().split(/\s+/)) {
    if (!word) continue
    const token = asToken(word)
    if (token) tokens.push(token)
    else words.push(word)
  }
  return { tokens, words }
}

/**
 * The field's view of a search: finished tokens (followed by a space) become chips, the rest stays
 * editable text. A token still being typed is text until its space.
 */
export function splitSearch(input: string): { chips: SearchToken[]; rest: string } {
  const trailing = /\s$/.test(input)
  const words = input.split(/\s+/).filter(Boolean)
  const chips: SearchToken[] = []
  const rest: string[] = []
  words.forEach((word, i) => {
    const token = i < words.length - 1 || trailing ? asToken(word) : null
    if (token) chips.push(token)
    else rest.push(word)
  })
  return { chips, rest: rest.join(' ') + (trailing && rest.length > 0 ? ' ' : '') }
}

/** The inverse of `splitSearch`: chips first, each followed by a space, then the typed text. */
export function joinSearch(chips: readonly SearchToken[], rest: string): string {
  if (chips.length === 0) return rest
  return chips.map((c) => `${formatToken(c)} `).join('') + rest.replace(/^\s+/, '')
}

const HOSTS = new Map<string, string>()

/** The host a download comes from; '' for a magnet or anything unparseable. Cached per source. */
export function sourceHost(source: string): string {
  let host = HOSTS.get(source)
  if (host != null) return host
  try {
    host = new URL(source).hostname.toLowerCase()
  } catch {
    host = ''
  }
  if (HOSTS.size > 5000) HOSTS.clear()
  HOSTS.set(source, host)
  return host
}

/** `is:` values beyond the status tokens themselves. */
const IS_ALIAS: Record<string, string> = {
  done: 'completed',
  finished: 'completed',
  complete: 'completed',
  error: 'failed',
  errored: 'failed',
  running: 'active',
  waiting: 'queued',
  stopped: 'paused',
}

function matchesIs(task: TaskRow, value: string): boolean {
  const v = IS_ALIAS[value] ?? value
  if (v === 'active') return isActive(task.statusToken) && task.statusToken !== 'queued'
  return task.statusToken === v
}

function matchesToken(task: TaskRow, token: SearchToken): boolean {
  switch (token.key) {
    case 'is':
      return matchesIs(task, token.value)
    case 'host':
      return sourceHost(task.source).includes(token.value)
    case 'type':
      return task.kind === token.value || fileType(task) === token.value
  }
}

export function matchesSearch(task: TaskRow, search: ParsedSearch): boolean {
  if (search.words.length > 0) {
    const hay = `${task.name}\n${sourceHost(task.source)}\n${task.savePath ?? ''}`.toLowerCase()
    if (!search.words.every((w) => hay.includes(w))) return false
  }
  if (search.tokens.length === 0) return true
  const byKey = new Map<TokenKey, SearchToken[]>()
  for (const token of search.tokens) byKey.set(token.key, [...(byKey.get(token.key) ?? []), token])
  for (const group of byKey.values()) if (!group.some((token) => matchesToken(task, token))) return false
  return true
}
