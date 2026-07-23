# T10 — Player: play while downloading

**Goal:** frame 4 of `visual.html`. A signature moment from PRD §6.3 — value at 23%,
not at 100%.

## The mechanism

T05's sequential mode guarantees bytes `0…n` are contiguous. So the partial file is a
valid, playable prefix. `AVPlayer` can open it; the only trick is that it must not treat
EOF-at-the-write-head as end-of-stream.

Two viable approaches, in order of preference:

1. **Local `AVAssetResourceLoaderDelegate`** — register a custom scheme, serve byte ranges
   out of the partial file, and *pend* requests that reach past the write head until more
   bytes land. This is the correct implementation and it is genuinely how this is done.
2. **Fallback if (1) fights you:** poll — reload the `AVURLAsset` from the partial file
   when playback stalls, seeking back to the saved position. Ugly, visible, but it works.

Pick (1). Time-box it; if it is not working in ~45 minutes, take (2) and note it in
`REPORT.md`. Do not let this task eat the night.

## Build

**`Features/Player/PlayerView.swift`**
- `VideoPlayer` (or a `UIViewRepresentable` over `AVPlayerLayer` if you need the resource
  loader) filling a 232pt hero area.
- **Custom scrubber** — the system controls cannot show the three states the mockup
  requires:
  - `played` — solid white
  - `buffered` (downloaded but not played) — white at 26%
  - remainder — `rgba(120,120,128,.3)`
  - 6pt track, 13pt round knob, draggable, seek on release.
- Time labels: elapsed `3:42` and remaining `−37:18`, 11.5pt secondary, tabular.
- **The ember banner** below the scrubber: *"Playing at 23% — still downloading at
  48.2 MB/s"* on a 13%-opacity ember ground, radius 11, with a star glyph.
- A stats card: **`Buffer: +33 min`** (green) and `Mode: Sequential`.
  Express the lead in **minutes, not bytes** — that is the number a person can act on.
- Seeking past the write head must be **prevented, visibly**: clamp the knob at the
  buffered edge rather than allowing a seek that stalls forever.

## Exit criteria

- Put a real video in `Scripts/ios/fixtures/` (generate one with `ffmpeg` if available;
  otherwise download a small public sample once, or synthesize with
  `AVAssetWriter` in a test). Serve it through `range-server.py --throttle`.
- Start it as a sequential download, and **begin playback at under 30% complete**.
  It must play. That is the gate.
- `Scripts/ios/sim.sh shot T10-player`, **Read it**, compare to frame 4 — three-state
  scrubber clearly distinguishable.
- Confirm the buffered edge advances while playing.
- `git commit -m "ios(T10): play-while-downloading player"`

## Notes

- Audio in the simulator is unreliable; judge success by the video advancing and the
  buffered edge moving, not by sound.
- If the asset will not open at all, confirm the container format supports progressive
  playback — a `.mp4` needs `moov` at the front (`-movflags +faststart`). A file with the
  atom at the end is unplayable until complete, and that is the file's fault, not yours.
  Detect it and say so in the UI rather than spinning forever.
