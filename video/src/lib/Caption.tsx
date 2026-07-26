// origin: template/src/aifl/Caption.tsx — reskinned for Goel° per DESIGN-SPEC §3
// (Inter instead of the template's mono, accent square instead of amber, ink
// tokens from Theme.swift). Motion is unchanged: 8f rise-in, 8f fade-out.
import { interpolate, useCurrentFrame } from 'remotion';
import { C, FONT } from '../theme';

/** Screen-space narration caption: a strip at the bottom of the frame led by a
 * small accent square, with an optional quieter second line. Every claim the
 * film makes carries one of these, because the README plays it muted. */
export const Caption: React.FC<{
  text: string;
  sub?: string;
  duration: number;
  bottom?: number;
}> = ({ text, sub, duration, bottom = 76 }) => {
  const frame = useCurrentFrame();
  const inT = interpolate(frame, [0, 8], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const outT = interpolate(frame, [duration - 8, duration], [1, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

  return (
    <div
      style={{
        position: 'absolute',
        left: 0,
        right: 0,
        bottom,
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        gap: 11,
        opacity: inT * outT,
        transform: `translateY(${(1 - inT) * 8}px)`,
        pointerEvents: 'none',
        textShadow: '0 2px 22px rgba(0,0,0,0.7)',
      }}
    >
      <div style={{ display: 'flex', alignItems: 'center', gap: 15 }}>
        <span
          style={{
            width: 7,
            height: 7,
            background: C.accent,
            display: 'inline-block',
            boxShadow: `0 0 12px ${C.accent}`,
          }}
        />
        <span
          style={{
            font: `500 27px/1 ${FONT.ui}`,
            letterSpacing: '-0.005em',
            color: C.ink,
          }}
        >
          {text}
        </span>
      </div>
      {sub ? (
        <div
          style={{
            font: `400 15px/1 ${FONT.mono}`,
            letterSpacing: '0.13em',
            textTransform: 'uppercase',
            color: C.inkFaint,
          }}
        >
          {sub}
        </div>
      ) : null}
    </div>
  );
};
