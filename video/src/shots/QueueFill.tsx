/* Shot 4 — the queue fills. Card `row-embed`, params verbatim: cue = 12 + i*9, 12f flight, land = cue+12,
 * scale 1.06->0.995 + 4f press-bounce, texture-crop bodies (never redrawn), 2px bottom seam. i=7 done f95. */
import React from 'react';
import { interpolate, staticFile, useCurrentFrame, Easing } from 'remotion';
import { PageCam, CamKey } from '../lib/PageCam';
import { C, PAGE } from '../theme';
import layout from '../layout.json';

const rows = layout.pages.app.boxes.rows;
const FLY_EASE = Easing.bezier(0.3, 0, 0.25, 1);
const fullSrc = staticFile('textures/app-full.png');
const emptySrc = staticFile('textures/app-empty-full.png');

/* Camera: opens on the top of the list and pans down past the last row while
   the rows are still landing. 75f of travel against a 125f shot. */
const CAM: CamKey[] = [
  { frame: 0, cx: 690, cy: 268, zoom: 1.36 },
  { frame: 78, cx: 690, cy: 452, zoom: 1.28 },
];

export const QueueFill: React.FC<{ durationInFrames: number }> = () => {
  const frame = useCurrentFrame();

  return (
    <PageCam
      src="textures/app-full.png"
      pageW={PAGE.w}
      pageH={PAGE.h}
      keys={CAM}
      ease={Easing.bezier(0.33, 0, 0.15, 1)}
    >
      {rows.map((r, i) => {
        const cue = 12 + i * 9;
        const land = cue + 12;

        // empty-slot patch, cropped out of the empty-queue capture of the very
        // same page; gone 2f after the row seats
        const patchOpacity = interpolate(frame, [land, land + 2], [1, 0], {
          extrapolateLeft: 'clamp',
          extrapolateRight: 'clamp',
        });
        const patch =
          patchOpacity > 0 ? (
            <div
              key={`patch-${i}`}
              style={{
                position: 'absolute',
                left: r.x,
                top: r.y,
                width: r.w,
                height: r.h,
                backgroundImage: `url(${emptySrc})`,
                backgroundSize: `${PAGE.w}px ${PAGE.h}px`,
                backgroundPosition: `-${r.x}px -${r.y}px`,
                opacity: patchOpacity,
                zIndex: 1,
                pointerEvents: 'none',
              }}
            />
          ) : null;

        // the flying row: a crop of the full page, dropping into its own slot.
        // Unmounted once the press-bounce is done so the baked texture shows.
        let flyer: React.ReactNode = null;
        if (frame >= cue && frame < cue + 16) {
          const p = interpolate(frame, [cue, cue + 12], [0, 1], {
            extrapolateLeft: 'clamp',
            extrapolateRight: 'clamp',
            easing: FLY_EASE,
          });
          const appear = interpolate(frame, [cue, cue + 3], [0, 1], {
            extrapolateLeft: 'clamp',
            extrapolateRight: 'clamp',
          });
          const scale =
            frame < land
              ? 1.06 - 0.065 * p
              : interpolate(frame, [land, land + 4], [0.995, 1], {
                  extrapolateLeft: 'clamp',
                  extrapolateRight: 'clamp',
                  easing: Easing.out(Easing.quad),
                });
          const air = 1 - p;
          flyer = (
            <div
              key={`row-${i}`}
              style={{
                position: 'absolute',
                left: r.x,
                top: r.y,
                width: r.w,
                height: r.h,
                borderRadius: 6,
                backgroundColor: C.row,
                backgroundImage: `url(${fullSrc})`,
                backgroundSize: `${PAGE.w}px ${PAGE.h}px`,
                backgroundPosition: `-${r.x}px -${r.y}px`,
                opacity: appear,
                transform: `perspective(900px) translateY(${-120 * air}px) rotateX(${16 * air}deg) scale(${scale})`,
                boxShadow: `0 ${30 * air}px ${60 * air}px rgba(0,0,0,${0.5 * air}), 0 ${8 * air}px ${16 * air}px rgba(0,0,0,${0.32 * air})`,
                zIndex: 3,
                pointerEvents: 'none',
              }}
            />
          );
        }

        // embed seam: accent line on the bottom edge only, spreading from the
        // centre. Clipped to the row's own width so nothing bleeds past it.
        let seam: React.ReactNode = null;
        if (frame >= land && frame < land + 8) {
          const spread = interpolate(frame, [land, land + 5], [0, 1], {
            extrapolateLeft: 'clamp',
            extrapolateRight: 'clamp',
            easing: Easing.out(Easing.cubic),
          });
          const seamOpacity = interpolate(frame, [land, land + 2, land + 8], [1, 1, 0], {
            extrapolateLeft: 'clamp',
            extrapolateRight: 'clamp',
          });
          const seamW = r.w * spread;
          seam = (
            <div
              key={`seam-${i}`}
              style={{
                position: 'absolute',
                left: r.x + (r.w - seamW) / 2,
                top: r.y + r.h - 2,
                width: seamW,
                height: 2,
                background: C.accent,
                /* The template's own alpha, restored: at full opacity the 6px halo on eight stacked
                   rows bled onto the sidebar, growing a ladder of glowing rungs instead of seams. */
                boxShadow: `0 0 6px rgba(138,162,255,0.35)`,
                borderRadius: 1,
                opacity: seamOpacity,
                zIndex: 4,
                pointerEvents: 'none',
              }}
            />
          );
        }

        return (
          <React.Fragment key={i}>
            {patch}
            {flyer}
            {seam}
          </React.Fragment>
        );
      })}
    </PageCam>
  );
};
