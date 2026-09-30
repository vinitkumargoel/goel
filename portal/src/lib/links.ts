/** The schemes the daemon's add endpoint understands. Anything else is flagged, not blocked. */
const SUPPORTED = /^(https?|s?ftp):\/\/\S+$|^magnet:\?\S+$/i

export interface LinkLine {
  text: string
  supported: boolean
}

export interface LinkSummary {
  lines: LinkLine[]
  /** Lines that look like a link the daemon can queue. */
  valid: number
  /** Non-blank lines that don't; the server will likely refuse them. */
  unsupported: LinkLine[]
}

/** One link per non-blank line, the same split the add endpoint performs. */
export function summarizeLinks(input: string): LinkSummary {
  const lines = input
    .split(/\r\n|\r|\n/)
    .map((l) => l.trim())
    .filter((l) => l !== '')
    .map((text) => ({ text, supported: SUPPORTED.test(text) }))
  return {
    lines,
    valid: lines.filter((l) => l.supported).length,
    unsupported: lines.filter((l) => !l.supported),
  }
}
