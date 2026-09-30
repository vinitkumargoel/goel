/**
 * Long file names in narrow places. Release names are one unbroken token ("A.B.C.2160p.HDR.mkv"),
 * so the browser either overflows them or breaks mid-word ("Collectio / n"). These split them at
 * the dots, dashes and underscores a reader already treats as word gaps.
 */

/** The name cut into runs that each end in a separator, for rendering with a `<wbr>` after each. */
export function breakRuns(name: string): string[] {
  return name.match(/[^._\-/ ]*[._\-/ ]|[^._\-/ ]+$/g) ?? [name]
}

/**
 * Head and tail for a middle ellipsis: the tail (episode number, extension) is what tells two files
 * of a season pack apart, so it is kept whole while the head truncates. Short names stay in the head.
 */
export function splitTail(name: string, tail = 16): { head: string; tail: string } {
  if (name.length <= tail + 12) return { head: name, tail: '' }
  return { head: name.slice(0, name.length - tail), tail: name.slice(name.length - tail) }
}

/** The folder every path shares ("Show/Season 01/"), or '' when they don't share one. */
export function commonDir(paths: readonly string[]): string {
  if (paths.length < 2) return ''
  const split = paths.map((p) => p.split('/'))
  const first = split[0]!
  let depth = 0
  // Directories only: the last component of each path is its file name.
  const max = Math.min(...split.map((s) => s.length - 1))
  while (depth < max && split.every((s) => s[depth] === first[depth])) depth++
  return depth === 0 ? '' : `${first.slice(0, depth).join('/')}/`
}

/**
 * The name prefix every sibling repeats ("Big.Buck.Bunny."), cut back to a separator so no token is
 * split. '' when there is no worthwhile one, or when trimming it would leave a name too short to read.
 */
export function siblingStem(names: readonly string[]): string {
  if (names.length < 2) return ''
  let n = 0
  const first = names[0]!
  while (n < first.length && names.every((s) => s[n] === first[n])) n++
  const cut = Math.max(...['.', '_', '-', ' '].map((sep) => first.lastIndexOf(sep, n - 1))) + 1
  if (cut < 6 || names.some((s) => s.length - cut < 6)) return ''
  return first.slice(0, cut)
}

export interface FileLabel {
  /** Folder below the shared one ("Season 01"), '' at the top. */
  dir: string
  /** The file name without the prefix its folder-mates share. */
  label: string
}

/**
 * Short labels for a torrent's file list: the shared folder is said once (see `commonDir`), each
 * subfolder once as a heading, and within a folder only the part of the name that differs is shown.
 */
export function fileLabels(paths: readonly string[], shared: string): FileLabel[] {
  const split = paths.map((p) => {
    const rest = p.slice(shared.length)
    const slash = rest.lastIndexOf('/')
    return { dir: slash < 0 ? '' : rest.slice(0, slash), base: rest.slice(slash + 1) }
  })
  const stems = new Map<string, string>()
  for (const dir of new Set(split.map((s) => s.dir))) {
    stems.set(dir, siblingStem(split.filter((s) => s.dir === dir).map((s) => s.base)))
  }
  return split.map(({ dir, base }) => ({ dir, label: base.slice(stems.get(dir)!.length) }))
}
