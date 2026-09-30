// Run: node --test Tests/BrowserExtension
// Pins the click-capture decisions Safari relies on (it has no downloads API to fall back on).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../../Sources/GoelApp/BrowserExtension/capture-rules.js', import.meta.url), 'utf8');
const sandbox = {};
vm.runInNewContext(source, { globalThis: sandbox, self: sandbox, URL });
const rules = sandbox.GoelCaptureRules;

const page = 'https://site.test/articles/1';

test('every extension script is plain ASCII, so Safari cannot decode it as mojibake', () => {
  for (const name of ['capture-rules.js', 'capture.js', 'background.js']) {
    const text = readFileSync(new URL(`../../Sources/GoelApp/BrowserExtension/${name}`, import.meta.url), 'utf8');
    assert.ok(/^[\x00-\x7f]*$/.test(text), `${name} has non-ASCII characters; write them as \\u escapes`);
  }
});

test('a link to a file is captured without asking the server', () => {
  for (const href of ['https://cdn.test/a.zip', 'https://cdn.test/x/Movie.2026.1080p.MKV',
                      'https://cdn.test/setup.dmg?token=abc', 'https://cdn.test/show.torrent']) {
    assert.equal(rules.isFileLink(new URL(href)), true, href);
  }
});

test('an ordinary page link is not a file link', () => {
  for (const href of ['https://site.test/', 'https://site.test/about.html', 'https://site.test/blog/zip-files',
                      'https://site.test/page.php?file=a.zip',
                      // Source-code links on GitHub and docs sites, not media or disk images.
                      'https://github.test/app/src/index.ts', 'https://site.test/lib/app.jar/docs']) {
    assert.equal(rules.isFileLink(new URL(href)), false, href);
  }
});

test('links that may redirect into a file are probed', () => {
  for (const href of ['https://site.test/download/123', 'https://site.test/dl?id=9',
                      'https://site.test/attachment/7', 'https://other.test/anything']) {
    assert.equal(rules.isWorthProbing(new URL(href), new URL(page)), true, href);
  }
});

test('same-page and plain same-site links are left to the browser', () => {
  for (const href of ['https://site.test/articles/1#comments', 'https://site.test/articles/2',
                      'https://site.test/about', 'https://www.site.test/news',
                      // App routes that merely share a word with download links keep their router.
                      'https://site.test/files/', 'https://site.test/go/settings', 'https://site.test/get-started']) {
    assert.equal(rules.isWorthProbing(new URL(href), new URL(page)), false, href);
  }
});

test('an attachment is a download whatever its type', () => {
  assert.equal(rules.isDownloadResponse('text/html', 'attachment; filename="a.html"'), true);
  assert.equal(rules.isDownloadResponse('', 'ATTACHMENT'), true);
});

test('binary, archive and media responses are downloads', () => {
  for (const type of ['application/octet-stream', 'application/zip', 'application/x-apple-diskimage',
                      'video/mp4', 'audio/mpeg; charset=binary', 'application/vnd.apple.mpegurl']) {
    assert.equal(rules.isDownloadResponse(type, ''), true, type);
  }
});

test('pages, images and documents Safari shows inline stay in Safari', () => {
  for (const type of ['text/html; charset=utf-8', 'text/plain', 'image/png', 'application/pdf',
                      'application/json', 'application/xhtml+xml', 'application/xml', '']) {
    assert.equal(rules.isDownloadResponse(type, ''), false, type);
  }
  assert.equal(rules.isDownloadResponse('application/pdf', 'inline; filename="a.pdf"'), false);
});
