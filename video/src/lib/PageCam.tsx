import { AbsoluteFill, Img, interpolate, staticFile, useCurrentFrame, Easing } from 'remotion';

export type CamKey = {
  frame: number;
  cx: number;
  cy: number;
  zoom: number;
  rotX?: number; // deg; positive leans the top away
  rotY?: number; // deg; positive recedes the right edge, i.e. seen from the LEFT
  rotZ?: number;
  persp?: number; // px; default 1400, and smaller is stronger
};

const lerp = (a: number, b: number, t: number) => a + (b - a) * t;

/** (cx, cy) is the page-space CSS point centred in 1920x1080; absent rotX/rotZ/persp must stay pixel-flat. */
export const PageCam: React.FC<{
  src: string; // staticFile path under textures/live/
  pageH: number;
  pageW?: number;
  keys: CamKey[];
  children?: React.ReactNode; // page-space overlays, positioned in CSS px
  blur?: number;
  saturate?: number;
  ease?: (t: number) => number;
  dof?: { focusY: number; strength: number };
  // A <Sequence> rebases useCurrentFrame, so the parent passes the absolute frame CAM_KEYS refer to.
  frame?: number;
}> = ({ src, pageH, pageW = 1920, keys, children, blur = 0, saturate = 1, ease = Easing.bezier(0.33, 0, 0.15, 1), dof, frame: frameProp }) => {
  const ownFrame = useCurrentFrame();
  const frame = frameProp ?? ownFrame;
  let a = keys[0], b = keys[keys.length - 1];
  for (let i = 0; i < keys.length - 1; i++) {
    if (frame >= keys[i].frame && frame <= keys[i + 1].frame) { a = keys[i]; b = keys[i + 1]; break; }
  }
  const t = a.frame === b.frame ? 1 : interpolate(frame, [a.frame, b.frame], [0, 1], {
    extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: ease,
  });
  const cx = lerp(a.cx, b.cx, t);
  const cy = lerp(a.cy, b.cy, t);
  const zoom = lerp(a.zoom, b.zoom, t);

  const filters: string[] = [];
  if (blur > 0) filters.push(`blur(${blur}px)`);
  if (saturate !== 1) filters.push(`saturate(${saturate})`);

  // With no 3D key the flat markup must be emitted exactly, or every 2D shot shifts.
  const has3D = keys.some((k) => k.rotX !== undefined || k.rotY !== undefined || k.rotZ !== undefined || k.persp !== undefined);

  if (!has3D) {
    return (
      <AbsoluteFill style={{ overflow: 'hidden', backgroundColor: '#0b0c10' }}>
        <div
          style={{
            position: 'absolute', width: pageW, height: pageH,
            transform: `translate(${960 - cx * zoom}px, ${540 - cy * zoom}px) scale(${zoom})`,
            transformOrigin: '0 0',
            filter: filters.length ? filters.join(' ') : undefined,
          }}
        >
          <Img src={staticFile(src)} style={{ position: 'absolute', width: pageW, height: pageH }} />
          {children}
        </div>
      </AbsoluteFill>
    );
  }

  // Pivot about (cx, cy) so at rotX=rotZ=0 this reduces to the flat (960,540) + zoom*(p - (cx,cy)).
  const rotX = lerp(a.rotX ?? 0, b.rotX ?? 0, t);
  const rotY = lerp(a.rotY ?? 0, b.rotY ?? 0, t);
  const rotZ = lerp(a.rotZ ?? 0, b.rotZ ?? 0, t);
  const persp = lerp(a.persp ?? 1400, b.persp ?? 1400, t);

  return (
    <AbsoluteFill style={{ overflow: 'hidden', backgroundColor: '#0b0c10' }}>
      <div
        style={{
          position: 'absolute', inset: 0,
          perspective: `${persp * zoom}px`,
          perspectiveOrigin: '960px 540px',
        }}
      >
        {/* CSS `zoom`, never scale(zoom): scale rasterizes at 1920 then GPU-upscales into blurry text. */}
        <div
          style={{
            position: 'absolute', width: pageW, height: pageH,
            zoom,
            transform: `translate(${960 / zoom - cx}px, ${540 / zoom - cy}px) rotateY(${rotY}deg) rotateX(${rotX}deg) rotateZ(${rotZ}deg)`,
            transformOrigin: `${cx}px ${cy}px`,
            transformStyle: 'preserve-3d',
            filter: filters.length ? filters.join(' ') : undefined,
          }}
        >
          <Img src={staticFile(src)} style={{ position: 'absolute', width: pageW, height: pageH }} />
          {children}
        </div>
      </div>

      {/* Depth-of-field band: screen-space, so it stays outside the transformed page. */}
      {dof ? (
        <div
          style={{
            position: 'absolute',
            left: 0,
            right: 0,
            top: 0,
            height: Math.max(0, dof.focusY),
            backdropFilter: `blur(${dof.strength}px)`,
            WebkitBackdropFilter: `blur(${dof.strength}px)`,
            maskImage: 'linear-gradient(to bottom, rgba(0,0,0,1) 0%, rgba(0,0,0,1) 45%, rgba(0,0,0,0) 100%)',
            WebkitMaskImage: 'linear-gradient(to bottom, rgba(0,0,0,1) 0%, rgba(0,0,0,1) 45%, rgba(0,0,0,0) 100%)',
            pointerEvents: 'none',
          }}
        />
      ) : null}
    </AbsoluteFill>
  );
};
