/* Shot 6 — the detail panel, shot as terrain.
 *
 * Card: graze-face-tour
 * Exact demo read: demos/graze-face-tour/GrazeFaceTour.tsx
 *
 * Demo parameters kept verbatim: the FloatWrap hover-plus-same-shape-shadow
 * body (offset h*0.22 / h*0.42, blur 3.5 + h*0.085, brightness 0.32,
 * saturate 0.4, opacity min(0.38, 0.16 + h*0.004), and the element itself
 * translated -h*0.34 / -h*0.78); `liftOf` with FALL = 0.34 and
 * easeFall = bezier(0.5, 0.05, 0.6, 1); hover height in the card's 120-180px
 * band; land times distributed 0.18 -> 0.80 along the camera's travel so the
 * panel completes itself in front of the lens.
 *
 * Card 命门 honoured, and it is the one that makes or breaks the shot: the
 * shadow's blur, offset and opacity all track the CURRENT hover height and
 * converge to zero on contact. A constant shadow reads as a sticker.
 *
 * Two card rulings applied deliberately:
 *   - the airborne elements are lifted ~1.3x in brightness, because the card
 *     records a rejected take where hovering elements were swallowed by the
 *     ambient darkening and the hover therefore read as nothing at all.
 *   - stagger here is PARALLEL (offset starts, overlapping falls), which is the
 *     tour grammar. Shot 2 (neon-frame-orbit-drop) uses the opposite ruling —
 *     one shared landing frame — and the card pair explicitly notes that
 *     picking the wrong one gets both shots rejected. They stay distinct.
 *
 * This is a single continuous take rather than the demo's three cross-faded
 * segments: the path is one straight slide down a single panel, so the demo's
 * segment relay (and its documented black-flash pitfall at the seams) is not
 * needed. Camera and depth of field come from the film's own PageCam.
 */
import React from 'react';
import { interpolate, staticFile, useCurrentFrame, Easing } from 'remotion';
import { PageCam, CamKey } from '../lib/PageCam';
import { C, PAGE } from '../theme';
import layout from '../layout.json';

/* The capture hands back 11 boxes, but six of them are 33px key/value rows and
   one is an 11px summary line. Toured individually they are not faces, they are
   text lines: at any hover height above ~20px a lifted line sits exactly on top
   of its neighbour and the two sets of right-aligned values interleave into
   nonsense. So the rows are grouped into the six blocks a designer would
   actually name — title, badges, ring, tiles, the whole key/value table, and the
   action bar. Those have real edges, so they read as faces when they lift. */
const RAW = layout.pages.app.boxes.detailBlocks;
const GROUPS: number[][] = [[0], [1], [2], [3, 4], [5, 6, 7, 8, 9], [10]];
const blocks = GROUPS.map((g) => {
  const first = RAW[g[0]];
  const last = RAW[g[g.length - 1]];
  return { x: first.x, y: first.y, w: first.w, h: last.y + last.h - first.y };
});

const easeFall = Easing.bezier(0.5, 0.05, 0.6, 1);
const fullSrc = staticFile('textures/app-full.png');

const TRAVEL = 95; // frames of camera travel; the shot runs 130
const ZOOM = 1.9;

/* Hover height of a block. The card's 120-180px band is SCREEN px; these blocks
   live in page space and are magnified by the camera, so the band is divided by
   the zoom to land inside it on screen (72 * 1.9 = 137px). Left in page px it
   was 150 -> 285 screen px, which is where the line collisions came from. */
const HOVER = 120 / ZOOM;
const liftOf = (t: number, land: number, H = HOVER): number => {
  const FALL = 0.34;
  const p = Math.min(1, Math.max(0, (t - (land - FALL)) / FALL));
  return (1 - easeFall(p)) * H;
};

/* Camera: a big-tilt pass grazing down the face of the detail panel. The panel
   is only 339 page px wide, so it is framed right-of-centre with the queue it
   belongs to filling the left — centring it put a third of the frame off the
   page edge into black. */
const CAM: CamKey[] = [
  { frame: 0, cx: 1030, cy: 240, zoom: ZOOM, rotX: 11, rotY: 23, rotZ: -2.5, persp: 950 },
  { frame: TRAVEL, cx: 1052, cy: 600, zoom: ZOOM + 0.14, rotX: 8, rotY: 17, rotZ: -1, persp: 950 },
];

export const DetailTour: React.FC<{ durationInFrames: number }> = () => {
  const frame = useCurrentFrame();
  const t = Math.min(1, Math.max(0, frame / TRAVEL));

  return (
    <PageCam
      src="textures/app-full.png"
      pageW={PAGE.w}
      pageH={PAGE.h}
      keys={CAM}
      ease={Easing.bezier(0.4, 0, 0.3, 1)}
      dof={{ focusY: 430, strength: 9 }}
    >
      {blocks.map((b, i) => {
        // land order follows the camera's travel: what it passes first, seats first
        const land = 0.18 + (i / (blocks.length - 1)) * 0.62;
        const h = liftOf(t, land);
        const crop = {
          width: b.w,
          height: b.h,
          backgroundImage: `url(${fullSrc})`,
          backgroundSize: `${PAGE.w}px ${PAGE.h}px`,
          backgroundPosition: `-${b.x}px -${b.y}px`,
        } as const;

        return (
          <div
            key={i}
            style={{ position: 'absolute', left: b.x, top: b.y, pointerEvents: 'none' }}
          >
            {/* patch: the bare panel surface the block lifts off. The detail
                panel is a flat surface, so a flat fill is the true empty slot
                (unlike the striped list in shot 4, which needed a real capture). */}
            {h > 1 && (
              <div
                style={{
                  position: 'absolute',
                  left: -2,
                  top: -1,
                  width: b.w + 4,
                  height: b.h + 2,
                  background: C.surface,
                }}
              />
            )}
            {/* same-shape soft shadow, converging as the block descends */}
            {h > 1.5 && (
              <div
                style={{
                  position: 'absolute',
                  inset: 0,
                  transform: `translate(${h * 0.22}px, ${h * 0.42}px) scale(${1 + h * 0.0011})`,
                  filter: `blur(${3.5 + h * 0.085}px) brightness(0.32) saturate(0.4)`,
                  opacity: Math.min(0.38, 0.16 + h * 0.004),
                  ...crop,
                }}
              />
            )}
            <div
              style={{
                transform: `translate(${-h * 0.34}px, ${-h * 0.78}px)`,
                // airborne lift: without it the hover is invisible against the
                // ambient darkening (the card's rejected-take note)
                filter: h > 1 ? `brightness(${1 + 0.18 * Math.min(1, h / HOVER)})` : undefined,
                ...crop,
              }}
            />
          </div>
        );
      })}
    </PageCam>
  );
};
