/* Shot 7, the signature line-carry (<=1 per film); demo geometry verbatim. 命门: `drawn = 1100 + cam`
 * during travel pins the pen tip at x=1500 — lose the tip, lose the transition; tip unmounts on fade. */
import React from 'react';
import { AbsoluteFill, Img, interpolate, staticFile, useCurrentFrame, Easing } from 'remotion';
import { C, FONT } from '../theme';
import { mulberry32 } from '../lib/helpers/rand';

// world polyline — the demo's, unchanged
const PATH = 'M 400 705 L 2600 705 L 2600 375 L 3160 375 L 3160 705 L 2600 705';
const SEGS: Array<[number, number, number, number, number]> = [
  [400, 705, 2600, 705, 2200],
  [2600, 705, 2600, 375, 330],
  [2600, 375, 3160, 375, 560],
  [3160, 375, 3160, 705, 330],
  [3160, 705, 2600, 705, 560],
];
const TOTAL_LEN = 3980;

// Scene A: window placed so the LAST row's progress bar starts at the path origin (400, 705).
// Page point (383,524) sits (323,464) inside the window => top-left (77, 241) at natural size.
const WIN_X = 77;
const WIN_Y = 241;

// Scene B: the piece-map block, centred inside the 560x330 frame the line draws
const B_FRAME = { x: 2600, y: 375, w: 560, h: 330 };
const PMAP = { w: 302, h: 259.46, scale: 1.15 };

/* Ambient bed in WORLD space (shot 1's orbs): gives the 60f traverse parallax instead of empty
   black, and world-space means they slide at camera speed — which sells the move as travel. */
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
    // brighter than shot 1's identical bed: there a radial gradient already lifts the centre;
    // here the orbs are all there is between scenes, and at shot 1's alpha they were invisible
    base: 0.14 + r() * 0.15,
  };
});

const BAR_LEN = 192; // the real progress bar's width in page px
const FILL = [0, 14] as const;
const EXTEND = [14, 24] as const;
const MOVE = [24, 84] as const;
const CLOSE = [84, 102] as const;
const CONTENT = [102, 114] as const;

/** Pen-tip position at a given drawn length, walked along the polyline. */
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
    // the bar completes in place
    drawn = interpolate(frame, FILL, [0, BAR_LEN], {
      easing: Easing.out(Easing.cubic),
      extrapolateLeft: 'clamp',
      extrapolateRight: 'clamp',
    });
  } else if (frame < EXTEND[1]) {
    // it runs out of row and keeps going
    drawn = interpolate(frame, EXTEND, [BAR_LEN, 1100], { extrapolateRight: 'clamp' });
  } else if (frame < MOVE[1]) {
    drawn = 1100 + cam; // 命门: pen and camera move at one speed
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
        {/* the far half sits a shade lifted — "somewhere else". Ramped over 700px, not butted at
            x=1920: a hard tone edge tracks across frame during the move and reads as a seam. */}
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

        {/* Scene A: the queue we have been in since shot 4. It recedes as the camera pulls off,
            so the line — not the UI it crosses — is the subject for the rest of the move. */}
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

        {/* one line, grown the whole way */}
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
              {/* the pen tip burns: a single high-quality point light, which is
                  what keeps 60 frames of dark traverse from being dead air */}
              <circle cx={tx} cy={ty} r={38} fill={C.accent} opacity={0.5} filter="url(#tipGlow)" />
              <circle cx={tx} cy={ty} r={11} fill={C.accent} />
            </g>
          )}
        </svg>

        {/* Scene B: what the line drew a frame around */}
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
