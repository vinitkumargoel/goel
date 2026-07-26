/* Shot 13 — the same queue, in a browser.
 *
 * Card: page-turn-transitions, 式 A `cube-rotate`
 * Exact demo read: demos/page-turn-transitions/CubeRotate.tsx
 *
 * Demo parameters kept verbatim: two faces on adjacent sides of a cube
 * (`rotateY(faceAngle) translateZ(W/2)`), the scene layer carrying
 * `translateZ(-W/2) rotateY(theta)` so the front face is pulled back to z = 0 —
 * without that layer the held frames are the wrong size, pushed away by the
 * perspective; theta 0 -> -90 across 38f on Easing.inOut(cubic); the outgoing
 * face darkening 1 -> 0.55 while the incoming one lifts 0.55 -> 1; the seam
 * shadow on the shared edge of both faces following sin(p*pi); a 1.5px blur in
 * mid-turn whose filter is CONDITIONALLY MOUNTED so the settled tail renders
 * identically frame after frame.
 *
 * Card semantics respected: 式 A means "these two are peers", 式 B means "this
 * replaces that". The desktop app and the web portal are the same engine with
 * two front doors, so A is correct — the film is not claiming the portal
 * supersedes the app.
 *
 * Card rule "volume transitions <= 2 per film": this is the only one. Shot 7's line
 * carry is a graphic relay, not a volume, and shot 11's turn is a card flipping
 * inside a scene, not a scene changing — so no two adjacent seams read as
 * slides in a deck.
 *
 * Both faces are real captures of real pages at the same layout scale, per the
 * card's requirement that the faces be hi-res enough to survive being seen at
 * an angle.
 *
 * Budget: 30f establishing A, 38f turning, and 42f held on B.
 */
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
