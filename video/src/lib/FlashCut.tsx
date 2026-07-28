import { AbsoluteFill, interpolate, useCurrentFrame } from 'remotion';

export const FlashCut: React.FC<{ duration?: number; strength?: number }> = ({
  duration = 10,
  strength = 0.8,
}) => {
  const frame = useCurrentFrame();
  const o = interpolate(frame, [0, duration * 0.4, duration], [0, strength, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  return (
    <AbsoluteFill
      style={{
        pointerEvents: 'none',
        opacity: o,
        background:
          'radial-gradient(ellipse at 50% 46%, rgba(236,241,255,0.97), rgba(180,199,255,0.5) 55%, transparent 80%)',
      }}
    />
  );
};
