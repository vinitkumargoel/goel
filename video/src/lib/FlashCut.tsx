// origin: template/src/aifl/FlashCut.tsx — reskinned dark: the template's warm-white (paper palette)
// bloom becomes a cool accent-white, the product's own light. Timing unchanged: peak at 40%, gone by end.
import { AbsoluteFill, interpolate, useCurrentFrame } from 'remotion';

/** Bright-field cut: a bloom that flashes over a hard cut, straddling the seam
 *  5f either side. Only ever used on a seam — never as decoration. */
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
