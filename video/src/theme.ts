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

export const M = {
  dur: 21,
  entry: [0, 0, 0.2, 1] as const,
  camera: [0.22, 1, 0.36, 1] as const,
  land: [0.16, 1, 0.3, 1] as const,
  overshoot: 1.06,
  staggerRow: 4,
  staggerCard: 6,
} as const;

export const PAGE = { w: 1480, h: 841 } as const;
export const WIN = { x: 60, y: 60, w: 1360, h: 721 } as const;
