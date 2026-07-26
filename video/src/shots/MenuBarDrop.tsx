/* Shot 12 — the menu bar.
 *
 * Card: command-palette-summon
 * Exact demo read: demos/command-palette-summon/CommandPaletteSummon.tsx
 *
 * Demo parameters kept verbatim: the world dims to 45% and blurs 10px across
 * frames 12 -> 22; the panel starts 20px high and drops with a real overshoot —
 * 9f out-cubic down to +8px, then 6f inOut-cubic back to 0 — because the card is
 * explicit that without the overshoot the whole thing reads as a fade and the
 * ceremony is gone; the panel's own opacity resolves over 7f; the candidate rows
 * stagger 4f apart, each rising 12px over 8f.
 *
 * Two of the card's six phases are deliberately not staged, and it is worth
 * saying why rather than leaving it to be noticed: phase 5 (typing narrows the
 * list) and the blinking caret have no counterpart here. This is a menu-bar
 * popover, not a search field — there is nothing to type into. What the card
 * treats as its remaining backbone (dim, overshoot drop, staggered rows, a held
 * final state) is all present, and the card's own instruction that the candidate
 * rows must carry real feature names is satisfied literally: these are the four
 * live transfers from the queue the film has been following since shot 4, with
 * their real progress bars.
 *
 * Budget: rows finish at 52, the selection settles by 70, and the shot runs 100
 * frames — 30f of true rest.
 */
import React from 'react';
import { AbsoluteFill, Img, interpolate, staticFile, useCurrentFrame, Easing } from 'remotion';
import { C, PAGE } from '../theme';
import layout from '../layout.json';

const CL = { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' } as const;

const DIM0 = 12;
const DIM1 = 22;
const PANEL_IN = 18;
const ROWS_START = 32;
const SEL = 60; // the first row takes selection

const POP = layout.pages.menubar.boxes.popover; // 570,36 340x377.5
const POP_ROWS = layout.pages.menubar.boxes.popRows;
const HEAD_H = POP_ROWS[0].y - POP.y; // 41
const ROWS_H = POP_ROWS.length * POP_ROWS[0].h; // 254
const EMPTY_H = layout.pages['menubar-norows'].boxes.popover.h; // 123.5
const FOOT_H = EMPTY_H - HEAD_H;

// page (1480x841) scaled up to fill the 1920x1080 frame
const ZOOM = 1920 / PAGE.w;
const OY = (1080 - PAGE.h * ZOOM) / 2;

const emptySrc = staticFile('textures/popover-empty.png');

export const MenuBarDrop: React.FC<{ durationInFrames: number }> = () => {
  const frame = useCurrentFrame();

  const dim = interpolate(frame, [DIM0, DIM1], [0, 0.45], CL);
  const blur = interpolate(frame, [DIM0, DIM1], [0, 10], CL);

  const panelY =
    frame < PANEL_IN + 9
      ? interpolate(frame, [PANEL_IN, PANEL_IN + 9], [-20, 8], { ...CL, easing: Easing.out(Easing.cubic) })
      : interpolate(frame, [PANEL_IN + 9, PANEL_IN + 15], [8, 0], { ...CL, easing: Easing.inOut(Easing.cubic) });
  const panelOp = interpolate(frame, [PANEL_IN, PANEL_IN + 7], [0, 1], CL);

  return (
    <AbsoluteFill style={{ background: C.canvas, overflow: 'hidden' }}>
      <div
        style={{
          position: 'absolute',
          left: 0,
          top: OY,
          width: PAGE.w,
          height: PAGE.h,
          transform: `scale(${ZOOM})`,
          transformOrigin: '0 0',
        }}
      >
        {/* the desktop: menu bar plus the running app, making way */}
        <div style={{ filter: frame < DIM0 ? undefined : `blur(${blur}px)` }}>
          <Img
            src={staticFile('textures/desktop-full.png')}
            style={{ position: 'absolute', inset: 0, width: PAGE.w, height: PAGE.h }}
          />
        </div>
        <div style={{ position: 'absolute', inset: 0, background: `rgba(8,9,13,${dim})` }} />

        {frame >= PANEL_IN && (
          <div
            style={{
              position: 'absolute',
              left: POP.x,
              top: POP.y,
              width: POP.w,
              height: POP.h,
              transform: `translateY(${panelY}px)`,
              opacity: panelOp,
              borderRadius: 13,
              background: 'rgba(38, 41, 51, 0.97)',
              border: '1px solid rgba(255,255,255,0.10)',
              boxShadow: '0 26px 64px -14px rgba(0,0,0,0.7)',
              overflow: 'hidden',
            }}
          >
            {/* header, cropped from the row-less capture of the same popover */}
            <div
              style={{
                position: 'absolute',
                left: 0,
                top: 0,
                width: POP.w,
                height: HEAD_H,
                backgroundImage: `url(${emptySrc})`,
                backgroundSize: `${POP.w}px ${EMPTY_H}px`,
                backgroundPosition: '0 0',
              }}
            />
            {/* the four live transfers, staggering up */}
            {POP_ROWS.map((r, i) => {
              const inStart = ROWS_START + i * 4;
              const op = interpolate(frame, [inStart, inStart + 8], [0, 1], CL);
              const y = interpolate(frame, [inStart, inStart + 8], [12, 0], {
                ...CL,
                easing: Easing.out(Easing.cubic),
              });
              const hl = i === 0 ? interpolate(frame, [SEL, SEL + 10], [0, 1], CL) : 0;
              return (
                <div
                  key={i}
                  style={{
                    position: 'absolute',
                    left: 0,
                    top: HEAD_H + i * r.h,
                    width: POP.w,
                    height: r.h,
                    opacity: op,
                    transform: `translateY(${y}px)`,
                    background: hl > 0 ? `rgba(138,162,255,${0.10 * hl})` : 'transparent',
                    boxShadow: hl > 0 ? `inset 3px 0 0 rgba(138,162,255,${hl})` : 'none',
                  }}
                >
                  <Img
                    src={staticFile(`textures/pop-row${i + 1}.png`)}
                    style={{ position: 'absolute', inset: 0, width: POP.w, height: r.h, display: 'block' }}
                  />
                </div>
              );
            })}
            {/* footer, cropped from the same row-less capture */}
            <div
              style={{
                position: 'absolute',
                left: 0,
                top: HEAD_H + ROWS_H,
                width: POP.w,
                height: FOOT_H,
                backgroundImage: `url(${emptySrc})`,
                backgroundSize: `${POP.w}px ${EMPTY_H}px`,
                backgroundPosition: `0 -${HEAD_H}px`,
              }}
            />
          </div>
        )}
      </div>
    </AbsoluteFill>
  );
};
