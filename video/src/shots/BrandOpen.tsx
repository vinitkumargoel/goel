import React from 'react';
import { AbsoluteFill, Img, interpolate, staticFile, useCurrentFrame, Easing } from 'remotion';
import { C, FONT } from '../theme';
import { mulberry32 } from '../lib/helpers/rand';

/* `vx`/`vw` must crop each viewBox to its ink + BEARING, or a narrow glyph like `l` floats. */
const BEARING = 4;
const GLYPHS: Record<string, { d: string; vx: number; vw: number }> = {
  G: { d: 'M 64 16 C 56 5, 21 3, 14 20 C 7 38, 18 60, 40 59 C 58 58, 65 48, 65 36 L 45 36', vx: 11, vw: 55 },
  o: { d: 'M 39 24 C 24 24, 17 32, 17 42 C 17 52, 24 59, 39 59 C 54 59, 61 52, 61 42 C 61 32, 54 24, 39 24', vx: 17, vw: 44 },
  e: { d: 'M 17 43 L 59 43 C 59 31, 50 24, 38 24 C 25 24, 17 32, 17 42 C 17 52, 26 59, 38 59 C 48 59, 55 55, 58 50', vx: 17, vw: 42 },
  l: { d: 'M 39 5 L 39 59', vx: 39, vw: 1 },
  '°': { d: 'M 26 8 C 17 8, 12 13, 12 20 C 12 27, 17 32, 26 32 C 35 32, 40 27, 40 20 C 40 13, 35 8, 26 8', vx: 12, vw: 28 },
};

const WORD = ['G', 'o', 'e', 'l', '°'];
const START = 6;
const GS = 1.85;
const GAP = 0.55 * 64 - 2 * BEARING;
const DUR = 46;

/* Seeded, never Math.random: an unseeded orb bed renders differently on every frame and every machine. */
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
  const e = p < 0.5 ? 2 * p * p : 1 - Math.pow(-2 * p + 2, 2) / 2;
  const doneGlow = interpolate(frame, [START + DUR, START + DUR + 8], [1, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const glowAmt = p >= 1 ? doneGlow : p > 0.7 ? (p - 0.7) / 0.3 : 0;

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
