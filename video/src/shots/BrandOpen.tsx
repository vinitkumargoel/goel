/* Shot 1 — brand open.
 *
 * Card: letterspace-materialize (gallery style-key `letterspace-materialize`)
 * Exact demo read: demos/letterspace-materialize/LetterspaceMaterialize.tsx
 * Ambient bed: glow-flyline-moves / `glow-orb-ambient`
 *
 * Card params preserved verbatim: all characters share ONE progress `p` (same
 * start frame, same finish frame, zero per-char stagger — the card's 命门),
 * pathLength-normalised continuous growth (no masked segments), thin strokes,
 * wide letter-spacing, easeInOut draw curve, >=30f settled hold (f62 -> f92,
 * during which the ambient bed is frozen too — see REST).
 *
 * Reskin: the demo draws SUPERHUMAN in caps on a dusk gradient. Goel°'s
 * wordmark is mixed-case with a raised degree, so the skeleton glyphs below are
 * drawn for G/o/e/l/° in the demo's 78x64 frame and stroke weight. Case is a
 * skinning choice; every timing and continuity parameter is the demo's.
 */
import React from 'react';
import { AbsoluteFill, Img, interpolate, staticFile, useCurrentFrame, Easing } from 'remotion';
import { C, FONT } from '../theme';
import { mulberry32 } from '../lib/helpers/rand';

/* Skeleton glyphs on the demo's 64-unit cap height (glyph face y 5-59).
   Single-line strokes — font outlines are double-line and read wrong drawn.
   `vx`/`vw` crop each glyph's viewBox to its own ink plus a uniform BEARING, so
   the visual gap between any two neighbours is the same. The demo could get away
   with one fixed 78-wide box because SUPERHUMAN is ten glyphs of near-equal
   width; here `l` (1 unit of ink) and `°` (28) would otherwise float in the
   middle of boxes sized for `G` (55), and the word stops reading as a word. */
const BEARING = 4;
const GLYPHS: Record<string, { d: string; vx: number; vw: number }> = {
  G: { d: 'M 64 16 C 56 5, 21 3, 14 20 C 7 38, 18 60, 40 59 C 58 58, 65 48, 65 36 L 45 36', vx: 11, vw: 55 },
  o: { d: 'M 39 24 C 24 24, 17 32, 17 42 C 17 52, 24 59, 39 59 C 54 59, 61 52, 61 42 C 61 32, 54 24, 39 24', vx: 17, vw: 44 },
  e: { d: 'M 17 43 L 59 43 C 59 31, 50 24, 38 24 C 25 24, 17 32, 17 42 C 17 52, 26 59, 38 59 C 48 59, 55 55, 58 50', vx: 17, vw: 42 },
  l: { d: 'M 39 5 L 39 59', vx: 39, vw: 1 },
  '°': { d: 'M 26 8 C 17 8, 12 13, 12 20 C 12 27, 17 32, 26 32 C 35 32, 40 27, 40 20 C 40 13, 35 8, 26 8', vx: 12, vw: 28 },
};

const WORD = ['G', 'o', 'e', 'l', '°'];
const START = 6; // unified start frame — no per-char offset
/* Rendered at the demo's 64px cap height on a 1080 canvas the word is far too
   small for a brand open, so the whole set is drawn 1.85x larger. Scaling the
   SVG viewport (not a CSS transform) scales the stroke with it, so the card's
   thin-stroke ratio survives verbatim.

   Tracking: the demo's ink-to-ink gap is 46 units on a 64-unit cap height —
   0.72em. That is a ten-letter all-caps mark; on a four-glyph mixed-case one it
   spaces the word into rubble. GAP is set so ink-to-ink lands at 0.55em, which
   is still unambiguously the card's "wide letter-spacing" register and is the
   widest value at which "Goel" still reads as one word. */
const GS = 1.85;
const GAP = 0.55 * 64 - 2 * BEARING;
/* Unified finish frame. The demo draws over 52f; this is 46, and the six frames
   come off the front and back of the draw rather than out of the hold, because
   the card's `>=30f settled hold` is a hard parameter and the 52 is not. With
   START=6 the word is complete at f52, the glow has annealed by f60, the tagline
   has landed by f62 and the exit does not begin until f92 — thirty frames in
   which nothing on screen moves at all, which is what a brand open is for. */
const DUR = 46;

/* glow-orb-ambient: slow drifting soft orbs as the backdrop bed. Deterministic
   seed, so every render is frame-identical. */
const ORBS = Array.from({ length: 7 }, (_, i) => {
  const r = mulberry32(0x9e01 + i * 977);
  return {
    x: r() * 1920,
    y: 180 + r() * 760,
    rad: 240 + r() * 380,
    hue: [C.accent, C.indigo, C.teal][Math.floor(r() * 3)],
    period: 150 + r() * 190,
    phase: r() * 200,
    amp: 26 + r() * 44,
    base: 0.05 + r() * 0.07,
  };
});

/* The bed comes to rest with the wordmark. Left running, the orbs drift through
   the whole hold and then hard-cut at the shot boundary, so the "settled hold"
   is settled everywhere except the background and the cut has a visible jump in
   it. Easing the bed's own clock to a stop at f62 freezes the frame properly:
   from f62 the composition is literally identical frame to frame, and the cut
   into the app shot is a cut from a still. */
const REST = 62;
const orbClock = (frame: number): number =>
  frame < 40
    ? frame
    : interpolate(frame, [40, REST], [40, REST], {
        extrapolateRight: 'clamp',
        easing: Easing.out(Easing.cubic),
      });

export const BrandOpen: React.FC<{ durationInFrames: number }> = ({ durationInFrames }) => {
  const frame = useCurrentFrame();

  const p = interpolate(frame, [START, START + DUR], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  // easeInOut — slow lift-off, even middle, soft finish (the handwriting feel)
  const e = p < 0.5 ? 2 * p * p : 1 - Math.pow(-2 * p + 2, 2) / 2;
  const doneGlow = interpolate(frame, [START + DUR, START + DUR + 8], [1, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const glowAmt = p >= 1 ? doneGlow : p > 0.7 ? (p - 0.7) / 0.3 : 0;

  // the icon settles first and holds — it is the anchor the wordmark grows beside
  const iconIn = interpolate(frame, [0, 22], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.bezier(0.16, 1, 0.3, 1),
  });
  const iconY = (1 - iconIn) * 26;

  const tagIn = interpolate(frame, [START + DUR - 4, START + DUR + 10], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.bezier(0, 0, 0.2, 1),
  });

  // hand off to the app shot: the whole group eases up and out at the very end
  const exit = interpolate(frame, [durationInFrames - 8, durationInFrames], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.bezier(0.4, 0, 1, 1),
  });

  return (
    <AbsoluteFill
      style={{
        background: `radial-gradient(120% 90% at 50% 42%, ${C.canvasLift} 0%, ${C.canvas} 66%)`,
        alignItems: 'center',
        justifyContent: 'center',
        overflow: 'hidden',
      }}
    >
      {ORBS.map((o, i) => {
        const t = (orbClock(frame) + o.phase) / o.period;
        const drift = Math.sin(t * Math.PI * 2) * o.amp;
        const breathe = 0.5 + 0.5 * Math.sin(t * Math.PI * 2 + 1.1);
        return (
          <div
            key={i}
            style={{
              position: 'absolute',
              left: o.x - o.rad,
              top: o.y - o.rad + drift,
              width: o.rad * 2,
              height: o.rad * 2,
              borderRadius: '50%',
              background: `radial-gradient(circle at center, ${o.hue} 0%, rgba(0,0,0,0) 68%)`,
              opacity: o.base * (0.6 + 0.8 * breathe),
              filter: 'blur(46px)',
            }}
          />
        );
      })}

      <div
        style={{
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          transform: `translateY(${-exit * 54}px)`,
          opacity: 1 - exit,
        }}
      >
        <Img
          src={staticFile('icon.png')}
          style={{
            width: 132,
            height: 132,
            marginBottom: 46,
            opacity: iconIn,
            transform: `translateY(${iconY}px) scale(${0.94 + 0.06 * iconIn})`,
            filter: `drop-shadow(0 24px 54px rgba(0,0,0,0.6)) drop-shadow(0 0 46px ${C.accent}38)`,
          }}
        />

        {/* wide letter-spacing wordmark: all characters draw in parallel */}
        <div style={{ display: 'flex', gap: GAP * GS, alignItems: 'flex-end' }}>
          {WORD.map((ch, li) => {
            const g = GLYPHS[ch];
            const vw = g.vw + BEARING * 2;
            return (
              <svg
                key={li}
                width={vw * GS}
                height={64 * GS}
                viewBox={`${g.vx - BEARING} 0 ${vw} 64`}
                style={{ overflow: 'visible', display: 'block' }}
              >
                {p > 0 && (
                  <path
                    d={g.d}
                    fill="none"
                    // the degree is the brand's accent mark, in the app icon and
                    // again on the outro wordmark — it carries colour here too
                    stroke={ch === '°' ? C.accent : '#f2f4fb'}
                    strokeWidth={5.5}
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    pathLength={1}
                    strokeDasharray={1}
                    strokeDashoffset={1 - e}
                    style={{
                      filter: `drop-shadow(0 0 ${6 + glowAmt * 10}px rgba(138,162,255,${
                        0.35 + glowAmt * 0.4
                      }))`,
                    }}
                  />
                )}
              </svg>
            );
          })}
        </div>

        <div
          style={{
            marginTop: 40,
            font: `400 21px/1 ${FONT.ui}`,
            letterSpacing: '0.16em',
            color: C.inkSoft,
            opacity: tagIn,
            transform: `translateY(${(1 - tagIn) * 9}px)`,
          }}
        >
          Every download. One queue.
        </div>
      </div>
    </AbsoluteFill>
  );
};
