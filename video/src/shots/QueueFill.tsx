import React from 'react';
import { interpolate, staticFile, useCurrentFrame, Easing } from 'remotion';
import { PageCam, CamKey } from '../lib/PageCam';
import { C, PAGE } from '../theme';
import layout from '../layout.json';

const rows = layout.pages.app.boxes.rows;
const FLY_EASE = Easing.bezier(0.3, 0, 0.25, 1);
const fullSrc = staticFile('textures/app-full.png');
const emptySrc = staticFile('textures/app-empty-full.png');

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
