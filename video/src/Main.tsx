import React from 'react';
import { AbsoluteFill, Audio, interpolate, Sequence, staticFile, useCurrentFrame } from 'remotion';
import { C } from './theme';
import { S, TOTAL, CAPTIONS } from './shots';
import { Caption } from './lib/Caption';
import { BGM, BGM_ENV, SFX, durOf, startOf } from './sound';

import { BrandOpen } from './shots/BrandOpen';
import { AppDebut } from './shots/AppDebut';
import { TitleCard } from './shots/TitleCard';
import { QueueFill } from './shots/QueueFill';
import { Throughput } from './shots/Throughput';
import { DetailTour } from './shots/DetailTour';
import { LineCarry } from './shots/LineCarry';
import { PieceMap } from './shots/PieceMap';
import { SftpTransfer } from './shots/SftpTransfer';
import { BrowserCapture } from './shots/BrowserCapture';
import { MenuBarDrop } from './shots/MenuBarDrop';
import { PortalCube } from './shots/PortalCube';
import { ThemeSweep } from './shots/ThemeSweep';
import { Outro } from './shots/Outro';

const Sound: React.FC = () => {
  const frame = useCurrentFrame();
  const bgmVolume = interpolate(frame, BGM_ENV.frames, BGM_ENV.values, {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  return (
    <>
      <Audio src={staticFile(BGM)} volume={bgmVolume} />
      {SFX.map((s, i) => (
        <Sequence key={i} from={startOf(s)} durationInFrames={durOf(s)}>
          <Audio src={staticFile(s.src)} volume={s.volume} />
        </Sequence>
      ))}
    </>
  );
};

export const Main: React.FC = () => (
  <AbsoluteFill style={{ background: C.canvas }}>
    <Sequence from={S.brandOpen.from} durationInFrames={S.brandOpen.dur}>
      <BrandOpen durationInFrames={S.brandOpen.dur} />
    </Sequence>

    <Sequence from={S.appDebut.from} durationInFrames={S.appDebut.dur}>
      <AppDebut durationInFrames={S.appDebut.dur} />
    </Sequence>

    <Sequence from={S.titleA.from} durationInFrames={S.titleA.dur}>
      <TitleCard durationInFrames={S.titleA.dur} lines={['Five protocols.', 'One queue.']} accentLine={1} />
    </Sequence>

    <Sequence from={S.queue.from} durationInFrames={S.queue.dur}>
      <QueueFill durationInFrames={S.queue.dur} />
    </Sequence>

    <Sequence from={S.throughput.from} durationInFrames={S.throughput.dur}>
      <Throughput durationInFrames={S.throughput.dur} />
    </Sequence>

    <Sequence from={S.detail.from} durationInFrames={S.detail.dur}>
      <DetailTour durationInFrames={S.detail.dur} />
    </Sequence>

    <Sequence from={S.carry.from} durationInFrames={S.carry.dur}>
      <LineCarry durationInFrames={S.carry.dur} />
    </Sequence>

    <Sequence from={S.pieces.from} durationInFrames={S.pieces.dur}>
      <PieceMap durationInFrames={S.pieces.dur} />
    </Sequence>

    <Sequence from={S.sftp.from} durationInFrames={S.sftp.dur}>
      <SftpTransfer durationInFrames={S.sftp.dur} />
    </Sequence>

    <Sequence from={S.titleB.from} durationInFrames={S.titleB.dur}>
      <TitleCard durationInFrames={S.titleB.dur} lines={['Everywhere', 'you already are.']} accentLine={0} />
    </Sequence>

    <Sequence from={S.capture.from} durationInFrames={S.capture.dur}>
      <BrowserCapture durationInFrames={S.capture.dur} />
    </Sequence>

    <Sequence from={S.menubar.from} durationInFrames={S.menubar.dur}>
      <MenuBarDrop durationInFrames={S.menubar.dur} />
    </Sequence>

    <Sequence from={S.portal.from} durationInFrames={S.portal.dur}>
      <PortalCube durationInFrames={S.portal.dur} />
    </Sequence>

    <Sequence from={S.themes.from} durationInFrames={S.themes.dur}>
      <ThemeSweep durationInFrames={S.themes.dur} />
    </Sequence>

    <Sequence from={S.outro.from} durationInFrames={S.outro.dur}>
      <Outro durationInFrames={S.outro.dur} />
    </Sequence>

    {CAPTIONS.map((c, i) => (
      <Sequence key={i} from={c.from} durationInFrames={c.dur}>
        <Caption text={c.text} sub={c.sub} duration={c.dur} />
      </Sequence>
    ))}

    <Sound />
  </AbsoluteFill>
);

export const DURATION = TOTAL;
