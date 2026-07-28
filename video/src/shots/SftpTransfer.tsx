import React from 'react';
import { AbsoluteFill, Img, interpolate, staticFile, useCurrentFrame, Easing } from 'remotion';
import { C } from '../theme';
import { mulberry32 } from '../lib/helpers/rand';

const CL = { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' } as const;

const AX = 760, AY = 560;
const BX = 3400, BY = 600;
const WIN_W = 1360, WIN_H = 721;

// 200/153 are hotRow (260,213) minus the texture's (60,60) window origin — re-derive if the shot changes.
const ROW_W = 579.5, ROW_H = 34;
const ROW_X = AX - WIN_W / 2 + 200;
const ROW_Y = AY - WIN_H / 2 + 153;
const CHIP_W = 320, CHIP_H = 60.5;

const P0 = { x: ROW_X + ROW_W / 2, y: ROW_Y + ROW_H / 2 };
const P1 = { x: 1560, y: -150 };
const P2 = { x: 2500, y: 260 };
const P3 = { x: 3380, y: 430 };
const bez = (t: number) => {
  const u = 1 - t;
  return {
    x: u * u * u * P0.x + 3 * u * u * t * P1.x + 3 * u * t * t * P2.x + t * t * t * P3.x,
    y: u * u * u * P0.y + 3 * u * u * t * P1.y + 3 * u * t * t * P2.y + t * t * t * P3.y,
  };
};

const PICK = 12;
const ZOOM_OUT = [16, 42] as const;
const FLY = [34, 104] as const;
const TAKEOVER = [112, 146] as const;

type Prop = { x: number; y: number; size: number; ring: boolean; depth: number; drift: number; hue: string };
const PROPS: Prop[] = (() => {
  const rng = mulberry32(42);
  const out: Prop[] = [];
  const depths = [0.45, 0.75, 1.3];
  const hues = [C.accent, C.indigo, C.teal];
  for (let i = 0; i < 16; i++) {
    const depth = depths[i % 3];
    out.push({
      x: 600 + rng() * 2600,
      y: -150 + rng() * 1350,
      size: depth < 0.6 ? 60 + rng() * 70 : depth < 1 ? 110 + rng() * 100 : 220 + rng() * 160,
      ring: rng() > 0.45,
      depth,
      drift: rng() * Math.PI * 2,
      hue: hues[i % 3],
    });
  }
  return out;
})();

const Win: React.FC<{ cx: number; cy: number; file: string }> = ({ cx, cy, file }) => (
  <div
    style={{
      position: 'absolute',
      left: cx - WIN_W / 2,
      top: cy - WIN_H / 2,
      width: WIN_W,
      height: WIN_H,
      borderRadius: 12,
      overflow: 'hidden',
      boxShadow: '0 50px 130px rgba(0,0,0,0.65), 0 8px 26px rgba(0,0,0,0.5)',
    }}
  >
    <Img src={staticFile(`textures/${file}`)} style={{ width: WIN_W, height: WIN_H, display: 'block' }} />
  </div>
);

export const SftpTransfer: React.FC<{ durationInFrames: number }> = () => {
  const frame = useCurrentFrame();

  const tFly = interpolate(frame, FLY, [0, 1], { ...CL, easing: Easing.bezier(0.45, 0.05, 0.25, 1) });
  const pos = bez(tFly);
  /* Must sample backward at tFly === 1: forward the samples coincide and atan2(0, 0) snaps to level. */
  const dt = 0.012;
  const back = tFly + dt > 1;
  const posB = bez(back ? tFly - dt : tFly + dt);
  const angle = back
    ? (Math.atan2(pos.y - posB.y, pos.x - posB.x) * 180) / Math.PI
    : (Math.atan2(posB.y - pos.y, posB.x - pos.x) * 180) / Math.PI;

  const zoomOutP = interpolate(frame, ZOOM_OUT, [0, 1], { ...CL, easing: Easing.inOut(Easing.cubic) });
  const takeP = interpolate(frame, TAKEOVER, [0, 1], { ...CL, easing: Easing.inOut(Easing.cubic) });
  const followW = interpolate(frame, ZOOM_OUT, [0, 1], CL);

  let cx = AX + (pos.x - AX) * followW;
  let cy = AY + (Math.max(pos.y, 120) - AY) * followW;
  cx = cx * (1 - takeP) + BX * takeP;
  cy = cy * (1 - takeP) + BY * takeP;

  // zBase and zTake must agree at TAKEOVER[0], or the camera jumps on the handover frame.
  const zBase = 1.55 + (0.62 - 1.55) * zoomOutP;
  const zTake = 0.62 + (1.6 - 0.62) * takeP;
  const z = frame < TAKEOVER[0] ? zBase : zTake;

  const camX = (wx: number, d: number) => 960 + (wx - cx) * z * d;
  const camY = (wy: number, d: number) => 540 + (wy - cy) * z * d;

  const pickPulse = interpolate(frame, [PICK, PICK + 3, PICK + 12], [0, 1, 0], {
    ...CL,
    easing: Easing.out(Easing.quad),
  });

  const chipVisible = frame >= FLY[0] - 2;
  const flightBoost = interpolate(tFly, [0, 0.25, 0.75, 1], [1, 1.7, 1.7, 1.1], CL);
  const chipScale =
    interpolate(frame, [FLY[0] - 2, FLY[0] + 8], [0.3, 1], { ...CL, easing: Easing.out(Easing.back(1.6)) }) *
    flightBoost;
  const chipOpacity = interpolate(takeP, [0, 0.35], [1, 0], CL);

  return (
    <AbsoluteFill style={{ background: `linear-gradient(165deg, ${C.canvasLift} 0%, ${C.canvas} 100%)`, overflow: 'hidden' }}>
      {PROPS.filter((p) => p.depth < 1).map((p, i) => {
        const x = camX(p.x, p.depth) + Math.sin(frame * 0.035 + p.drift) * 14;
        const y = camY(p.y, p.depth) + Math.cos(frame * 0.03 + p.drift) * 10;
        const s = p.size * z * p.depth;
        const fade = interpolate(takeP, [0.3, 0.9], [1, 0], CL);
        return (
          <div
            key={i}
            style={{
              position: 'absolute',
              left: x - s / 2,
              top: y - s / 2,
              width: s,
              height: s,
              opacity: (p.depth < 0.6 ? 0.16 : 0.24) * fade,
              borderRadius: p.ring ? '50%' : 14,
              background: p.ring ? 'transparent' : p.hue,
              border: p.ring ? `${Math.max(s * 0.11, 3)}px solid ${p.hue}` : 'none',
              filter: p.depth < 0.6 ? 'blur(3px)' : 'none',
              boxSizing: 'border-box',
            }}
          />
        );
      })}

      <div
        style={{
          position: 'absolute',
          left: 0,
          top: 0,
          transformOrigin: '0 0',
          transform: `translate(${960 - cx * z}px, ${540 - cy * z}px) scale(${z})`,
        }}
      >
        <Win cx={AX} cy={AY} file="sftp-window.png" />
        <Win cx={BX} cy={BY} file="app-window.png" />

        {pickPulse > 0.01 && (
          <div
            style={{
              position: 'absolute',
              left: ROW_X,
              top: ROW_Y,
              width: ROW_W,
              height: ROW_H,
              borderRadius: 8,
              border: `2px solid ${C.accent}`,
              boxShadow: `0 0 0 ${pickPulse * 18}px rgba(138,162,255,0.10), 0 0 26px rgba(138,162,255,${0.5 * pickPulse})`,
              opacity: pickPulse,
            }}
          />
        )}

        {chipVisible && chipOpacity > 0.01 && (
          <div
            style={{
              position: 'absolute',
              left: pos.x - CHIP_W / 2,
              top: pos.y - CHIP_H / 2,
              width: CHIP_W,
              height: CHIP_H,
              transform: `rotate(${angle}deg) scale(${chipScale})`,
              opacity: chipOpacity,
              borderRadius: 12,
              boxShadow: `0 22px 52px rgba(0,0,0,0.6), 0 0 40px rgba(138,162,255,0.3)`,
            }}
          >
            <Img
              src={staticFile('textures/transfer-chip.png')}
              style={{ position: 'absolute', inset: 0, width: CHIP_W, height: CHIP_H, display: 'block' }}
            />
            <div
              style={{
                position: 'absolute',
                inset: 0,
                borderRadius: 12,
                border: `1.5px solid rgba(138,162,255,0.5)`,
                boxSizing: 'border-box',
              }}
            />
          </div>
        )}
      </div>

      {/* near props, out of focus in front of everything */}
      {PROPS.filter((p) => p.depth >= 1).map((p, i) => {
        const x = camX(p.x, p.depth) + Math.sin(frame * 0.04 + p.drift) * 20;
        const y = camY(p.y, p.depth) + Math.cos(frame * 0.033 + p.drift) * 16;
        const s = p.size * z * p.depth;
        const fade = interpolate(takeP, [0.2, 0.7], [1, 0], CL);
        return (
          <div
            key={i}
            style={{
              position: 'absolute',
              left: x - s / 2,
              top: y - s / 2,
              width: s,
              height: s,
              opacity: 0.14 * fade,
              borderRadius: p.ring ? '50%' : 22,
              background: p.ring ? 'transparent' : p.hue,
              border: p.ring ? `${Math.max(s * 0.1, 5)}px solid ${p.hue}` : 'none',
              filter: 'blur(8px)',
              boxSizing: 'border-box',
            }}
          />
        );
      })}
    </AbsoluteFill>
  );
};
