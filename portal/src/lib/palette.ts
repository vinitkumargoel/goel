/**
 * The command palette's matching: a forgiving subsequence match ("ubu iso" finds
 * "ubuntu-24.04.iso") scored so whole words and word starts rank first.
 */
export type PaletteGroup = 'add' | 'downloads' | 'view' | 'actions' | 'settings'

export const PALETTE_GROUPS: readonly PaletteGroup[] = ['add', 'downloads', 'view', 'actions', 'settings']

export interface PaletteCommand {
  id: string
  group: PaletteGroup
  label: string
  /** Extra words that should find it ("theme dark"). */
  keywords?: string
  /** Key glyphs shown at the right, e.g. ['G', 'H']. */
  keys?: readonly string[]
  run: () => void
}

const BOUNDARY = /[\s\-_./()[\]]/

/**
 * How well `query` matches `text`: null when not every query character appears in order. Each
 * space-separated part of the query must match on its own.
 */
export function fuzzyScore(query: string, text: string): number | null {
  const q = query.trim().toLowerCase()
  if (!q) return 0
  const hay = text.toLowerCase()
  let total = 0
  for (const part of q.split(/\s+/)) {
    const score = partScore(part, hay)
    if (score == null) return null
    total += score
  }
  return total
}

function partScore(part: string, hay: string): number | null {
  const direct = hay.indexOf(part)
  if (direct >= 0) {
    // A plain substring beats any scattered match; at a word start or the very start, more so.
    const atStart = direct === 0 ? 30 : BOUNDARY.test(hay[direct - 1]!) ? 20 : 0
    return 100 + part.length * 4 + atStart - Math.min(direct, 20)
  }
  let score = 0
  let from = 0
  let last = -2
  for (const ch of part) {
    const at = hay.indexOf(ch, from)
    if (at < 0) return null
    score += at === last + 1 ? 5 : 1
    if (at === 0 || BOUNDARY.test(hay[at - 1]!)) score += 3
    last = at
    from = at + 1
  }
  // Letters strewn across unrelated words are noise, not a match: ask for some runs or word starts.
  return score >= part.length * 2.5 ? score : null
}

export interface RankedGroup {
  group: PaletteGroup
  commands: PaletteCommand[]
}

/**
 * Commands that match, best first within each group, groups in the fixed order. With no query,
 * everything but the downloads group shows, in its given order.
 */
export function rankCommands(
  commands: readonly PaletteCommand[],
  query: string,
  perGroup = 8,
): RankedGroup[] {
  const q = query.trim()
  return PALETTE_GROUPS.flatMap((group) => {
    const inGroup = commands.filter((c) => c.group === group)
    const ranked = q
      ? inGroup
          .map((c) => ({ c, score: fuzzyScore(q, `${c.label} ${c.keywords ?? ''}`) }))
          .filter((x): x is { c: PaletteCommand; score: number } => x.score != null)
          .sort((a, b) => b.score - a.score)
          .map((x) => x.c)
      : group === 'downloads'
        ? []
        : inGroup
    const top = ranked.slice(0, perGroup)
    return top.length > 0 ? [{ group, commands: top }] : []
  })
}
