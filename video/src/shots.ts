/* Frame-level timeline — DESIGN-SPEC.md §5, locked before implementation.
 *
 * Every downstream frame reference (captions, SFX pins, QA stills) is written
 * as `S.<name>.from + offset`, never as a bare number, so shifting one shot
 * shifts everything that hangs off it.
 */

type Shot = { from: number; dur: number; note: string };

const seq = <K extends string>(entries: [K, number, string][]) => {
  let at = 0;
  const out = {} as Record<K, Shot>;
  for (const [k, dur, note] of entries) {
    out[k] = { from: at, dur, note };
    at += dur;
  }
  return out;
};

export const S = seq([
  ['brandOpen', 100, 'ambient orbs, icon settles, wordmark crystallises, 30f hold'],
  ['appDebut', 120, 'accent frame draws, camera arcs L->R, all layers land together'],
  ['titleA', 90, 'Five protocols. / One queue.'],
  ['queue', 125, 'rows descend + flatten + accent seam; last row seats at 87'],
  ['throughput', 140, 'push into the status bar, odometer rolls to 43 MB/s, lock pulse'],
  ['detail', 130, 'grazing camera down the detail panel; blocks fall and seat'],
  ['carry', 150, 'the progress bar extends off-screen and corners into the piece map'],
  ['pieces', 150, 'six-cell wall light-up rebuilds the BitTorrent view'],
  ['sftp', 150, 'the remote file arcs from the SFTP browser into the queue'],
  ['titleB', 90, 'Everywhere / you already are.'],
  ['capture', 130, 'the page turns; five browser marks pop, then five pipes connect'],
  ['menubar', 100, 'desktop dims and blurs, popover drops, rows stagger'],
  ['portal', 110, 'the cube turns: native face -> portal face'],
  ['themes', 165, 'three diagonal sweeps across four real theme captures'],
  ['outro', 155, 'nine elements fly in, the wordmark lands, 75f hold'],
]);

export const TOTAL = Object.values(S).reduce((n, s) => Math.max(n, s.from + s.dur), 0);

/** Bottom-strip narration. Every claim in the film has one — it plays muted. */
export const CAPTIONS: { from: number; dur: number; text: string; sub?: string }[] = [
  { from: S.appDebut.from + 40, dur: 68, text: 'One native app. Five protocols.' },
  { from: S.queue.from + 22, dur: 88, text: 'One queue, every protocol', sub: 'http · ftp · sftp · bittorrent · hls' },
  { from: S.throughput.from + 40, dur: 66, text: 'Peak throughput', sub: 'segmented & resumable' },
  { from: S.detail.from + 26, dur: 86, text: 'Live progress, per file', sub: 'speed · eta · connections' },
  { from: S.pieces.from + 24, dur: 82, text: 'Real BitTorrent', sub: 'piece map · per-file priority' },
  { from: S.sftp.from + 24, dur: 82, text: 'Browse & transfer over SFTP', sub: 'host key pinned' },
  { from: S.capture.from + 26, dur: 76, text: 'Never miss a download', sub: 'capture from your browser' },
  { from: S.menubar.from + 22, dur: 66, text: 'Right from your menu bar' },
  { from: S.portal.from + 30, dur: 62, text: 'Manage from any browser', sub: 'same engine, any device' },
  { from: S.themes.from + 26, dur: 70, text: 'Four built-in themes' },
];
