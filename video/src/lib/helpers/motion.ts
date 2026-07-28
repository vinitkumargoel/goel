// origin: disney-animation-rule-skill implementation-patterns (scanned 2026-07-13, absorbed 2026-07-15)

/** Motion-derived signal: sample a pure trajectory at frame±dt (central difference) for velocity,
 *  speed and heading. Drive stretch/smear/blur from `speed`; works on any pure `posAt`, no state. */
export const velocityAt = (
  posAt: (f: number) => { x: number; y: number },
  frame: number,
  dt = 0.5,
): { vx: number; vy: number; speed: number; direction: number } => {
  const before = posAt(frame - dt);
  const after = posAt(frame + dt);
  const vx = (after.x - before.x) / (2 * dt);
  const vy = (after.y - before.y) / (2 * dt);
  return { vx, vy, speed: Math.hypot(vx, vy), direction: Math.atan2(vy, vx) };
};

/** Follow-through without state: a trailing layer is the primary state at `frame − delayFrames`
 *  (shadow 2f, ghost 4f). Never accumulate across frames — every layer stays a pure fn of frame. */
export const lagged = <T>(
  stateAt: (f: number) => T,
  frame: number,
  delayFrames: number,
): T => stateAt(frame - delayFrames);

/** Closed-form damped oscillation for recoil/settle tails; t in frames from impact, returns a signed
 *  offset decaying to 0. Scale by peak amplitude. freq ~0.1 cycles/frame, damping ~0.15/frame. */
export const dampedSettle = (t: number, freq: number, damping: number): number =>
  t <= 0 ? 0 : Math.exp(-damping * t) * Math.sin(2 * Math.PI * freq * t);
