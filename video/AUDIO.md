# Audio assets for the keynote film

`video/public/audio/` is **not committed**. The music and sound effects are
third-party assets under licences that permit free commercial *use* but that we
should not redistribute as loose files in a public repository — the rendered
film is the product, the source mp3s are not ours to hand out.

Everything is Mixkit, free for commercial use with no attribution required.
`npm run render` needs the files present; fetch them once:

```sh
cd video && ./scripts/fetch-audio.sh
```

## What the film uses

`src/sound.ts` is the single source of truth for which file plays when. If you
change anything here, that table is what needs editing.

### BGM

| File | Track | Artist | BPM | Source |
|---|---|---|---|---|
| `bgm-house-vibez.mp3` | House Vibez | Lily J | ~123 | https://assets.mixkit.co/music/745/745.mp3 |

Chosen over the shot-library template's `bgm-tech-house.mp3`, which has a
slightly better built-in energy curve but whose licence provenance is recorded
as unverifiable. This film ships in a public product repo, so the track with a
documented licence and URL wins; the energy arc is drawn by hand in
`BGM_ENV` instead (the track itself measures flat at −11 to −12 dBFS throughout).

### SFX

All Mixkit Sound Effects Free License.

| File | Mixkit name | Source |
|---|---|---|
| `air-zoom-vacuum.mp3` | Air zoom vacuum | https://assets.mixkit.co/active_storage/sfx/2608/2608-preview.mp3 |
| `bass-transition-pulse.mp3` | Pulsating bass transition | https://assets.mixkit.co/active_storage/sfx/2295/2295-preview.mp3 |
| `drum-impact-subtle.mp3` | Deep cinematic subtle drum impact | https://assets.mixkit.co/active_storage/sfx/549/549-preview.mp3 |
| `shimmer-sparkle-sweep.mp3` | Sweeping sparkle presentation intro | https://assets.mixkit.co/active_storage/sfx/2633/2633-preview.mp3 |
| `sub-bass-knock.mp3` | Knocking sub bass | https://assets.mixkit.co/active_storage/sfx/2300/2300-preview.mp3 |
| `sweep-fast-small.mp3` | Fast small sweep transition | https://assets.mixkit.co/active_storage/sfx/166/166-preview.mp3 |

The remaining files — `click-camera`, `impact-cine`, `pop`, `riser-cine`,
`sparkle`, `swoosh-quick`, `transition-snap`, `transition-soft`, `whoosh-big`,
`whoosh-fast` — come from the shot library's first batch, whose per-file URLs
were not recorded at download time. They are declared Mixkit, **except `pop.mp3`,
whose origin is unknown and which is flagged for review before any commercial
use.** `scripts/fetch-audio.sh` copies these from the local shot library.
