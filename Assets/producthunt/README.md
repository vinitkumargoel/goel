# Product Hunt gallery assets

Launch-ready gallery images for **Goel°** on Product Hunt.

- **7 landscape slides**, each **1905×1140 px** — the exact Product Hunt gallery ratio (1270×760 / 1.67:1), rendered at 1.5× for crispness. PNG, well under the 5 MB limit.
- Two themes: **`dark/`** (vivid brand gradient) and **`light/`**. Pick one theme and upload the files **in numeric order (01 → 07)**. Image `01` becomes the thumbnail and the one shared to social, so it leads.
- `overview-dark.png` / `overview-light.png` show all 7 slides of a theme at a glance.

## Slides

| # | File | Feature |
|---|------|---------|
| 01 | `hero` | Every download, one native queue |
| 02 | `queue` | Five protocols, one list |
| 03 | `detail` | Live progress & per-file detail |
| 04 | `linux` | Linux web portal — same engine, any browser |
| 05 | `menubar` | Menu-bar extra |
| 06 | `capture` | Browser capture *(illustrative)* |
| 07 | `extensions` | Browser extensions + Link Grabber *(illustrative)* |

> **Slides 06 and 07 are illustrative mock panels** (designed to match the app's UI), because there are no real screenshots of the browser-capture flow or the extension popover yet. They're accurate to the described features — swap in real captures when you have them.

## Source

Composited from `Assets/screenshots/*` (desktop app, web portal, menu-bar) and `Assets/AppIcon-Light-1024.png`, laid out in HTML/CSS and rendered to exact pixels with Playwright. Slides 01–05 are real screenshots (01 full app; 02/03 are framed views of the desktop app); 06–07 are designed illustrations.
