import React from 'react';
import { AbsoluteFill, Easing, interpolate, staticFile, useCurrentFrame } from 'remotion';
import { C, PAGE } from '../theme';
import layout from '../layout.json';

const cells = layout.pages.torrent.boxes.cells;
const [head, map, rate, facts, actions] = cells;

/* Capture yields seven boxes but the card fixes six, so `facts` swallows the action bar and each rail cell grows to meet the next. */
const grow = (b: typeof head, nextY: number) => ({ x: b.x, y: b.y, w: b.w, h: nextY - b.y });
const headBlock = grow(head, map.y);
const mapBlock = grow(map, rate.y);
const factsBlock = grow(facts, actions.y + actions.h);

/* Chrome strips must tile the GAPS only: a full-window backplate doubled every list row while the cells rise. */
const CHROME: { x: number; y: number; w: number; h: number }[] = [
  { x: 60, y: 60, w: 1360, h: 51 },
  { x: 60, y: 744, w: 1360, h: 37 },
  { x: 1081, y: 111, w: 19, h: 633 },
  { x: 1402, y: 111, w: 18, h: 633 },
  { x: 1100, y: 111, w: 302, h: 16 },
  { x: 1100, y: 728, w: 302, h: 16 },
];

const WALL: { key: string; x: number; y: number; w: number; h: number }[] = [
  { key: 'map', ...mapBlock },
  { key: 'head', ...headBlock },
  { key: 'rate', ...rate },
  { key: 'facts', ...factsBlock },
  { key: 'list', x: 260, y: 111, w: 821, h: 633 },
  { key: 'side', x: 60, y: 111, w: 200, h: 633 },
];

const LAST = 20 + 5 * 12;

const FIRST = 20;
const GAP = 12;
const GUTTER = 3;
const RADIUS = 10;

const ZOOM = 1.37;
const OX = (1920 - 1360 * ZOOM) / 2 - 60 * ZOOM;
const OY = (1080 - 721 * ZOOM) / 2 - 60 * ZOOM;

const src = staticFile('textures/torrent-full.png');

const Cell: React.FC<{ i: number; frame: number }> = ({ i, frame }) => {
  const c = WALL[i];
  const start = FIRST + i * GAP;
  const w = c.w - GUTTER * 2;
  const h = c.h - GUTTER * 2;

  const draw = interpolate(frame, [start, start + 8], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.out(Easing.cubic),
  });
  const strokeFade = interpolate(frame, [start + 12, start + 26], [1, 0.4], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.out(Easing.quad),
  });
  const lit = interpolate(frame, [start + 6, start + 14], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.out(Easing.cubic),
  });
  const rise = interpolate(frame, [start + 6, start + 14], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.bezier(0.3, 1.4, 0.5, 1),
  });

  const opacity = 0.18 + 0.82 * lit;
  const ty = 20 * (1 - rise);
  const jitter = Math.abs(((Math.sin(i * 127.3) * 43758.5453) % 1));
  const pulse = lit * (1 - lit) * 4;
  const glow = pulse * (14 + jitter * 6);

  return (
    <div style={{ position: 'absolute', left: c.x + GUTTER, top: c.y + GUTTER, width: w, height: h }}>
      <div
        style={{
          position: 'absolute',
          inset: 0,
          opacity,
          transform: `translateY(${ty}px)`,
          borderRadius: RADIUS,
          overflow: 'hidden',
          boxShadow: lit > 0.5 ? `0 0 ${glow}px rgba(138,162,255,${0.35 * pulse})` : 'none',
          backgroundImage: `url(${src})`,
          backgroundSize: `${PAGE.w}px ${PAGE.h}px`,
          backgroundPosition: `-${c.x + GUTTER}px -${c.y + GUTTER}px`,
        }}
      />
      {draw > 0 && (
        <svg
          width={w}
          height={h}
          viewBox={`0 0 ${w} ${h}`}
          style={{ position: 'absolute', left: 0, top: ty, overflow: 'visible' }}
        >
          <rect
            x={1.5}
            y={1.5}
            width={w - 3}
            height={h - 3}
            rx={RADIUS}
            fill="none"
            stroke={C.accent}
            strokeWidth={3}
            pathLength={100}
            strokeDasharray={100}
            strokeDashoffset={100 * (1 - draw)}
            opacity={strokeFade}
            style={{ filter: `drop-shadow(0 0 ${5 + jitter * 4}px ${C.accent})` }}
          />
        </svg>
      )}
    </div>
  );
};

export const PieceMap: React.FC<{ durationInFrames: number }> = () => {
  const frame = useCurrentFrame();

  const plate = interpolate(frame, [LAST + 6, LAST + 20], [0.18, 0.58], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.out(Easing.cubic),
  });

  const push = interpolate(frame, [96, 121], [1, 1.04], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.bezier(0.33, 0, 0.2, 1),
  });

  return (
    <AbsoluteFill style={{ background: C.canvas, overflow: 'hidden' }}>
      <div style={{ position: 'absolute', inset: 0, transform: `scale(${push})`, transformOrigin: '960px 540px' }}>
        <div
          style={{
            position: 'absolute',
            left: 0,
            top: 0,
            width: PAGE.w,
            height: PAGE.h,
            transform: `translate(${OX}px, ${OY}px) scale(${ZOOM})`,
            transformOrigin: '0 0',
          }}
        >
          {CHROME.map((r, i) => (
            <div
              key={`chrome-${i}`}
              style={{
                position: 'absolute',
                left: r.x,
                top: r.y,
                width: r.w,
                height: r.h,
                opacity: plate,
                backgroundImage: `url(${src})`,
                backgroundSize: `${PAGE.w}px ${PAGE.h}px`,
                backgroundPosition: `-${r.x}px -${r.y}px`,
              }}
            />
          ))}
          {WALL.map((_, i) => (
            <Cell key={i} i={i} frame={frame} />
          ))}
        </div>
      </div>
    </AbsoluteFill>
  );
};
