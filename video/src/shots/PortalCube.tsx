/* Shot 13 — the same queue, in a browser. page-turn-transitions 式 A `cube-rotate`: the two are peers.
 * `translateZ(-W/2) rotateY(theta)` scene layer, theta 0->-90/38f; mid-turn blur mounted conditionally. */
import React from 'react';
import { AbsoluteFill, Img, interpolate, staticFile, useCurrentFrame, Easing } from 'remotion';
import { C, FONT } from '../theme';

const S = 1.08; // the 1480x841 page rendered at 1598x908
const W = 1480 * S;
const H = 841 * S;

const TURN = [30, 68] as const;

const Face: React.FC<{
  file: string;
  rot: number;
  brightness: number;
  seam: number;
  seamSide: 'right' | 'left';
  badge: string;
}> = ({ file, rot, brightness, seam, seamSide, badge }) => (
  <div
    style={{
      position: 'absolute',
      width: W,
      height: H,
      overflow: 'hidden',
      backfaceVisibility: 'hidden',
      transform: `rotateY(${rot}deg) translateZ(${W / 2}px)`,
      filter: `brightness(${brightness})`,
      background: C.canvas,
    }}
  >
    <Img src={staticFile(`textures/${file}`)} style={{ width: W, height: H, display: 'block' }} />
    <div
      style={{
        position: 'absolute',
        left: 44,
        bottom: 34,
        font: `400 16px/1 ${FONT.mono}`,
        letterSpacing: '0.2em',
        textTransform: 'uppercase',
        color: C.inkFaint,
      }}
    >
      {badge}
    </div>
    {seam > 0.01 && (
      <div
        style={{
          position: 'absolute',
          top: 0,
          [seamSide]: 0,
          width: 170,
          height: H,
          opacity: seam,
          background:
            seamSide === 'right'
              ? 'linear-gradient(to right, rgba(0,0,0,0), rgba(0,0,0,0.62))'
              : 'linear-gradient(to left, rgba(0,0,0,0), rgba(0,0,0,0.62))',
        }}
      />
    )}
  </div>
);

export const PortalCube: React.FC<{ durationInFrames: number }> = () => {
  const frame = useCurrentFrame();

  const p = interpolate(frame, TURN, [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.inOut(Easing.cubic),
  });
  const theta = -90 * p;
  const brightA = 1 - 0.45 * p;
  const brightB = 0.55 + 0.45 * p;
  const mid = Math.sin(p * Math.PI);
  const seam = mid * 0.9;
  const blur = mid * 1.5;

  return (
    <AbsoluteFill style={{ background: C.canvas, overflow: 'hidden' }}>
      <div
        style={{
          position: 'absolute',
          inset: 0,
          filter: blur > 0.02 ? `blur(${blur}px)` : undefined,
        }}
      >
        <div
          style={{
            position: 'absolute',
            left: (1920 - W) / 2,
            top: (1080 - H) / 2,
            width: W,
            height: H,
            perspective: 1400,
          }}
        >
          <div
            style={{
              position: 'absolute',
              inset: 0,
              transformStyle: 'preserve-3d',
              // pulls the front face back to z = 0 so the held frames are true size
              transform: `translateZ(${-W / 2}px) rotateY(${theta}deg)`,
            }}
          >
            <Face
              file="app-full.png"
              rot={0}
              brightness={brightA}
              seam={seam}
              seamSide="right"
              badge="native · macOS"
            />
            <Face
              file="portal-full.png"
              rot={90}
              brightness={brightB}
              seam={seam}
              seamSide="left"
              badge="portal · any browser"
            />
          </div>
        </div>
      </div>
    </AbsoluteFill>
  );
};
