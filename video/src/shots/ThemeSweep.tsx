import React from 'react';
import { AbsoluteFill, Img, interpolate, staticFile, useCurrentFrame, Easing } from 'remotion';
import { C, FONT, PAGE } from '../theme';

const CL = { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' } as const;

const SLANT = 1080 * Math.tan((15 * Math.PI) / 180);
const END = 1920 + SLANT + 40;

const ZOOM = 1920 / PAGE.w;
const PH = PAGE.h * ZOOM;

const SWEEPS: [number, number][] = [
  [12, 42],
  [54, 84],
  [96, 126],
];

const THEMES = [
  { file: 'theme-frost-dark-full.png', name: 'Frost Dark' },
  { file: 'theme-frost-light-full.png', name: 'Frost Light' },
  { file: 'theme-dracula-full.png', name: 'Dracula' },
  { file: 'theme-nord-full.png', name: 'Nord' },
];

const Layer: React.FC<{ i: number; label: string; file: string; dark: boolean }> = ({
  label,
  file,
  dark,
}) => (
  <div style={{ position: 'absolute', left: 0, top: (1080 - PH) / 2, width: 1920, height: PH }}>
    <Img src={staticFile(`textures/${file}`)} style={{ width: 1920, height: PH, display: 'block' }} />
    <div
      style={{
        position: 'absolute',
        left: 92,
        top: 44,
        font: `500 20px/1 ${FONT.mono}`,
        letterSpacing: '0.24em',
        textTransform: 'uppercase',
        color: dark ? 'rgba(232,234,240,0.72)' : 'rgba(28,31,40,0.68)',
      }}
    >
      {label}
    </div>
  </div>
);

export const ThemeSweep: React.FC<{ durationInFrames: number }> = () => {
  const frame = useCurrentFrame();

  return (
    <AbsoluteFill style={{ background: C.canvas, overflow: 'hidden' }}>
      {THEMES.map((t, i) => {
        if (i === 0) {
          if (frame > SWEEPS[0][1] + 2) return null;
          return <Layer key={i} i={i} label={t.name} file={t.file} dark />;
        }
        const [s0, s1] = SWEEPS[i - 1];
        if (frame < s0) return null;
        if (i < THEMES.length - 1 && frame > SWEEPS[i][1] + 2) return null;

        const p = interpolate(frame, [s0, s1], [-20, END], { ...CL, easing: Easing.out(Easing.poly(3)) });
        /* Must overshoot OUTWARD: a sub-1 settle exposes a near-black strip down both edges. */
        const settle = interpolate(frame, [s1, s1 + 1, s1 + 12], [1, 1.015, 1], {
          ...CL,
          easing: Easing.out(Easing.cubic),
        });
        return (
          <div
            key={i}
            style={{
              position: 'absolute',
              inset: 0,
              clipPath: `polygon(0 0, ${p}px 0, ${p - SLANT}px 1080px, 0 1080px)`,
              transform: `scale(${settle})`,
              transformOrigin: '50% 50%',
            }}
          >
            <Layer i={i} label={t.name} file={t.file} dark={i !== 1} />
          </div>
        );
      })}

      {SWEEPS.map(([s0, s1], i) => {
        if (frame < s0 || frame >= s1 + 2) return null;
        const p = interpolate(frame, [s0, s1], [-20, END], { ...CL, easing: Easing.out(Easing.poly(3)) });
        const op = interpolate(frame, [s0, s0 + 4, s1 - 4, s1 + 2], [0, 1, 1, 0], CL);
        return (
          <div
            key={i}
            style={{
              position: 'absolute',
              left: p - SLANT / 2 - 2,
              top: 540 - 620,
              width: 4,
              height: 1240,
              background: '#ffffff',
              boxShadow: '0 0 18px 4px rgba(255,255,255,0.75)',
              transform: 'rotate(15deg)',
              transformOrigin: '50% 50%',
              opacity: op,
            }}
          />
        );
      })}
    </AbsoluteFill>
  );
};
