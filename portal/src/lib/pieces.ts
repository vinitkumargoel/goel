export type PieceState = 'have' | 'partial' | 'missing'

export interface PieceRun {
  start: number
  length: number
  state: PieceState
}

export function pieceState(fraction: number): PieceState {
  return fraction >= 1 ? 'have' : fraction > 0 ? 'partial' : 'missing'
}

/**
 * The piece map as runs of one state, so a 720-bucket torrent draws as a few dozen rects in one
 * strip instead of 720 grid cells that overflow the panel.
 */
export function pieceRuns(pieces: readonly number[]): PieceRun[] {
  const runs: PieceRun[] = []
  for (let i = 0; i < pieces.length; i++) {
    const state = pieceState(pieces[i]!)
    const last = runs.at(-1)
    if (last && last.state === state) last.length++
    else runs.push({ start: i, length: 1, state })
  }
  return runs
}

/** Buckets fully held, for the strip's label. */
export function piecesHave(pieces: readonly number[]): number {
  return pieces.filter((p) => p >= 1).length
}
