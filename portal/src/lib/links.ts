/**
 * The schemes the daemon's add endpoint understands (`DownloadSource.parse`): http, https, ftp,
 * ftps, sftp and magnet. Anything else is flagged, not blocked.
 */
const SUPPORTED = /^(https?|ftps?|sftp):\/\/\S+$|^magnet:\?\S+$/i

/** The input without any line that trims to `text` — the ✕ on a flagged line. */
export function removeLine(input: string, text: string): string {
  return input
    .split(/\r\n|\r|\n/)
    .filter((l) => l.trim() !== text)
    .join('\n')
}

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
