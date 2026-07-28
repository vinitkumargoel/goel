/* Sound design — single audio source of truth (references/sound-design.md); BGM is the licence-documented
 * `house-vibez.mp3`. Pins are `S.<shot>.from + offset`, never absolute, so shot-length changes survive. */
import { S, TOTAL } from './shots';

export const BGM = 'audio/bgm-house-vibez.mp3';

/* The track is a flat house loop (-11 to -12 dBFS throughout, no breakdown), so the energy curve is
   drawn here: dipped under both title cards (rest beats), pushed for the finale. Peak 0.34 = headroom. */
export const BGM_ENV: { frames: number[]; values: number[] } = {
  frames: [
    0,
    30,
    S.titleA.from - 8,
    S.titleA.from + 30,
    S.queue.from,
    S.titleB.from - 8,
    S.titleB.from + 30,
    S.capture.from,
    S.outro.from + 40,
    TOTAL - 52,
    TOTAL,
  ],
  values: [0, 0.17, 0.2, 0.13, 0.24, 0.29, 0.18, 0.29, 0.34, 0.34, 0],
};

/* Transient latency (out/sfx-latency.json, see AUDIO.md): a cue's `from` is the PICTURE frame, and the
   sample starts LEAD[sample] earlier so its peak lands there — else `sub-bass-knock` fires 2.1s late. */
const LEAD: Record<string, number> = {
  pop: 1,
  'transition-snap': 3,
  'click-camera': 5,
  'sweep-fast-small': 8,
  'swoosh-quick': 8,
  'sweep-scifi-fast': 5,
  'impact-zoom-quick': 5,
  'transition-soft': 13,
  'impact-cine': 16,
  'whoosh-fast': 21,
  'whoosh-big': 21,
  'drum-impact-subtle': 25,
  'shimmer-sparkle-sweep': 29,
  sparkle: 44,
  'sub-bass-knock': 64,
  'bass-transition-pulse': 7,
  // the riser is anchored by its END, not its peak — see the outro block
  'riser-trailer': 0,
};

export type Cue = {
  /** The PICTURE frame this sound belongs to. Lead compensation is automatic. */
  from: number;
  src: string;
  volume: number;
  /** Truncates long samples to the length of their action (rule S4). */
  dur?: number;
  /** Opt out of lead compensation (for sounds anchored by their end). */
  raw?: boolean;
  /** What this cue is nailed to on screen. */
  note: string;
};

const a = (f: string) => `audio/${f}.mp3`;

/** Resolved start frame for a cue, after transient compensation. */
export const startOf = (c: Cue): number => {
  if (c.raw) return c.from;
  const name = c.src.replace('audio/', '').replace('.mp3', '');
  return Math.max(0, c.from - (LEAD[name] ?? 0));
};

/** Length to play, in frames — explicit `dur`, else the action-length default. */
export const durOf = (c: Cue): number => c.dur ?? 40;

/** A run of one repeating element: two alternating samples + a descending volume ladder. Interval
 * acceleration is deliberately NOT applied — the picture cadence is uniform, so it would only desync. */
const run = (
  base: number,
  first: number,
  gap: number,
  count: number,
  v0: number,
  v1: number,
  note: string,
): Cue[] =>
  Array.from({ length: count }, (_, i) => ({
    from: base + first + i * gap,
    src: a(i % 2 === 0 ? 'pop' : 'transition-snap'),
    volume: (v0 + ((v1 - v0) * i) / Math.max(1, count - 1)) * (i % 2 === 0 ? 1 : 0.8),
    dur: 20,
    note: `${note} ${i + 1}/${count}`,
  }));

export const SFX: Cue[] = [
  // ---- 1. brand open ----
  { from: S.brandOpen.from + 4, src: a('transition-soft'), volume: 0.26, note: 'film in' },
  { from: S.brandOpen.from + 20, src: a('shimmer-sparkle-sweep'), volume: 0.3, dur: 60, note: 'wordmark begins to draw' },
  { from: S.brandOpen.from + 68, src: a('transition-snap'), volume: 0.3, dur: 20, note: 'wordmark settles (START+DUR)' },
  { from: S.brandOpen.from + 94, src: a('whoosh-fast'), volume: 0.34, dur: 40, note: 'group lifts out, hand off to the app' },

  // ---- 2. app debut ----
  { from: S.appDebut.from + 6, src: a('whoosh-big'), volume: 0.4, dur: 50, note: 'accent frame draws, camera arcs' },
  { from: S.appDebut.from + 63, src: a('drum-impact-subtle'), volume: 0.38, dur: 45, note: 'all layers land on one frame' },

  // ---- 3. title A ----
  { from: S.titleA.from + 2, src: a('swoosh-quick'), volume: 0.32, dur: 24, note: 'title card in (film-wide title sound)' },

  // ---- 4. queue fills ----
  { from: S.queue.from + 4, src: a('sweep-fast-small'), volume: 0.24, dur: 24, note: 'camera settles onto the list' },
  // rows land at cue+12 where cue = 12 + i*9
  ...run(S.queue.from, 24, 9, 8, 0.34, 0.2, 'row seats'),

  // ---- 5. throughput ----
  { from: S.throughput.from + 4, src: a('impact-zoom-quick'), volume: 0.34, dur: 36, note: 'push into the status bar' },
  { from: S.throughput.from + 22, src: a('click-camera'), volume: 0.5, dur: 16, note: 'CUT — flash cut on the odometer' },
  { from: S.throughput.from + 52, src: a('sub-bass-knock'), volume: 0.4, dur: 92, note: '43 MB/s locks' },

  // ---- 6. detail tour ----
  { from: S.detail.from + 2, src: a('swoosh-quick'), volume: 0.22, dur: 24, note: 'graze begins' },
  // six blocks seat at t = 0.18 -> 0.80 of TRAVEL = 95, i.e. every 11.78f
  ...run(S.detail.from, 17, 12, 6, 0.3, 0.18, 'detail block seats'),

  // ---- 7. line carry (the signature transition) ----
  { from: S.carry.from + 14, src: a('sweep-fast-small'), volume: 0.3, dur: 24, note: 'the bar runs out of row' },
  { from: S.carry.from + 24, src: a('bass-transition-pulse'), volume: 0.3, dur: 66, note: 'the 60f traverse' },
  { from: S.carry.from + 102, src: a('transition-snap'), volume: 0.34, dur: 20, note: 'the corner closes the frame (CLOSE end)' },
  { from: S.carry.from + 108, src: a('sparkle'), volume: 0.3, dur: 60, note: 'the piece map appears inside it' },

  // ---- 8. piece map ----
  // six cells light up at FIRST=20 with GAP=12
  ...run(S.pieces.from, 20, 12, 6, 0.3, 0.18, 'cell lights'),
  { from: S.pieces.from + 100, src: a('whoosh-fast'), volume: 0.24, dur: 36, note: 'closing push' },

  // ---- 9. SFTP transfer ----
  { from: S.sftp.from + 12, src: a('click-camera'), volume: 0.42, dur: 16, note: 'PICK — the remote row is taken' },
  { from: S.sftp.from + 40, src: a('whoosh-big'), volume: 0.42, dur: 60, note: 'the flight' },
  { from: S.sftp.from + 104, src: a('transition-snap'), volume: 0.34, dur: 20, note: 'touchdown in the queue' },
  { from: S.sftp.from + 116, src: a('sweep-fast-small'), volume: 0.26, dur: 24, note: 'camera takeover' },

  // ---- 10. title B ----
  { from: S.titleB.from + 2, src: a('swoosh-quick'), volume: 0.32, dur: 24, note: 'title card in' },

  // ---- 11. browser capture ----
  { from: S.capture.from + 2, src: a('transition-soft'), volume: 0.26, dur: 38, note: 'new scene' },
  { from: S.capture.from + 20, src: a('whoosh-fast'), volume: 0.34, dur: 40, note: 'the page turns' },
  ...run(S.capture.from, 52, 4, 5, 0.28, 0.18, 'browser mark pops'),
  { from: S.capture.from + 66, src: a('shimmer-sparkle-sweep'), volume: 0.3, dur: 60, note: 'five pipes connect' },

  // ---- 12. menu bar ----
  { from: S.menubar.from + 2, src: a('transition-soft'), volume: 0.26, dur: 38, note: 'new scene' },
  { from: S.menubar.from + 12, src: a('sweep-fast-small'), volume: 0.26, dur: 24, note: 'desktop dims and blurs' },
  { from: S.menubar.from + 22, src: a('transition-snap'), volume: 0.34, dur: 20, note: 'popover seats after overshoot' },
  ...run(S.menubar.from, 32, 4, 4, 0.26, 0.18, 'popover row'),
  { from: S.menubar.from + 60, src: a('pop'), volume: 0.34, dur: 16, note: 'row selection (a UI highlight takes a pop, not a shutter)' },

  // ---- 13. portal cube ----
  { from: S.portal.from + 40, src: a('whoosh-big'), volume: 0.4, dur: 60, note: 'TURN — the cube rotates' },
  { from: S.portal.from + 68, src: a('drum-impact-subtle'), volume: 0.36, dur: 45, note: 'the portal face lands' },

  // ---- 14. theme sweeps ----
  { from: S.themes.from + 2, src: a('transition-soft'), volume: 0.24, dur: 38, note: 'new scene' },
  { from: S.themes.from + 20, src: a('sweep-scifi-fast'), volume: 0.34, dur: 36, note: 'sweep 1 crosses frame' },
  { from: S.themes.from + 62, src: a('sweep-scifi-fast'), volume: 0.3, dur: 36, note: 'sweep 2 crosses frame' },
  { from: S.themes.from + 104, src: a('sweep-scifi-fast'), volume: 0.28, dur: 36, note: 'sweep 3 crosses frame' },
  { from: S.themes.from + 126, src: a('transition-snap'), volume: 0.24, dur: 20, note: 'the last theme settles' },

  /* ---- 15. outro: riser → impact (loudest cue) → sparkle. `riser-trailer` is END-anchored (`raw:true`):
     a 77f crescendo peaking on its last frame, started 77f early so it runs INTO the impact. */
  { from: S.outro.from + 42 - 77, src: a('riser-trailer'), volume: 0.42, dur: 77, raw: true, note: 'the group photo assembles, building into the stamp' },
  { from: S.outro.from + 8, src: a('whoosh-fast'), volume: 0.3, dur: 40, note: 'nine elements fly in (covered, not counted)' },
  { from: S.outro.from + 46, src: a('impact-cine'), volume: 0.55, dur: 90, note: 'the wordmark lands — loudest cue in the film' },
  { from: S.outro.from + 64, src: a('sparkle'), volume: 0.34, dur: 70, note: 'the rule flashes' },
];
