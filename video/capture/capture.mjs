import puppeteer from 'puppeteer';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const OUT = path.join(ROOT, 'public', 'textures');
const LAYOUT_JSON = path.join(ROOT, 'src', 'layout.json');
const PAGE_URL = pathToFileURL(path.join(HERE, 'index.html')).href;

const VIEWPORT = { width: 1480, height: 841, deviceScaleFactor: 2 };

const JOBS = [
  {
    name: 'app',
    query: { page: 'app' },
    window: 'app-window',
    cutouts: [
      { name: 'sidebar', sel: '[data-cap="sidebar"]' },
      { name: 'toolbar', sel: '[data-cap="toolbar"]' },
      { name: 'detail', sel: '[data-cap="detail"]' },
      { name: 'statusbar', sel: '[data-cap="statusbar"]' },
      { name: 'ring', sel: '[data-cap="ring"]', transparent: true },
      { name: 'ud-tiles', sel: '[data-cap="ud-tiles"]', transparent: true },
      { name: 'row', sel: '.row', all: true, max: 8 },
      { name: 'list', sel: '[data-cap="list"]' },
    ],
    boxes: [
      { key: 'window', sel: '[data-cap="window"]' },
      { key: 'rows', sel: '.row', all: true },
      { key: 'rowsHost', sel: '[data-cap="rows"]' },
      { key: 'sidebar', sel: '[data-cap="sidebar"]' },
      { key: 'toolbar', sel: '[data-cap="toolbar"]' },
      { key: 'detail', sel: '[data-cap="detail"]' },
      { key: 'ring', sel: '[data-cap="ring"]' },
      { key: 'statusbar', sel: '[data-cap="statusbar"]' },
      { key: 'speedDown', sel: '[data-cap="speed-down"]' },
      { key: 'btnAdd', sel: '[data-cap="btn-add"]' },
      { key: 'list', sel: '[data-cap="list"]' },
      { key: 'progressBars', sel: '.row .pbar', all: true },
      { key: 'protoBadges', sel: '.row .proto', all: true },
      { key: 'udTiles', sel: '[data-cap="ud-tiles"]' },
      { key: 'detailBlocks', sel: '.detail > *', all: true },
    ],
  },
  {
    name: 'app-empty',
    query: { page: 'app-empty' },
    window: 'app-window-empty',
    cutouts: [],
    boxes: [{ key: 'window', sel: '[data-cap="window"]' }],
  },
  {
    name: 'torrent',
    query: { page: 'torrent' },
    window: 'torrent-window',
    cutouts: [
      { name: 'pmap', sel: '[data-cap="pmap"]' },
      { name: 'tcell', sel: '[data-cap^="tcell-"]', all: true, max: 5, transparent: true },
      { name: 'torrent-detail', sel: '[data-cap="detail"]' },
    ],
    boxes: [
      { key: 'window', sel: '[data-cap="window"]' },
      { key: 'detail', sel: '[data-cap="detail"]' },
      { key: 'pmap', sel: '[data-cap="pmap"]' },
      { key: 'pieces', sel: '.pmap i', all: true },
      { key: 'cells', sel: '[data-cap^="tcell-"]', all: true },
    ],
  },
  {
    name: 'sftp',
    query: { page: 'sftp' },
    window: 'sftp-window',
    cutouts: [
      { name: 'pane-remote', sel: '[data-cap="pane-remote"]' },
      { name: 'pane-local', sel: '[data-cap="pane-local"]' },
      { name: 'sftp-chip', sel: '[data-cap="sftp-hot"]', transparent: true },
    ],
    boxes: [
      { key: 'window', sel: '[data-cap="window"]' },
      { key: 'paneRemote', sel: '[data-cap="pane-remote"]' },
      { key: 'paneLocal', sel: '[data-cap="pane-local"]' },
      { key: 'hotRow', sel: '[data-cap="sftp-hot"]' },
    ],
  },
  {
    name: 'menubar',
    query: { page: 'menubar', canvas: '1' },
    cutouts: [
      { name: 'popover', sel: '[data-cap="popover"]', transparent: true },
      { name: 'pop-row', sel: '.pop-row', all: true, max: 4, transparent: true },
    ],
    boxes: [
      { key: 'popover', sel: '[data-cap="popover"]' },
      { key: 'popRows', sel: '.pop-row', all: true },
      { key: 'menubar', sel: '.menubar' },
    ],
  },
  {
    name: 'chip',
    query: { page: 'chip', canvas: '0' },
    cutouts: [{ name: 'transfer-chip', sel: '[data-cap="chip"]', transparent: true }],
    boxes: [{ key: 'chip', sel: '[data-cap="chip"]' }],
  },
  {
    name: 'desktop',
    query: { page: 'desktop', canvas: '1' },
    cutouts: [],
    boxes: [{ key: 'menubar', sel: '.menubar' }, { key: 'window', sel: '[data-cap="window"]' }],
  },
  {
    name: 'menubar-norows',
    query: { page: 'menubar-norows', canvas: '1' },
    cutouts: [{ name: 'popover-empty', sel: '[data-cap="popover"]', transparent: true }],
    boxes: [{ key: 'popover', sel: '[data-cap="popover"]' }],
  },
  {
    name: 'portal',
    query: { page: 'portal' },
    window: 'portal-window',
    cutouts: [],
    boxes: [
      { key: 'window', sel: '[data-cap="window"]' },
      { key: 'rows', sel: '.row', all: true },
    ],
  },
  ...['frost-dark', 'frost-light', 'dracula', 'nord'].map((t) => ({
    name: `theme-${t}`,
    query: { page: 'app', theme: t === 'frost-dark' ? '' : t },
    window: `theme-${t}-window`,
    cutouts: [],
    boxes: [{ key: 'window', sel: '[data-cap="window"]' }],
  })),
];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function bbox(page, sel, all) {
  return page.evaluate(
    ({ sel, all }) => {
      const pick = (el) => {
        const r = el.getBoundingClientRect();
        return {
          x: Math.round((r.x + scrollX) * 100) / 100,
          y: Math.round((r.y + scrollY) * 100) / 100,
          w: Math.round(r.width * 100) / 100,
          h: Math.round(r.height * 100) / 100,
        };
      };
      const els = [...document.querySelectorAll(sel)];
      if (!els.length) return null;
      return all ? els.map(pick) : pick(els[0]);
    },
    { sel, all }
  );
}

async function run() {
  fs.mkdirSync(OUT, { recursive: true });
  fs.mkdirSync(path.dirname(LAYOUT_JSON), { recursive: true });

  const browser = await puppeteer.launch({
    headless: true,
    args: ['--allow-file-access-from-files', '--force-color-profile=srgb', '--font-render-hinting=none'],
  });
  const page = await browser.newPage();
  await page.setViewport(VIEWPORT);

  const layout = { viewport: VIEWPORT, pages: {} };

  for (const job of JOBS) {
    const qs = new URLSearchParams(
      Object.fromEntries(Object.entries(job.query).filter(([, v]) => v !== ''))
    );
    await page.goto(`${PAGE_URL}?${qs}`, { waitUntil: 'load' });
    await page.waitForFunction(() => document.documentElement.dataset.ready === '1', {
      timeout: 15000,
    });
    await sleep(600);

    await page.screenshot({ path: path.join(OUT, `${job.name}-full.png`), fullPage: false });

    if (job.window) {
      const el = await page.$('[data-cap="window"]');
      if (el) {
        await el.screenshot({ path: path.join(OUT, `${job.window}.png`), omitBackground: true });
      }
    }

    for (const c of job.cutouts) {
      const els = await page.$$(c.sel);
      if (!els.length) {
        console.warn(`  ! no match for cutout ${c.name} (${c.sel})`);
        continue;
      }
      const list = c.all ? els.slice(0, c.max ?? els.length) : [els[0]];
      for (let i = 0; i < list.length; i++) {
        const file = c.all ? `${c.name}${i + 1}.png` : `${c.name}.png`;
        await list[i].screenshot({
          path: path.join(OUT, file),
          omitBackground: !!c.transparent,
        });
      }
    }

    const boxes = {};
    for (const b of job.boxes) {
      const v = await bbox(page, b.sel, b.all);
      if (v == null) console.warn(`  ! no match for box ${b.key} (${b.sel})`);
      else boxes[b.key] = v;
    }
    layout.pages[job.name] = { pageH: VIEWPORT.height, boxes };

    console.log(`captured ${job.name}`);
  }

  fs.writeFileSync(LAYOUT_JSON, JSON.stringify(layout, null, 2) + '\n');
  console.log(`\nlayout -> ${path.relative(ROOT, LAYOUT_JSON)}`);
  console.log(`textures -> ${path.relative(ROOT, OUT)}`);

  await browser.close();
}

run().catch((e) => {
  console.error(e);
  process.exit(1);
});
