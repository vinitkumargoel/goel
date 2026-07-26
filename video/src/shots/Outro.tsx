/* Shot 15 — the group photo.
 *
 * Card: outro-group-photo-launch
 * Exact reference implementation read: template/src/aifl/live/SceneOutroLive.tsx
 * (the card names the template scene; there is no demos/ directory for it)
 *
 * Parameters kept verbatim: nine elements, cues from 4 at 3f apart, each flying
 * 12f from a +/-300-500px offset, rendered in cue order so later arrivals stack;
 * the fly easing is `bezier(0.34, 1.4, 0.44, 1)` — the source comments record
 * that the previous curve "never crossed 1" and so never actually overshot, and
 * a landing that does not bounce is the failure this value fixes; in-flight pose
 * `rot * (2 - t)` and `scale * (1.12 - 0.12t)`; a ghost copy lagging 8% of the
 * path at blur 8; a landing glow blooming 0.35 -> 0 over 6f; the whole photo
 * layer under a crane, `rotateX 4 -> 0` with `scale 1.06 -> 1` over 40f then a
 * slow +0.035 push; the assembled elements stepping back 12% in opacity and 8%
 * in saturation across 42 -> 50 as the wordmark takes the stage; letters at
 * `delay = 42 + i*1.8` over 8f; the rule growing 58 -> 70 with 190px extension
 * lines shooting out 58 -> 66 and fading by 72; one letter-spacing breath at
 * 62 -> 66; 20 dust motes with every parameter derived from the index.
 *
 * Card's Q8 check — every feature the film showed needs a representative in the
 * photo, because the audience notices the one that is missing. Present: the app
 * chrome and sidebar (shots 2, 4), the queue row (4), the status bar's
 * throughput (5), the progress ring (6), the piece map (8), the SFTP pane (9),
 * the menu-bar popover (12), the web portal (13). Nine elements, nine beats.
 *
 * Card's dedupe rule: the sign-off line must not repeat anything the film has
 * already said. "Zero Homebrew dependencies · macOS + Linux" appears nowhere in
 * the captions, and the outro carries no narration caption of its own.
 *
 * Reskin only in the palette: the template's warm paper scrim, amber glows and
 * gold dust become the product's canvas, accent and cool light. The landing glow
 * blends with `screen` rather than `multiply`, because on a dark ground a
 * multiply glow is invisible. For the same reason each element carries a
 * hairline accent edge and a small brightness lift: the template's members were
 * light cards on paper and separated themselves, whereas nine dark panels on a
 * dark canvas read as nine holes unless they are given an edge.
 *
 * Budget: last element lands at 40, the wordmark is fully set by 57, the rule
 * and tagline finish by 80, and the shot runs 155 — 75f of sign-off hold, well
 * past the card's one-second floor.
 */
import React from 'react';
import { AbsoluteFill, Img, interpolate, staticFile, useCurrentFrame, Easing } from 'remotion';
import { PageCam, CamKey } from '../lib/PageCam';
import { C, FONT, PAGE } from '../theme';

const CL = { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' } as const;

const FLY_EASE = Easing.bezier(0.34, 1.4, 0.44, 1);
const CRANE_EASE = Easing.bezier(0.3, 0, 0.2, 1);
const LETTERS = 'Goel°'.split('');

type FlyEl = {
  key: string;
  file: string;
  w: number;
  h: number;
  cx: number;
  cy: number;
  scale: number;
  rot: number;
  dx: number;
  dy: number;
  radius: number;
  cue: number;
};

/* render order = cue order, so later arrivals stack on top */
const ELS: FlyEl[] = [
  { key: 'toolbar', file: 'toolbar.png', w: 1360, h: 51, cx: 960, cy: 104, scale: 0.64, rot: 0, dx: 0, dy: -120, radius: 8, cue: 4 },
  { key: 'sidebar', file: 'sidebar.png', w: 200, h: 633, cx: 214, cy: 470, scale: 0.5, rot: -3, dx: -430, dy: 0, radius: 10, cue: 7 },
  { key: 'portal', file: 'portal-window.png', w: 1400, h: 761, cx: 1606, cy: 336, scale: 0.42, rot: 4, dx: 500, dy: -60, radius: 12, cue: 10 },
  { key: 'sftp', file: 'pane-remote.png', w: 579.5, h: 633, cx: 306, cy: 806, scale: 0.42, rot: 3, dx: -400, dy: 300, radius: 10, cue: 13 },
  { key: 'pieces', file: 'pmap.png', w: 302, h: 220.96, cx: 1566, cy: 806, scale: 0.86, rot: -3, dx: 380, dy: 270, radius: 10, cue: 16 },
  { key: 'row', file: 'row1.png', w: 821, h: 50, cx: 700, cy: 944, scale: 0.74, rot: 2, dx: 0, dy: 320, radius: 8, cue: 19 },
  { key: 'popover', file: 'popover.png', w: 340, h: 377.5, cx: 1738, cy: 626, scale: 0.6, rot: -2.5, dx: 360, dy: 0, radius: 12, cue: 22 },
  { key: 'ring', file: 'ring.png', w: 118, h: 118, cx: 256, cy: 194, scale: 1, rot: 0, dx: -300, dy: -220, radius: 59, cue: 25 },
  { key: 'status', file: 'statusbar.png', w: 1360, h: 37, cx: 1140, cy: 1014, scale: 0.56, rot: -1.5, dx: 0, dy: 300, radius: 8, cue: 28 },
];

/* 20 motes, every parameter derived from the index — no randomness at render */
const DUST = Array.from({ length: 20 }, (_, i) => ({
  x: (i * 439 + 137) % 1920,
  y0: (i * 613 + 271) % 1080,
  rise: 0.3 + (i % 5) * 0.11,
  swayAmp: 9 + (i % 4) * 5,
  swayFreq: 0.022 + (i % 3) * 0.008,
  phase: (i * 0.83) % (Math.PI * 2),
  size: 2 + (i % 3) * 0.5,
  opacity: 0.14 + ((i * 7) % 5) * 0.05,
}));

const CAM: CamKey[] = [{ frame: 0, cx: 740, cy: 560, zoom: 0.78 }];

export const Outro: React.FC<{ durationInFrames: number }> = ({ durationInFrames }) => {
  const frame = useCurrentFrame();
  const duration = durationInFrames;

  // 22, not the template's 14: at 14 the backdrop still reads as a legible
  // page behind the group photo, which is a smudge rather than bokeh
  const blur = interpolate(frame, [0, 24], [0, 22], { ...CL, easing: Easing.bezier(0.4, 0, 0.4, 1) });
  const rule = interpolate(frame, [58, 70], [0, 1], { ...CL, easing: Easing.bezier(0.3, 0, 0.2, 1) });
  const tag = interpolate(frame, [68, 80], [0, 1], CL);
  const fadeOut = interpolate(frame, [duration - 12, duration], [1, 0], CL);
  const recede = interpolate(frame, [42, 50], [0, 1], CL);

  const craneT = interpolate(frame, [0, 40], [0, 1], { ...CL, easing: CRANE_EASE });
  const pushT = interpolate(frame, [40, duration], [0, 1], CL);
  const camScale = 1.06 - 0.06 * craneT + 0.035 * pushT;
  const camTilt = 4 * (1 - craneT);

  const sweepX = interpolate(frame, [2, 14], [-700, 2020], { ...CL, easing: Easing.bezier(0.4, 0, 0.6, 1) });
  const sweepOpacity = interpolate(frame, [2, 5, 11, 14], [0, 0.14, 0.14, 0], CL);
  const stageLight = interpolate(frame, [42, 50, 58], [0, 0.5, 0.25], CL);
  const vignette = interpolate(frame, [42, 54], [0, 0.14], CL);
  const ruleExt = interpolate(frame, [58, 66], [0, 1], { ...CL, easing: Easing.bezier(0.3, 0, 0.2, 1) });
  const ruleExtFade = interpolate(frame, [66, 72], [1, 0], CL);
  const wordSpacing = interpolate(frame, [62, 66], [-0.012, 0.004], {
    ...CL,
    easing: Easing.bezier(0.3, 0, 0.2, 1),
  });

  return (
    <AbsoluteFill style={{ opacity: fadeOut, background: C.canvas }}>
      <AbsoluteFill
        style={{
          transform: `perspective(1400px) rotateX(${camTilt}deg) scale(${camScale})`,
          transformOrigin: '50% 45%',
        }}
      >
        <PageCam
          src="textures/app-full.png"
          pageW={PAGE.w}
          pageH={PAGE.h}
          keys={CAM}
          blur={blur}
          saturate={0.85}
        />
        {/* scrim: keeps the centre readable without washing the photo out */}
        <AbsoluteFill
          style={{
            background:
              'radial-gradient(1200px 800px at 50% 48%, rgba(11,12,16,0.86), rgba(11,12,16,0.66) 60%, rgba(11,12,16,0.46))',
            pointerEvents: 'none',
          }}
        />

        <AbsoluteFill style={{ pointerEvents: 'none' }}>
          {ELS.map((el) => {
            if (frame < el.cue) return null;

            const t = interpolate(frame, [el.cue, el.cue + 12], [0, 1], { ...CL, easing: FLY_EASE });
            const opacity = interpolate(frame, [el.cue, el.cue + 3], [0, 1], CL);
            const x = el.dx * (1 - t);
            const y = el.dy * (1 - t);
            const rot = el.rot * (2 - t);
            const scale = el.scale * (1.12 - 0.12 * t);
            const air = Math.max(0, 1 - t);
            const shadow =
              air > 0.01
                ? `0 ${10 + 26 * air}px ${24 + 46 * air}px rgba(0,0,0,${0.42 + 0.2 * air}), 0 2px 6px rgba(0,0,0,.3)`
                : '0 10px 24px rgba(0,0,0,.42), 0 2px 6px rgba(0,0,0,.3)';
            const settledOpacity = opacity * (1 - 0.12 * recede);
            const saturate = 1 - 0.08 * recede;

            const linT = interpolate(frame, [el.cue, el.cue + 12], [0, 1], CL);
            const showGhost = linT > 0.05 && linT < 0.95;
            const glow = interpolate(frame, [el.cue + 12, el.cue + 18], [0.35, 0], CL);
            const showGlow = frame >= el.cue + 12 && frame < el.cue + 18;
            const glowR = el.w * el.scale * 0.5;

            const box = {
              position: 'absolute' as const,
              left: el.cx - el.w / 2,
              top: el.cy - el.h / 2,
              width: el.w,
              height: el.h,
              transformOrigin: 'center center' as const,
              borderRadius: el.radius,
              overflow: 'hidden' as const,
            };
            const lift = {
              border: '1px solid rgba(138,162,255,0.16)',
              filter: `saturate(${saturate}) brightness(1.16)`,
            };

            return (
              <div key={el.key}>
                {showGhost ? (
                  <div
                    style={{
                      ...box,
                      transform: `translate(${x + el.dx * 0.08}px, ${y + el.dy * 0.08}px) rotate(${rot}deg) scale(${scale})`,
                      opacity: 0.2 * Math.max(0, 1 - linT),
                      filter: 'blur(8px)',
                    }}
                  >
                    <Img
                      src={staticFile(`textures/${el.file}`)}
                      style={{ position: 'absolute', inset: 0, width: el.w, height: el.h, display: 'block' }}
                    />
                  </div>
                ) : null}
                <div
                  style={{
                    ...box,
                    transform: `translate(${x}px, ${y}px) rotate(${rot}deg) scale(${scale})`,
                    boxShadow: shadow,
                    opacity: settledOpacity,
                    ...lift,
                  }}
                >
                  <Img
                    src={staticFile(`textures/${el.file}`)}
                    style={{ position: 'absolute', inset: 0, width: el.w, height: el.h, display: 'block' }}
                  />
                </div>
                {showGlow ? (
                  <div
                    style={{
                      position: 'absolute',
                      left: el.cx - glowR,
                      top: el.cy - glowR,
                      width: glowR * 2,
                      height: glowR * 2,
                      borderRadius: '50%',
                      background:
                        'radial-gradient(circle, rgba(138,162,255,0.85), rgba(138,162,255,0) 70%)',
                      opacity: glow,
                      mixBlendMode: 'screen',
                    }}
                  />
                ) : null}
              </div>
            );
          })}
        </AbsoluteFill>
      </AbsoluteFill>

      {/* dust drifting up in front of the photo */}
      <AbsoluteFill style={{ pointerEvents: 'none' }}>
        {DUST.map((d, i) => {
          const y = (((d.y0 - frame * d.rise) % 1080) + 1080) % 1080;
          const x = d.x + Math.sin(frame * d.swayFreq + d.phase) * d.swayAmp;
          return (
            <div
              key={i}
              style={{
                position: 'absolute',
                left: x,
                top: y,
                width: d.size,
                height: d.size,
                borderRadius: '50%',
                background: C.indigo,
                opacity: d.opacity,
              }}
            />
          );
        })}
      </AbsoluteFill>

      {sweepOpacity > 0 ? (
        <AbsoluteFill style={{ pointerEvents: 'none', mixBlendMode: 'screen' }}>
          <div
            style={{
              position: 'absolute',
              top: 0,
              bottom: 0,
              left: sweepX - 300,
              width: 600,
              background:
                'linear-gradient(90deg, rgba(180,199,255,0), rgba(180,199,255,1) 50%, rgba(180,199,255,0))',
              opacity: sweepOpacity,
            }}
          />
        </AbsoluteFill>
      ) : null}

      {stageLight > 0 ? (
        <AbsoluteFill
          style={{
            pointerEvents: 'none',
            background:
              'radial-gradient(700px 360px at 960px 470px, rgba(138,162,255,0.55), rgba(138,162,255,0.18) 55%, rgba(138,162,255,0) 75%)',
            opacity: stageLight,
          }}
        />
      ) : null}

      {vignette > 0 ? (
        <AbsoluteFill
          style={{
            pointerEvents: 'none',
            background: 'radial-gradient(1400px 900px at 50% 50%, rgba(0,0,0,0) 55%, rgba(0,0,0,0.75) 100%)',
            opacity: vignette,
          }}
        />
      ) : null}

      <AbsoluteFill style={{ justifyContent: 'center', alignItems: 'center', pointerEvents: 'none' }}>
        <div style={{ textAlign: 'center' }}>
          <div
            style={{
              fontFamily: FONT.ui,
              fontSize: 172,
              fontWeight: 700,
              color: C.ink,
              letterSpacing: `${wordSpacing}em`,
              display: 'flex',
            }}
          >
            {LETTERS.map((ch, i) => {
              const delay = Math.round(42 + i * 1.8);
              const t = interpolate(frame, [delay, delay + 8], [0, 1], {
                ...CL,
                easing: Easing.bezier(0.2, 0.75, 0.3, 1),
              });
              return (
                <span
                  key={i}
                  style={{
                    opacity: t,
                    transform: `translateY(${(1 - t) * 28}px) scale(${1.35 - 0.35 * t})`,
                    filter: `blur(${(1 - t) * 8}px)`,
                    display: 'inline-block',
                    whiteSpace: 'pre',
                    color: ch === '°' ? C.accent : C.ink,
                  }}
                >
                  {ch}
                </span>
              );
            })}
          </div>
          <div style={{ position: 'relative', height: 6, width: 260, margin: '34px auto 0' }}>
            <div
              style={{
                position: 'absolute',
                inset: 0,
                borderRadius: 3,
                background: C.accent,
                transform: `scaleX(${rule})`,
              }}
            />
            {ruleExt > 0 && ruleExtFade > 0 ? (
              <>
                <div style={{ position: 'absolute', top: 2.5, height: 1, right: '100%', width: 190 * ruleExt, background: C.accent, opacity: ruleExtFade }} />
                <div style={{ position: 'absolute', top: 2.5, height: 1, left: '100%', width: 190 * ruleExt, background: C.accent, opacity: ruleExtFade }} />
              </>
            ) : null}
          </div>
          <div
            style={{
              fontFamily: FONT.mono,
              fontSize: 23,
              letterSpacing: '0.15em',
              color: C.inkSoft,
              marginTop: 30,
              opacity: tag,
              textTransform: 'uppercase',
            }}
          >
            Zero Homebrew dependencies · macOS + Linux
          </div>
        </div>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
