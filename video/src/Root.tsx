import React from 'react';
import { Composition } from 'remotion';
import { Main, DURATION } from './Main';
import './fonts.css';

export const RemotionRoot: React.FC = () => (
  <Composition
    id="GoelKeynote"
    component={Main}
    durationInFrames={DURATION}
    fps={30}
    width={1920}
    height={1080}
  />
);
