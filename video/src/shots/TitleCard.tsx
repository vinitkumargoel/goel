/* Shots 3/10 title cards — 式 A `split-text-stagger`, demo params verbatim (115%->OVERSHOOT->0,
 * RISE 14f, SETTLE 6f). OVERSHOOT -10 is 已知坑, never revert to 6; line 2 cue lands both on f48. */
import React from 'react';
import { AbsoluteFill, interpolate, useCurrentFrame, Easing } from 'remotion';
import { C, FONT } from '../theme';

const START = 0; // first character's cue
const RISE = 14;
const SETTLE = 6;
const OVERSHOOT = -10; // percent — the card's raised value, not the original 6
const FONT_SIZE = 96;
const LINE2_CUE = 10; // line 2 starts later so both lines finish together

/** Vertical offset of one character, in percent. Frame-deterministic. */
const charY = (f: number, cue: number): number => {
  if (f < cue + RISE) {
    return interpolate(f, [cue, cue + RISE], [115, OVERSHOOT], {
      extrapolateLeft: 'clamp',
      extrapolateRight: 'clamp',
      easing: Easing.out(Easing.cubic),
    });
  }
  return interpolate(f, [cue + RISE, cue + RISE + SETTLE], [OVERSHOOT, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.out(Easing.quad),
  });
};

const Line: React.FC<{ text: string; cue0: number; frame: number; accent: boolean }> = ({
  text,
  cue0,
  frame,
  accent,
}) => (
  <div style={{ display: 'flex' }}>
    {text.split('').map((c, i) => (
      <div
        key={i}
        style={{
          // mask box: 0.35em of head room above the cap line holds the
          // overshoot, and its bottom edge is the implied cut line
          overflow: 'hidden',
          height: FONT_SIZE * 1.35,
          display: 'flex',
          alignItems: 'flex-end',
        }}
      >
        <span
          style={{
            display: 'inline-block',
            font: `600 ${FONT_SIZE}px/1.05 ${FONT.ui}`,
            letterSpacing: '-0.022em',
            color: accent ? C.accent : C.ink,
            whiteSpace: 'pre',
            transform: `translateY(${charY(frame, cue0 + i * 2)}%)`,
          }}
        >
          {c}
        </span>
      </div>
    ))}
  </div>
);

export const TitleCard: React.FC<{
  durationInFrames: number;
  lines: [string, string];
  accentLine: 0 | 1;
}> = ({ lines, accentLine }) => {
  const frame = useCurrentFrame();

  // baseline rule: starts on the first character's cue, grows left to right
  const ruleW = interpolate(frame, [START, START + 26], [0, 100], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.out(Easing.cubic),
  });

  return (
    <AbsoluteFill
      style={{
        background: C.canvas,
        alignItems: 'center',
        justifyContent: 'center',
        flexDirection: 'column',
      }}
    >
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'flex-start' }}>
        <Line text={lines[0]} cue0={START} frame={frame} accent={accentLine === 0} />
        <Line text={lines[1]} cue0={START + LINE2_CUE} frame={frame} accent={accentLine === 1} />
        {/* baseline rule: the implied cut line the characters rose through */}
        <div style={{ width: 760, marginTop: 18 }}>
          <div style={{ height: 2, width: `${ruleW}%`, background: C.accent, opacity: 0.85 }} />
        </div>
      </div>
    </AbsoluteFill>
  );
};
