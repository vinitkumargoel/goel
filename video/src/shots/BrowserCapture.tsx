/* Shot 11 — browser capture.
 *
 * Card: integration-hub-map
 * Exact demo read: demos/integration-hub-map/IntegrationHubMap.tsx
 *
 * Demo parameters kept verbatim: the page is a two-sided card that turns a full
 * rotateY 0 -> 180 over 35 frames on Easing.out(cubic) — a fast turn with a long
 * decelerating landing, one continuous move with no mid-way pause (the card
 * records that a 70f version and a version that paused at the edge were both
 * rejected, and that "even" means "unbroken", not literally linear); the edge
 * flash is a 2f spike that is back to zero within 4 (the long bloom plateau was
 * rejected); the pipes' rainbow gradients use `gradientUnits="userSpaceOnUse"`,
 * because a perfectly horizontal or vertical line has a zero-height bounding box
 * and object-bounding-box gradients silently drop those pipes entirely; the
 * pipe-glow filter carries an explicit userSpaceOnUse filter region for the same
 * reason; pipes grow over 9f; and the transport pulse runs at 4.6px per frame
 * with a per-pipe phase offset, forever.
 *
 * Card 命门 — the two-beat entry — is exact: all five marks appear on ONE frame
 * (tIcon 52), and 10 frames later all five pipes start on ONE frame (tPipe 62).
 * The card's case history is unambiguous: staggered connection was rejected
 * twice, and only "all at once, then all connected at once" was accepted. The
 * two beats stay >= 6f apart so they read as two, not one.
 *
 * Reskin: the demo's neon-purple field and third-party SaaS logos become the
 * film's canvas and the five browsers Goel° actually installs a capture
 * extension into. The marks are the same inline SVGs the product website
 * serves, so the film and the site show the same logos.
 *
 * The card's dividing line with glow-flyline-moves is respected: the light pipes
 * here are structure (five things attach to one thing), not the subject. The
 * subject is the turn.
 */
import React from 'react';
import { AbsoluteFill, Img, interpolate, staticFile, useCurrentFrame, Easing } from 'remotion';
import { C, FONT } from '../theme';

const CL = { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' } as const;

const HUB_W = 900;
const HUB_H = 478; // 900 * 721/1360, the app window's aspect

/* ---- browser marks: the site's own symbols, inlined ---- */
const Mark: React.FC<{ kind: string }> = ({ kind }) => {
  switch (kind) {
    case 'chrome':
      return (
        <svg width={58} height={58} viewBox="0 0 48 48">
          <circle cx="24" cy="24" r="21" fill="#fff" />
          <path fill="#EA4335" d="M24 24 L5.81 13.5 A21 21 0 0 1 42.19 13.5 Z" />
          <path fill="#FBBC05" d="M24 24 L42.19 13.5 A21 21 0 0 1 24 45 Z" />
          <path fill="#34A853" d="M24 24 L24 45 A21 21 0 0 1 5.81 13.5 Z" />
          <circle cx="24" cy="24" r="9.5" fill="#fff" />
          <circle cx="24" cy="24" r="7" fill="#4285F4" />
        </svg>
      );
    case 'firefox':
      return (
        <svg width={58} height={58} viewBox="0 0 48 48">
          <defs>
            <clipPath id="ff-clip">
              <circle cx="24" cy="24" r="21" />
            </clipPath>
          </defs>
          <g clipPath="url(#ff-clip)">
            <circle cx="24" cy="24" r="21" fill="#FF9640" />
            <circle cx="31" cy="32" r="22" fill="#E1350F" />
            <circle cx="17" cy="17" r="10" fill="#FFCB00" />
          </g>
        </svg>
      );
    case 'safari':
      return (
        <svg width={58} height={58} viewBox="0 0 48 48">
          <defs>
            <linearGradient id="sf-g" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0" stopColor="#3FB6F5" />
              <stop offset="1" stopColor="#0B62D8" />
            </linearGradient>
          </defs>
          <circle cx="24" cy="24" r="21" fill="#F2F5F7" />
          <circle cx="24" cy="24" r="19" fill="url(#sf-g)" />
          <path fill="#FF3B30" d="M36 12 L26.12 26.12 L21.88 21.88 Z" />
          <path fill="#fff" d="M12 36 L21.88 21.88 L26.12 26.12 Z" />
        </svg>
      );
    case 'edge':
      return (
        <svg width={58} height={58} viewBox="0 0 48 48">
          <defs>
            <clipPath id="ed-clip">
              <circle cx="24" cy="24" r="21" />
            </clipPath>
          </defs>
          <g clipPath="url(#ed-clip)">
            <circle cx="24" cy="24" r="21" fill="#0C59A4" />
            <circle cx="30" cy="17" r="18" fill="#2CC3D5" />
            <circle cx="34" cy="12" r="10" fill="#6DDDF2" />
          </g>
        </svg>
      );
    default: // brave
      return (
        <svg width={58} height={58} viewBox="0 0 48 48">
          <path
            fill="#FB542B"
            d="M11.5 9.5 L36.5 9.5 L35 26 C34.3 32.5 30 37 24 41.5 C18 37 13.7 32.5 13 26 Z"
          />
          <path fill="#fff" opacity="0.9" d="M18 17 L24 21.5 L30 17 L27 25 L24 30 L21 25 Z" />
        </svg>
      );
  }
};

const Tile: React.FC<{ kind: string; label: string; on: number }> = ({ kind, label, on }) => (
  <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 10 }}>
    <div
      style={{
        width: 116,
        height: 116,
        borderRadius: 28,
        background: C.surface,
        border: `1px solid rgba(138,162,255,${0.18 + on * 0.32})`,
        display: 'flex',
        justifyContent: 'center',
        alignItems: 'center',
        boxShadow: `0 0 ${14 + on * 40}px rgba(138,162,255,${0.14 + on * 0.4})`,
        transform: `scale(${0.9 + on * 0.1})`,
      }}
    >
      <Mark kind={kind} />
    </div>
    <div
      style={{
        font: `400 13px/1 ${FONT.mono}`,
        letterSpacing: '0.15em',
        textTransform: 'uppercase',
        color: C.inkFaint,
        opacity: 0.4 + on * 0.6,
      }}
    >
      {label}
    </div>
  </div>
);

/* Five pipes into the hub. The hub occupies 900x478 centred at (960, 565), so
   its edges are x 510/1410 and y 326/804. Every path ends ON an edge. */
type Pipe = { kind: string; label: string; icon: [number, number]; path: string; len: number };
const PIPES: Pipe[] = [
  { kind: 'chrome', label: 'Chrome', icon: [330, 210], path: 'M 330 278 L 330 400 Q 330 440 370 440 L 510 440', len: 342 },
  { kind: 'firefox', label: 'Firefox', icon: [230, 640], path: 'M 296 640 L 510 640', len: 214 },
  { kind: 'safari', label: 'Safari', icon: [960, 150], path: 'M 960 216 L 960 326', len: 110 },
  { kind: 'edge', label: 'Edge', icon: [1590, 210], path: 'M 1590 278 L 1590 400 Q 1590 440 1550 440 L 1410 440', len: 342 },
  { kind: 'brave', label: 'Brave', icon: [1690, 640], path: 'M 1624 640 L 1410 640', len: 214 },
];

const T_ICON = 52; // one frame, all five
const T_PIPE = 62; // one frame, all five — 10f later
const GROW = 9;
const ALL_ON = T_PIPE + GROW;

export const BrowserCapture: React.FC<{ durationInFrames: number }> = () => {
  const frame = useCurrentFrame();

  // the turn: fast, with a long decelerating landing; one unbroken move
  const rotY = interpolate(frame, [14, 49], [0, 180], { ...CL, easing: Easing.out(Easing.cubic) });
  const zoom = interpolate(frame, [0, 14, 58, 96], [1.55, 1.48, 1.02, 1], {
    extrapolateRight: 'clamp',
    easing: Easing.inOut(Easing.cubic),
  });
  // the edge: a 2f spike, back to nothing within 4
  const bloom = interpolate(frame, [19, 21, 23, 27], [0, 1, 0.25, 0], CL);

  const breathe = frame > ALL_ON ? 0.5 + 0.5 * Math.sin((frame - ALL_ON) * 0.16) : 0;
  const mapIn = interpolate(frame, [34, 60], [0, 1], CL);

  return (
    <AbsoluteFill style={{ background: C.canvas, overflow: 'hidden' }}>
      <AbsoluteFill
        style={{
          background:
            'radial-gradient(ellipse at 50% 52%, rgba(138,162,255,0.13), transparent 62%), radial-gradient(ellipse at 16% 80%, rgba(192,162,251,0.07), transparent 52%)',
        }}
      />

      {/* pipes */}
      <svg width={1920} height={1080} style={{ position: 'absolute', inset: 0, opacity: mapIn }}>
        <defs>
          {PIPES.map((p, i) => {
            const nums = p.path.match(/-?[\d.]+/g)!.map(Number);
            const [x1, y1] = [nums[0], nums[1]];
            const [x2, y2] = [nums[nums.length - 2], nums[nums.length - 1]];
            return (
              // userSpaceOnUse: a purely horizontal or vertical pipe has a
              // zero-extent bbox and object-bounding-box gradients drop it
              <linearGradient
                key={i}
                id={`pipe-${i}`}
                gradientUnits="userSpaceOnUse"
                x1={x1}
                y1={y1}
                x2={x2}
                y2={y2}
              >
                <stop offset="0%" stopColor={C.teal} />
                <stop offset="45%" stopColor={C.indigo} />
                <stop offset="100%" stopColor={C.accent} />
              </linearGradient>
            );
          })}
          <filter id="pipeGlow" filterUnits="userSpaceOnUse" x="0" y="0" width="1920" height="1080">
            <feGaussianBlur stdDeviation="7" result="b" />
            <feMerge>
              <feMergeNode in="b" />
              <feMergeNode in="SourceGraphic" />
            </feMerge>
          </filter>
        </defs>
        {PIPES.map((p, i) => {
          const grow = interpolate(frame, [T_PIPE, T_PIPE + GROW], [0, 1], {
            ...CL,
            easing: Easing.out(Easing.quad),
          });
          if (grow <= 0) return null;
          const dashOn = p.len * grow;
          const pulse = frame > ALL_ON ? 0.78 + 0.22 * Math.sin((frame - ALL_ON) * 0.16 + i) : 1;
          const flowOffset = -((frame - T_PIPE) * 4.6 + i * 37);
          const flowIn = interpolate(frame, [ALL_ON, ALL_ON + 8], [0, 1], CL);
          return (
            <g key={i} filter="url(#pipeGlow)">
              <path
                d={p.path}
                fill="none"
                stroke={`url(#pipe-${i})`}
                strokeWidth={13}
                strokeLinecap="round"
                strokeDasharray={`${dashOn} ${p.len + 60}`}
                opacity={0.82 * pulse}
              />
              <path
                d={p.path}
                fill="none"
                stroke="rgba(232,234,240,0.85)"
                strokeWidth={4}
                strokeLinecap="round"
                strokeDasharray={`${dashOn} ${p.len + 60}`}
                opacity={0.72 * pulse}
              />
              {grow >= 1 && flowIn > 0 && (
                <>
                  {/* transport: bright packets running browser -> hub, always */}
                  <path
                    d={p.path}
                    fill="none"
                    stroke="#ffffff"
                    strokeWidth={9}
                    strokeLinecap="round"
                    strokeDasharray="16 56"
                    strokeDashoffset={flowOffset}
                    opacity={0.9 * flowIn}
                  />
                  <path
                    d={p.path}
                    fill="none"
                    stroke="rgba(138,162,255,0.6)"
                    strokeWidth={22}
                    strokeLinecap="round"
                    strokeDasharray="16 56"
                    strokeDashoffset={flowOffset}
                    opacity={0.5 * flowIn}
                  />
                </>
              )}
            </g>
          );
        })}
      </svg>

      {/* the five marks: one frame, together */}
      {PIPES.map((p, i) => {
        const appear = interpolate(frame, [T_ICON, T_ICON + 12], [0, 1], {
          ...CL,
          easing: Easing.out(Easing.cubic),
        });
        const on = interpolate(frame, [T_PIPE, T_PIPE + 10], [0.15, 1], CL);
        if (appear <= 0) return null;
        return (
          <div
            key={i}
            style={{
              position: 'absolute',
              left: p.icon[0] - 58,
              top: p.icon[1] - 58,
              opacity: appear,
              transform: `translateY(${(1 - appear) * 24}px)`,
            }}
          >
            <Tile
              kind={p.kind}
              label={p.label}
              on={on * (frame > ALL_ON ? 0.8 + 0.2 * breathe : 1)}
            />
          </div>
        );
      })}

      {/* the hub: a two-sided card that turns over */}
      <AbsoluteFill style={{ justifyContent: 'center', alignItems: 'center', perspective: 1500 }}>
        <div
          style={{
            transform: `translateY(25px) rotateY(${rotY}deg) scale(${zoom})`,
            position: 'relative',
            transformStyle: 'preserve-3d',
            width: HUB_W,
            height: HUB_H,
          }}
        >
          {/* front: the browser we were just downloading from */}
          <div style={{ position: 'absolute', inset: 0, backfaceVisibility: 'hidden' }}>
            <Img
              src={staticFile('textures/portal-window.png')}
              style={{
                width: HUB_W,
                height: HUB_H,
                borderRadius: 12,
                display: 'block',
                boxShadow: `0 0 ${40 + bloom * 110}px rgba(232,234,240,${0.12 + bloom * 0.5})`,
              }}
            />
          </div>
          {/* back: the queue everything lands in (pre-turned so it reads correctly) */}
          <div
            style={{
              position: 'absolute',
              inset: 0,
              backfaceVisibility: 'hidden',
              transform: 'rotateY(180deg)',
            }}
          >
            <Img
              src={staticFile('textures/app-window.png')}
              style={{
                width: HUB_W,
                height: HUB_H,
                borderRadius: 12,
                display: 'block',
                boxShadow: `0 0 ${40 + bloom * 110}px rgba(232,234,240,${0.12 + bloom * 0.5}), 0 0 ${130 + bloom * 140}px rgba(138,162,255,${0.16 + breathe * 0.1})`,
              }}
            />
          </div>
          {/* edge blow-out: only during the spike */}
          {bloom > 0.02 && (
            <div
              style={{
                position: 'absolute',
                inset: -6,
                borderRadius: 16,
                background: '#eef2ff',
                opacity: Math.min(0.96, bloom * 1.05),
                filter: 'blur(5px)',
                pointerEvents: 'none',
                transform: rotY > 90 ? 'rotateY(180deg) translateZ(1px)' : 'translateZ(1px)',
                backfaceVisibility: 'hidden',
              }}
            />
          )}
        </div>
      </AbsoluteFill>

      {/* the flash the edge throws across the frame */}
      {bloom > 0.02 && (
        <AbsoluteFill style={{ pointerEvents: 'none' }}>
          <div
            style={{
              position: 'absolute',
              left: 360,
              top: 90,
              width: 1200,
              height: 900,
              background:
                'radial-gradient(closest-side, rgba(238,242,255,0.96), rgba(180,199,255,0.6) 45%, rgba(138,162,255,0.28) 70%, transparent 88%)',
              filter: 'blur(26px)',
              opacity: Math.min(1, bloom * 0.95),
            }}
          />
        </AbsoluteFill>
      )}
    </AbsoluteFill>
  );
};
