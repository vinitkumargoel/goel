import type { FileType } from '../../lib/taskKind'
import { Icon, type IconName } from './Icon'

/** A tile's artwork: every file type, plus a folder and the grey placeholder. */
export type ArtKind = FileType | 'dir' | 'ghost'

const GLYPH: Readonly<Record<ArtKind, IconName>> = {
  video: 'film',
  audio: 'music',
  image: 'image',
  iso: 'disc',
  archive: 'archive',
  app: 'app',
  doc: 'doc',
  magnet: 'magnet',
  other: 'file',
  dir: 'folder',
  ghost: 'file',
}

interface ArtProps {
  kind: ArtKind
  /** xs 24 · s 32 · m 44 (default) · l 64 · band: the full-width strip atop a board card. */
  size?: 'xs' | 's' | 'm' | 'l' | 'band'
  /** Greyed for a paused download, a skipped file, a missing one. */
  faded?: boolean
  /** Overrides the type's glyph (subtitles drawn on a doc tile, say). */
  glyph?: IconName
  /** Laid over the band, top right: the protocol badge. */
  children?: React.ReactNode
  className?: string
}

/**
 * Generated artwork for a file type, the Studio `.art` tile: a two-stop gradient in the type's hue,
 * a pattern drawn in `--art-hi`, the glyph in `--art-ink`. Decorative — the name beside it says
 * what the file is.
 */
export function Art({ kind, size = 'm', faded = false, glyph, children, className }: ArtProps) {
  const cls = ['art', kind, size === 'm' ? '' : size, faded ? 'faded' : '', className ?? '']
    .filter(Boolean)
    .join(' ')
  return (
    <span className={cls} aria-hidden={children ? undefined : true}>
      <Icon name={glyph ?? GLYPH[kind]} />
      {children}
    </span>
  )
}
