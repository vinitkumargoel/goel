/** Brush colours from the palette's own tokens: the first profile in the up hue, then the accents. */
const BRUSH = ['var(--up)', 'var(--accent-line)', 'var(--accent)', 'var(--info)', 'var(--warn)', 'var(--good)']

/** A stable colour per profile, so "Night" paints the same on every visit; "keep current" is the accent. */
export function brushColor(name: string, profiles: readonly string[]): string {
  if (!name) return 'var(--accent)'
  const i = profiles.indexOf(name)
  if (i >= 0) return BRUSH[i % BRUSH.length]!
  let hash = 0
  for (const ch of name) hash = (hash * 31 + ch.charCodeAt(0)) >>> 0
  return BRUSH[hash % BRUSH.length]!
}
