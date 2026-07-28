import React from 'react';
import { AbsoluteFill, Img, interpolate, staticFile, useCurrentFrame, Easing } from 'remotion';
import { C, FONT } from '../theme';
import { mulberry32 } from '../lib/helpers/rand';

const PATH = 'M 400 705 L 2600 705 L 2600 375 L 3160 375 L 3160 705 L 2600 705';
const SEGS: Array<[number, number, number, number, number]> = [
  [400, 705, 2600, 705, 2200],
  [2600, 705, 2600, 375, 330],
  [2600, 375, 3160, 375, 560],
  [3160, 375, 3160, 705, 330],
  [3160, 705, 2600, 705, 560],
];
const TOTAL_LEN = 3980;

// Derived: page point (383,524) is (323,464) inside the window, so the bar meets the path at (400,705).
const WIN_X = 77;
const WIN_Y = 241;

const B_FRAME = { x: 2600, y: 375, w: 560, h: 330 };
const PMAP = { w: 302, h: 259.46, scale: 1.15 };

const ORBS = Array.from({ length: 15 }, (_, i) => {
  const r = mulberry32(0x7c11 + i * 613);
  return {
    x: 300 + r() * 3300,
    y: 120 + r() * 840,
    rad: 220 + r() * 340,
    hue: [C.accent, C.indigo, C.teal][Math.floor(r() * 3)],
    period: 190 + r() * 200,
    phase: r() * 220,
    amp: 20 + r() * 34,
    base: 0.14 + r() * 0.15,
  };
});

const BAR_LEN = 192; // the real progress bar's width in page px
const FILL = [0, 14] as const;
const EXTEND = [14, 24] as const;
const MOVE = [24, 84] as const;
const CLOSE = [84, 102] as const;
const CONTENT = [102, 114] as const;

const tipAt = (drawn: number): [number, number] => {
  let d = Math.max(0, Math.min(drawn, TOTAL_LEN));
  for (const [x1, y1, x2, y2, len] of SEGS) {
    if (d <= len) {
      const t = d / len;
      return [x1 + (x2 - x1) * t, y1 + (y2 - y1) * t];
    }
    d -= len;
  }
  return [2600, 705];
};

export const LineCarry: React.FC<{ durationInFrames: number }> = () => {
  const frame = useCurrentFrame();

  const cam = interpolate(frame, MOVE, [0, 1920], {
    easing: Easing.inOut(Easing.cubic),
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

  let drawn: number;
  if (frame < FILL[1]) {
    drawn = interpolate(frame, FILL, [0, BAR_LEN], {
      easing: Easing.out(Easing.cubic),
      extrapolateLeft: 'clamp',
      extrapolateRight: 'clamp',
    });
  } else if (frame < EXTEND[1]) {
    drawn = interpolate(frame, EXTEND, [BAR_LEN, 1100], { extrapolateRight: 'clamp' });
  } else if (frame < MOVE[1]) {
    drawn = 1100 + cam; // Pen and camera must advance at one speed or the tip leaves frame
  } else {
    drawn = interpolate(frame, CLOSE, [3020, TOTAL_LEN], {
      easing: Easing.out(Easing.cubic),
      extrapolateLeft: 'clamp',
      extrapolateRight: 'clamp',
    });
  }

  const contentOpacity = interpolate(frame, CONTENT, [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

  const tipMounted = frame < CONTENT[0] + 6;
  const tipOpacity = interpolate(frame, [CONTENT[0], CONTENT[0] + 6], [1, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const [tx, ty] = tipAt(drawn);

  return (
    <AbsoluteFill style={{ background: C.canvas, overflow: 'hidden' }}>
      <div
        style={{
          position: 'absolute',
          width: 3840,
          height: 1080,
          transform: `translateX(${-cam}px)`,
        }}
      >
        <div
          style={{
            position: 'absolute',
            left: 1220,
            top: 0,
            width: 2620,
            height: 1080,
            background: `linear-gradient(90deg, rgba(0,0,0,0) 0%, ${C.canvasLift} 27%, ${C.canvasLift} 100%)`,
          }}
        />

        {ORBS.map((o, i) => {
          const t = (frame + o.phase) / o.period;
          const breathe = 0.5 + 0.5 * Math.sin(t * Math.PI * 2 + 1.1);
          return (
            <div
              key={i}
              style={{
                position: 'absolute',
                left: o.x - o.rad,
                top: o.y - o.rad + Math.sin(t * Math.PI * 2) * o.amp,
                width: o.rad * 2,
                height: o.rad * 2,
                borderRadius: '50%',
                background: `radial-gradient(circle at center, ${o.hue} 0%, rgba(0,0,0,0) 68%)`,
                opacity: o.base * (0.6 + 0.8 * breathe),
                filter: 'blur(44px)',
              }}
            />
          );
        })}

        <Img
          src={staticFile('textures/app-window.png')}
          style={{
            position: 'absolute',
            left: WIN_X,
            top: WIN_Y,
            width: 1360,
            height: 721,
            filter: `brightness(${interpolate(cam, [0, 900], [1, 0.5], {
              extrapolateLeft: 'clamp',
              extrapolateRight: 'clamp',
            })})`,
          }}
        />

        <svg width={3840} height={1080} style={{ position: 'absolute', inset: 0, pointerEvents: 'none' }}>
          <defs>
            <filter id="tipGlow" x="-200%" y="-200%" width="500%" height="500%">
              <feGaussianBlur stdDeviation="24" />
            </filter>
          </defs>
          <path
            d={PATH}
            fill="none"
            stroke={C.accent}
            strokeWidth={6}
            strokeLinecap="round"
            strokeLinejoin="round"
            strokeDasharray={TOTAL_LEN}
            strokeDashoffset={TOTAL_LEN - drawn}
          />
          {tipMounted && (
            <g opacity={tipOpacity}>
              <circle cx={tx} cy={ty} r={38} fill={C.accent} opacity={0.5} filter="url(#tipGlow)" />
              <circle cx={tx} cy={ty} r={11} fill={C.accent} />
            </g>
          )}
        </svg>

        <div
          style={{
            position: 'absolute',
            left: B_FRAME.x,
            top: B_FRAME.y,
            width: B_FRAME.w,
            height: B_FRAME.h,
            opacity: contentOpacity,
            display: 'flex',
            flexDirection: 'column',
            alignItems: 'center',
            justifyContent: 'center',
          }}
        >
          <Img
            src={staticFile('textures/tcell2.png')}
            style={{ width: PMAP.w * PMAP.scale, height: PMAP.h * PMAP.scale }}
          />
        </div>
        <div
          style={{
            position: 'absolute',
            left: B_FRAME.x,
            top: B_FRAME.y - 44,
            opacity: contentOpacity,
            font: `400 16px/1 ${FONT.mono}`,
            letterSpacing: '0.18em',
            textTransform: 'uppercase',
            color: C.inkFaint,
          }}
        >
          the same bar, piece by piece
        </div>
      </div>
    </AbsoluteFill>
  );
};
