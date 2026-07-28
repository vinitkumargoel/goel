/* Shot 5 — throughput (card: odometer-digit-roll). Digit i decelerates 16f from 20+i*7, overshoots half a
 * row, springs back 6f; reels read 4,3 (shot 4's 43 MB/s). Lock pulse goes ink→white: dark field. */
import React from 'react';
import {
  AbsoluteFill,
  Sequence,
  interpolate,
  interpolateColors,
  useCurrentFrame,
  Easing,
} from 'remotion';
import { PageCam, CamKey } from '../lib/PageCam';
import { FlashCut } from '../lib/FlashCut';
import { C, FONT, PAGE } from '../theme';

const ROW = 210; // digit row height (the overflow box height)
const DW = 128; // digit box width
const FS = 190;
const SPIN = 0.85; // rows per frame while free-spinning
const DIGITS = [4, 3]; // the digits of "43 MB/s"

const ODO = 26; // frame the odometer's own clock starts
const CUT = 22; // seam the FlashCut straddles

/** Strip position of digit i, in rows. Pure function of the frame. */
const posAt = (f: number, i: number): number => {
  const d = DIGITS[i];
  const s = 20 + i * 7; // deceleration start
  const p0 = SPIN * s;
  // travel at least 6 more rows, then land on the nearest integer ending in d
  const T = Math.ceil((p0 + 6 - d) / 10) * 10 + d;
  if (f < s) return SPIN * Math.max(f, 0);
  if (f < s + 16)
    return interpolate(f, [s, s + 16], [p0, T + 0.5], {
      extrapolateLeft: 'clamp',
      extrapolateRight: 'clamp',
      easing: Easing.out(Easing.cubic),
    });
  if (f < s + 22)
    return interpolate(f, [s + 16, s + 22], [T + 0.5, T], {
      extrapolateLeft: 'clamp',
      extrapolateRight: 'clamp',
      easing: Easing.out(Easing.cubic),
    });
  return T;
};

const Strip: React.FC<{ pos: number; color: string; opacity?: number; dy?: number }> = ({
  pos,
  color,
  opacity = 1,
  dy = 0,
}) => (
  <div
    style={{
      position: 'absolute',
      left: 0,
      top: 0,
      width: DW,
      transform: `translateY(${-(pos % 10) * ROW + dy}px)`,
      opacity,
    }}
  >
    {Array.from({ length: 20 }).map((_, k) => (
      <div
        key={k}
        style={{
          width: DW,
          height: ROW,
          lineHeight: `${ROW}px`,
          textAlign: 'center',
          fontSize: FS,
          fontWeight: 800,
          fontVariantNumeric: 'tabular-nums',
          color,
        }}
      >
        {k % 10}
      </div>
    ))}
  </div>
);

/** One digit box: the reel plus two speed-gated ghost copies. */
const DigitReel: React.FC<{ frame: number; i: number; color: string }> = ({ frame, i, color }) => {
  const pos = posAt(frame, i);
  const speed = Math.abs(pos - posAt(frame - 1, i));
  const gate = interpolate(speed, [0.06, 0.5], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  return (
    <div style={{ position: 'relative', width: DW, height: ROW, overflow: 'hidden' }}>
      {gate > 0.001 && (
        <>
          <Strip pos={pos} color={color} opacity={0.25 * gate} dy={ROW * 0.5} />
          <Strip pos={pos} color={color} opacity={0.12 * gate} dy={-ROW * 0.5} />
        </>
      )}
      <Strip pos={pos} color={color} />
    </div>
  );
};

/* Camera push: the whole page, driving into the status-bar readout. */
/* The push ACCELERATES into the cut instead of easing out: an ease-out parks on the real "43 MB/s"
   status bar for ~10f, giving the answer away before the odometer rolls. FlashCut at 22 absorbs the stop. */
const CAM: CamKey[] = [
  { frame: 0, cx: 740, cy: 610, zoom: 1.12 },
  { frame: 24, cx: 205, cy: 763, zoom: 4.6 },
];

export const Throughput: React.FC<{ durationInFrames: number }> = () => {
  const frame = useCurrentFrame();
  const f = frame - ODO; // odometer-local frame

  const inkNow = interpolateColors(f, [49, 53, 57], [C.ink, '#ffffff', C.ink]);
  const pulseScale = interpolate(f, [49, 53, 57], [1, 1.035, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.inOut(Easing.quad),
  });
  const labelOp = interpolate(f, [52, 70], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.out(Easing.quad),
  });

  return (
    <AbsoluteFill style={{ background: C.canvas }}>
      {frame < ODO ? (
        <PageCam
          src="textures/app-full.png"
          pageW={PAGE.w}
          pageH={PAGE.h}
          keys={CAM}
          ease={Easing.bezier(0.5, 0, 0.78, 0.92)}
        />
      ) : (
        <AbsoluteFill style={{ background: C.canvas }}>
          {/* a single low pool of accent light under the number — the one light
              effect in this shot, per the "one high-quality point source" rule */}
          <AbsoluteFill
            style={{
              background: `radial-gradient(760px 420px at 50% 46%, rgba(138,162,255,0.16), transparent 72%)`,
            }}
          />
          <div
            style={{
              position: 'absolute',
              left: 0,
              top: 392,
              width: 1920,
              display: 'flex',
              alignItems: 'flex-end',
              justifyContent: 'center',
              fontFamily: FONT.ui,
              transform: `scale(${pulseScale})`,
              transformOrigin: '960px 105px',
            }}
          >
            <DigitReel frame={f} i={0} color={inkNow} />
            <DigitReel frame={f} i={1} color={inkNow} />
            <div
              style={{
                height: ROW,
                lineHeight: `${ROW}px`,
                fontSize: 74,
                fontWeight: 600,
                color: C.inkSoft,
                paddingLeft: 26,
                letterSpacing: '-0.01em',
              }}
            >
              MB/s
            </div>
          </div>
          {/* label bar: only after every reel has locked */}
          <div
            style={{
              position: 'absolute',
              left: 0,
              top: 672,
              width: 1920,
              display: 'flex',
              justifyContent: 'center',
              opacity: labelOp,
            }}
          >
            <div
              style={{
                font: `400 19px/1 ${FONT.mono}`,
                letterSpacing: '0.19em',
                textTransform: 'uppercase',
                color: C.inkFaint,
              }}
            >
              sustained · 16 segments · one file
            </div>
          </div>
        </AbsoluteFill>
      )}

      <Sequence from={CUT} durationInFrames={10}>
        <FlashCut duration={10} strength={0.72} />
      </Sequence>
    </AbsoluteFill>
  );
};
