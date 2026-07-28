import React from 'react';
import { AbsoluteFill, Img, interpolate, staticFile, useCurrentFrame, Easing } from 'remotion';
import { C } from '../theme';
import { mulberry32 } from '../lib/helpers/rand';

const easeFall = Easing.bezier(0.5, 0.05, 0.6, 1);

const FloatWrap: React.FC<{ h: number; children: React.ReactNode }> = ({ h, children }) => (
  <div style={{ position: 'relative' }}>
    {h > 1 && (
      <div
        style={{
          position: 'absolute',
          inset: 0,
          transform: `translate(${h * 0.26}px, ${h * 0.48}px) scale(${1 + h * 0.0012})`,
          filter: `blur(${2.5 + h * 0.09}px) brightness(0.32) saturate(0.4)`,
          opacity: Math.min(0.4, 0.16 + h * 0.005),
          pointerEvents: 'none',
        }}
      >
        {children}
      </div>
    )}
    <div style={{ transform: `translate(${-h * 0.36}px, ${-h * 0.82}px)` }}>{children}</div>
  </div>
);

const LAND = 0.52;
const FALL = 0.3;
const liftOf = (t: number, H: number) => {
  const p = Math.min(1, Math.max(0, (t - (LAND - FALL)) / FALL));
  return (1 - easeFall(p)) * H;
};

const PW = 1360;
const PH = 721;
const PL = 1000;
const FRAME_D = `M 0 ${PH / 2} L 0 0 L ${PW} 0 L ${PW} ${PH} L 0 ${PH} Z`;

const rng = mulberry32(20260726);
const HUES = [C.accent, C.indigo, C.teal, C.purple];
const BG_FRAMES = Array.from({ length: 16 }).map(() => ({
  x: rng() * 2000 - 120,
  y: rng() * 1100 - 60,
  w: 160 + rng() * 480,
  h: 70 + rng() * 220,
  hue: HUES[Math.floor(rng() * HUES.length)],
  phase: rng() * 90,
  period: 55 + rng() * 70,
  skew: -14 + rng() * 10,
}));

const Layer: React.FC<{
  src: string;
  x: number;
  y: number;
  w: number;
  h: number;
  lift: number;
}> = ({ src, x, y, w, h, lift }) => (
  <div style={{ position: 'absolute', left: x, top: y, width: w, height: h }}>
    <FloatWrap h={lift}>
      <Img src={staticFile(src)} style={{ display: 'block', width: w, height: h }} />
    </FloatWrap>
  </div>
);

export const AppDebut: React.FC<{ durationInFrames: number }> = ({ durationInFrames }) => {
  const frame = useCurrentFrame();
  const D = durationInFrames;

  const trace = interpolate(frame, [0, 14], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.bezier(0.3, 0.1, 0.3, 1),
  });
  const lit = interpolate(frame, [8, 30], [0.25, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.bezier(0.35, 0, 0.3, 1),
  });
  const frameLine = interpolate(frame, [D - 30, D - 4], [1, 0.35], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const rimGlow = interpolate(frame, [0, 20, D - 20, D], [0.7, 1, 0.75, 0.5], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const bgLit = interpolate(frame, [0, 30, D - 24, D], [0.3, 1, 0.85, 0.1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

  const orbit = interpolate(frame, [0, D - 34], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.bezier(0.42, 0.05, 0.32, 1),
  });
  const rotY = 26 - 26 * orbit;
  const rotX = 5 - 4 * orbit;
  const rotZ = 2.4 - 2.8 * orbit;
  const scale = 0.9 + 0.1 * Math.sin(orbit * Math.PI) + 0.02 * orbit;
  const pOrigin = 30 + 34 * orbit;
  const headP = trace * (PL / 2);

  const drop = interpolate(frame, [10, D - 6], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const L = (H: number) => liftOf(drop, H);

  const fit = 1920 / PW;

  return (
    <AbsoluteFill style={{ background: C.canvas, overflow: 'hidden' }}>
      <svg width={1920} height={1080} style={{ position: 'absolute' }}>
        <defs>
          <filter id="obgblur" x="-60%" y="-60%" width="220%" height="220%">
            <feGaussianBlur stdDeviation={7} />
          </filter>
        </defs>
        {BG_FRAMES.map((b, i) => {
          const breath = 0.5 + 0.5 * Math.sin(((frame + b.phase) / b.period) * Math.PI * 2);
          const op = bgLit * (0.1 + 0.24 * breath);
          return (
            <g key={i} transform={`translate(${b.x} ${b.y}) skewY(${b.skew * 0.4}) skewX(${b.skew})`}>
              <rect
                width={b.w}
                height={b.h}
                rx={4}
                fill="none"
                stroke={b.hue}
                strokeWidth={7}
                filter="url(#obgblur)"
                opacity={op * 0.8}
              />
              <rect width={b.w} height={b.h} rx={4} fill="none" stroke={b.hue} strokeWidth={2} opacity={op} />
            </g>
          );
        })}
      </svg>

      <div
        style={{
          position: 'absolute',
          inset: 0,
          perspective: 1500,
          perspectiveOrigin: `${pOrigin}% 44%`,
        }}
      >
        <div
          style={{
            position: 'absolute',
            left: (1920 - PW * fit) / 2,
            top: (1080 - PH * fit) / 2,
            width: PW * fit,
            height: PH * fit,
            transform: `scale(${scale}) rotateY(${rotY}deg) rotateX(${rotX}deg) rotateZ(${rotZ}deg)`,
            transformStyle: 'preserve-3d',
          }}
        >
          <div
            style={{
              position: 'absolute',
              inset: 0,
              zoom: fit,
              opacity: trace > 0.4 ? 1 : 0,
              filter: `brightness(${Math.max(0.05, lit)})`,
            }}
          >
            <Img
              src={staticFile('textures/app-window-empty.png')}
              style={{ position: 'absolute', width: PW, height: PH, borderRadius: 12 }}
            />
            <div style={{ position: 'absolute', inset: 0, borderRadius: 12, overflow: 'hidden' }}>
              <Layer src="textures/sidebar.png" x={0} y={51} w={200} h={633} lift={L(150)} />
              <Layer src="textures/list.png" x={200} y={51} w={821} h={633} lift={L(178)} />
              <Layer src="textures/detail.png" x={1021} y={51} w={339} h={633} lift={L(150)} />
              <Layer src="textures/statusbar.png" x={0} y={684} w={1360} h={37} lift={L(122)} />
            </div>
            {/* Must stay outside the clip: the toolbar's slot is y=0 and it hovers above it. */}
            <Layer src="textures/toolbar.png" x={0} y={0} w={1360} h={51} lift={L(122)} />
            <div
              style={{
                position: 'absolute',
                inset: 0,
                borderRadius: 12,
                background: 'linear-gradient(150deg, rgba(24,28,54,0.5), rgba(0,0,0,0.78))',
                opacity: 1 - lit,
              }}
            />
          </div>

          <div
            style={{
              position: 'absolute',
              left: -10,
              top: -10,
              width: PW * fit + 20,
              height: PH * fit + 20,
              borderRadius: 14,
              opacity: rimGlow * Math.min(1, trace * 1.6),
              boxShadow: `-18px -8px 42px 6px ${C.accent}52, 22px 24px 56px 12px ${C.teal}2e, 0 14px 80px 22px ${C.indigo}24`,
            }}
          />

          <svg
            width={PW * fit + 80}
            height={PH * fit + 80}
            /* Pad is CSS px on a box `fit`x the user-unit size: a literal 40 skews the aspect ratio. */
            viewBox={`${-40 / fit} ${-40 / fit} ${PW + 80 / fit} ${PH + 80 / fit}`}
            style={{ position: 'absolute', left: -40, top: -40 }}
          >
            <defs>
              <linearGradient id="gfg" gradientUnits="userSpaceOnUse" x1={0} y1={0} x2={PW} y2={PH}>
                <stop offset="0%" stopColor={C.accent} />
                <stop offset="42%" stopColor={C.indigo} />
                <stop offset="78%" stopColor={C.teal} />
                <stop offset="100%" stopColor={C.accent} />
              </linearGradient>
              <filter id="gfblur" x="-40%" y="-40%" width="180%" height="180%">
                <feGaussianBlur stdDeviation={10} />
              </filter>
              <filter id="gfblur2" x="-40%" y="-40%" width="180%" height="180%">
                <feGaussianBlur stdDeviation={3} />
              </filter>
            </defs>
            {[1, -1].map((dir) => (
              <g key={dir}>
                <path
                  d={FRAME_D}
                  pathLength={PL}
                  fill="none"
                  stroke="url(#gfg)"
                  strokeWidth={14}
                  strokeLinecap="butt"
                  filter="url(#gfblur)"
                  strokeDasharray={`${headP} ${PL}`}
                  strokeDashoffset={dir === 1 ? 0 : -(PL - headP)}
                  opacity={0.6 * rimGlow}
                />
                <path
                  d={FRAME_D}
                  pathLength={PL}
                  fill="none"
                  stroke="url(#gfg)"
                  strokeWidth={3.5}
                  strokeLinecap="butt"
                  strokeDasharray={`${headP} ${PL}`}
                  strokeDashoffset={dir === 1 ? 0 : -(PL - headP)}
                  opacity={0.95 * frameLine}
                />
                {trace < 1 && (
                  <path
                    d={FRAME_D}
                    pathLength={PL}
                    fill="none"
                    stroke="#ffffff"
                    strokeWidth={6}
                    strokeLinecap="round"
                    filter="url(#gfblur2)"
                    strokeDasharray={`8 ${PL}`}
                    strokeDashoffset={dir === 1 ? -Math.max(0, headP - 8) : -(PL - headP)}
                    opacity={0.95}
                  />
                )}
              </g>
            ))}
          </svg>
        </div>
      </div>
    </AbsoluteFill>
  );
};
