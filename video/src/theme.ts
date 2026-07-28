/* Film tokens. Colour from Sources/GoelApp/Theme.swift (AppTheme.frostDark) and website/tokens.css;
 * motion from DESIGN-SPEC.md §3. Nothing invented — the spec table gives each value's origin. */

export const C = {
  canvas: '#0b0c10',
  canvasLift: '#12141a',
  appBar: '#22252e',
  appSide: '#191b21',
  surface: '#20222b',
  row: '#212329',
  rowSel: '#333953',
  statusBar: '#21242d',

  accent: '#8AA2FF',
  accentPress: '#738FF5',
  green: '#4ADE80',
  orange: '#FBBF6B',
  red: '#F87171',
  yellow: '#FCD34D',
  purple: '#C0A2FB',
  teal: '#7FDBE8',
  indigo: '#A5B8FF',

  ink: '#e8eaf0',
  inkSoft: '#a8adba',
  inkFaint: '#767c8a',
  inkDim: '#515660',
} as const;

/* Named theme window tints, for the theme-sweep shot */
export const THEME_TINT = {
  'frost-dark': '#191b21',
  'frost-light': '#eceef2',
  dracula: '#282A36',
  nord: '#2E3440',
} as const;

export const FONT = {
  ui: 'Inter, -apple-system, BlinkMacSystemFont, sans-serif',
  mono: '"IBM Plex Mono", ui-monospace, monospace',
} as const;

/* Motion tokens — DESIGN-SPEC §3. Things that merely move use `entry`/`camera`; things that LAND use
 * `land` (y1 > 1 per the library's hard ruling, overriding the "professional trust = no bounce" preset). */
export const M = {
  dur: 21,
  entry: [0, 0, 0.2, 1] as const,
  camera: [0.22, 1, 0.36, 1] as const,
  land: [0.16, 1, 0.3, 1] as const,
  overshoot: 1.06,
  staggerRow: 4,
  staggerCard: 6,
} as const;

/** Page geometry of the captured UI replica, in CSS px. */
export const PAGE = { w: 1480, h: 841 } as const;
/** The app window inside that page. */
export const WIN = { x: 60, y: 60, w: 1360, h: 721 } as const;
