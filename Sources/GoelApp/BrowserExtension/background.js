const HOST = 'com.goeldownloader.host';
const api = typeof chrome !== 'undefined' ? chrome : browser;

const BLUE = '#2f6fed';
const AMBER = '#b9770e';
const RED = '#c0392b';

// Safari has neither `downloads` nor a native channel that can carry a credential, so one probe covers both.
const canInterceptDownloads = !!(api.downloads && api.downloads.onCreated);
const canForwardCookies = canInterceptDownloads;
// Safari's stand-in for capture: a content script that catches download clicks (see capture.js).
const canCaptureClicks = !canInterceptDownloads &&
  !!(api.scripting && api.scripting.registerContentScripts);
const canCapture = canInterceptDownloads || canCaptureClicks;
const CLICK_CAPTURE_ID = 'goel-click-capture';
const CLICK_CAPTURE_FILES = ['capture-rules.js', 'capture.js'];

// Listed before this file under `background.scripts`; a service worker has to pull it in itself.
if (typeof GoelCaptureRules === 'undefined' && typeof importScripts === 'function') {
  try {
    importScripts('capture-rules.js');
  } catch (e) {
    // Without the rules a probe answers "not a download", so clicks still go through.
  }
}

const DEFAULT_TITLE = canCapture
  ? 'Goel\u00b0 \u2014 click to toggle download capture'
  : 'Goel\u00b0 \u2014 right-click a link and choose \u201cDownload with Goel\u00b0\u201d';

let captureEnabled = false;
let cookiesEnabled = false;

function updateBadge() {
  api.action.setBadgeText({ text: captureEnabled ? 'ON' : '' });
  if (captureEnabled) {
    api.action.setBadgeBackgroundColor({ color: BLUE });
  }
}

// Listeners register synchronously but stored state loads async; queue events or they run on stale state.
let stateReady = false;
const pendingUntilReady = [];

function whenReady(run) {
  if (stateReady) return run();
  pendingUntilReady.push(run);
}

api.storage.local.get({ capture: false, cookies: false }, (state) => {
  captureEnabled = canCapture && !!state.capture;
  cookiesEnabled = canForwardCookies && !!state.cookies;
  // Badge and tooltip live in the browser and outlive this worker, so a stale hint must be cleared here.
  clearHint();
  syncCookieMenu();
  syncClickCapture();
  stateReady = true;
  while (pendingUntilReady.length) pendingUntilReady.shift()();
});

api.action.onClicked.addListener(() => {
  if (!canCapture) {
    hint('!', AMBER, 'this browser can\u2019t hand over its downloads. Right-click a link \u2192 \u201cDownload with Goel\u00b0\u201d.');
    return;
  }
  if (canCaptureClicks && !captureEnabled) {
    // Only a click like this one may raise the site-access prompt the content script needs.
    api.permissions.request({ origins: ['<all_urls>'] }, (granted) => {
      if (!granted || api.runtime.lastError) {
        hint('!', AMBER, 'capture needs access to websites. Allow it, then click again.');
        return;
      }
      setCapture(true);
    });
    return;
  }
  setCapture(!captureEnabled);
});

function setCapture(next) {
  captureEnabled = next;
  api.storage.local.set({ capture: captureEnabled });
  syncClickCapture();
  // clearHint, not updateBadge: updateBadge leaves the old hint's tooltip contradicting the badge.
  clearHint();
}

// Registered only while capture is on, so a page never pays for a listener that would do nothing.
// Chained: the startup sync and a quick toggle would otherwise both register the same id.
let clickCaptureSync = Promise.resolve();
function syncClickCapture() {
  if (!canCaptureClicks) return;
  clickCaptureSync = clickCaptureSync.then(applyClickCapture);
}

async function applyClickCapture() {
  try {
    const existing = await api.scripting.getRegisteredContentScripts({ ids: [CLICK_CAPTURE_ID] });
    const registered = Array.isArray(existing) && existing.length > 0;
    if (captureEnabled && !registered) {
      await api.scripting.registerContentScripts([{
        id: CLICK_CAPTURE_ID,
        js: CLICK_CAPTURE_FILES,
        matches: ['<all_urls>'],
        allFrames: true,
        runAt: 'document_start',
        persistAcrossSessions: true,
      }]);
      injectIntoOpenTabs();
    } else if (!captureEnabled && registered) {
      await api.scripting.unregisterContentScripts({ ids: [CLICK_CAPTURE_ID] });
    }
  } catch (e) {
    console.warn('Goel\u00b0 click capture:', e && e.message);
    hint('!', RED, 'couldn\u2019t switch capture in this browser. Right-click links instead.');
  }
}

// A registered script only reaches pages loaded from now on; tabs already open get it here.
async function injectIntoOpenTabs() {
  let tabs = [];
  try {
    tabs = await api.tabs.query({});
  } catch (e) {
    return;
  }
  for (const tab of tabs) {
    if (!tab.id || (tab.url && !/^https?:/i.test(tab.url))) continue;
    api.scripting.executeScript({ target: { tabId: tab.id, allFrames: true }, files: CLICK_CAPTURE_FILES })
      .catch(() => {});
  }
}

function isSendable(url) {
  // Scheme allowlist: a page must not use this to make the app open e.g. an `sftp:` connection.
  return !!url && /^(https?:|magnet:)/i.test(url);
}

const PROBE_MS = 4000;

// Asks the server what a link really is, following redirects, before the browser commits to it.
async function probe(url) {
  if (typeof GoelCaptureRules === 'undefined') return { download: false };
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), PROBE_MS);
  const options = { redirect: 'follow', credentials: 'include', signal: controller.signal };
  try {
    let response = await fetch(url, { ...options, method: 'HEAD' });
    // Some servers refuse HEAD; a one-byte GET answers the same question.
    if (response.status === 405 || response.status === 501) {
      response = await fetch(url, { ...options, headers: { Range: 'bytes=0-0' } });
      if (response.body) response.body.cancel().catch(() => {});
    }
    const download = response.ok && GoelCaptureRules.isDownloadResponse(
      response.headers.get('content-type'), response.headers.get('content-disposition'));
    return { download, finalUrl: response.url || url };
  } catch (e) {
    return { download: false };
  } finally {
    clearTimeout(timer);
  }
}

api.runtime.onMessage.addListener((message, sender, reply) => {
  if (!canCaptureClicks || !message || !sender || !sender.tab) return;
  // whenReady: this message is often what woke the worker, before `captureEnabled` has loaded.
  if (message.type === 'goel-capture') {
    whenReady(() => {
      if (captureEnabled && isSendable(message.url)) sendToApp(message.url, message.referrer, '');
    });
    return;
  }
  if (message.type !== 'goel-probe' || !isSendable(message.url)) return;
  whenReady(() => {
    probe(message.url).then((result) => {
      if (captureEnabled && result.download) {
        sendToApp(result.finalUrl, message.referrer, '');
        reply({ handled: true });
      } else if (message.newTab) {
        api.tabs.create({ url: message.url, index: sender.tab.index + 1, openerTabId: sender.tab.id });
        reply({ handled: true });
      } else {
        reply({ handled: false });
      }
    });
  });
  // Keeps `reply` alive until the probe settles.
  return true;
});

api.runtime.onInstalled.addListener(() => {
  api.contextMenus.create({
    id: 'goel-send',
    title: 'Download with Goel\u00b0',
    contexts: ['link', 'image', 'video', 'audio'],
  });
  if (!canInterceptDownloads) {
    // The native host's spool can't open the Add sheet, so this is the scheme browsers' item only.
    api.contextMenus.create({
      id: 'goel-send-page',
      title: 'Download video from this page with Goel\u00b0',
      contexts: ['page', 'video', 'audio'],
    });
  }
  if (canForwardCookies) {
    api.contextMenus.create({
      id: 'goel-send-signed-in',
      title: 'Download with Goel\u00b0 (stay signed in)',
      contexts: ['link', 'image', 'video', 'audio'],
    });
    api.contextMenus.create({
      id: 'goel-cookies',
      title: 'Send login cookies with captured downloads',
      type: 'checkbox',
      checked: false,
      contexts: ['action'],
    });
  }
  api.action.setTitle({ title: DEFAULT_TITLE });
  updateBadge();
  syncCookieMenu();
});

function syncCookieMenu() {
  if (!canForwardCookies) return;
  api.contextMenus.update('goel-cookies', { checked: cookiesEnabled }, () => {
    void api.runtime.lastError;
  });
}

api.contextMenus.onClicked.addListener((info) => {
  if (info.menuItemId === 'goel-cookies') {
    setCookiesEnabled(!!info.checked);
    return;
  }
  if (info.menuItemId === 'goel-send-page') {
    if (isSendable(info.pageUrl)) sendToApp(info.pageUrl, info.pageUrl, '', null, 'page');
    return;
  }
  const url = info.linkUrl || info.srcUrl;
  if (!isSendable(url)) {
    // A player fed from a blob: or MediaSource URL: the page is what yt-dlp can work with.
    if (!canInterceptDownloads && (info.mediaType === 'video' || info.mediaType === 'audio') &&
        isSendable(info.pageUrl)) {
      sendToApp(info.pageUrl, info.pageUrl, '', null, 'page');
    }
    return;
  }
  const wantsCookies = info.menuItemId === 'goel-send-signed-in';
  if (wantsCookies) {
    // Only a user gesture like this click may raise a permission prompt; asking elsewhere is denied.
    requestCookieAccess(url, (granted) => {
      if (granted) return sendWithCookies(url, info.pageUrl);
      sendToApp(url, info.pageUrl, '', 'cookie access wasn\u2019t granted, so this was sent without your login.');
    });
  } else {
    sendToApp(url, info.pageUrl, '');
  }
});

function setCookiesEnabled(next) {
  if (!next) {
    cookiesEnabled = false;
    api.storage.local.set({ cookies: false });
    syncCookieMenu();
    return;
  }
  api.permissions.request(
    { permissions: ['cookies'], origins: ['<all_urls>'] },
    (granted) => {
      cookiesEnabled = !!granted && !api.runtime.lastError;
      api.storage.local.set({ cookies: cookiesEnabled });
      syncCookieMenu();
    }
  );
}

function requestCookieAccess(url, done) {
  const ask = { permissions: ['cookies'], origins: [originPattern(url)] };
  api.permissions.contains(ask, (has) => {
    if (has && !api.runtime.lastError) return done(true);
    api.permissions.request(ask, (granted) => done(!!granted && !api.runtime.lastError));
  });
}

function originPattern(url) {
  try {
    return new URL(url).origin + '/*';
  } catch (e) {
    return '<all_urls>';
  }
}

// `getAll({url})` honours Secure/SameSite/path and yields HttpOnly cookies page script cannot read.
function cookieHeaderFor(url, done) {
  if (!api.cookies || !api.cookies.getAll) return done('');
  let settled = false;
  const finish = (value) => {
    if (settled) return;
    settled = true;
    done(value);
  };
  // Never let a slow/absent cookie store stall the download hand-off.
  setTimeout(() => finish(''), 1500);
  try {
    api.cookies.getAll({ url }, (list) => {
      if (api.runtime.lastError || !Array.isArray(list)) return finish('');
      finish(
        list
          .filter((c) => c && c.name)
          .map((c) => `${c.name}=${c.value}`)
          .join('; ')
      );
    });
  } catch (e) {
    finish('');
  }
}

function sendWithCookies(url, referrer) {
  cookieHeaderFor(url, (cookie) => sendToApp(url, referrer, cookie));
}

const PROBLEM_MS = 10000;
const SUCCESS_MS = 2500;

let hintTimer = null;

function hint(badge, color, title, ms) {
  if (hintTimer) clearTimeout(hintTimer);
  api.action.setBadgeText({ text: badge });
  api.action.setBadgeBackgroundColor({ color });
  api.action.setTitle({ title: 'Goel\u00b0 \u2014 ' + title });
  hintTimer = setTimeout(clearHint, ms || PROBLEM_MS);
}

function clearHint() {
  if (hintTimer) clearTimeout(hintTimer);
  hintTimer = null;
  api.action.setTitle({ title: DEFAULT_TITLE });
  updateBadge();
}

function sendToApp(url, referrer, cookie, caveat, kind) {
  const message = { url, referrer: referrer || '' };
  if (cookie) message.cookie = cookie;
  // `page`: a video page for the Add sheet's yt-dlp, not a file to fetch as-is.
  if (kind) message.kind = kind;
  // Needed to tell the reply's `cookies: false` apart from "we never sent one".
  const sentCookie = !!cookie;
  api.runtime.sendNativeMessage(HOST, message, (response) => {
    if (api.runtime.lastError) {
      // Log the reason only: `message` holds a session cookie and this console is readable.
      console.warn('Goel\u00b0 host unreachable:', api.runtime.lastError.message);
      hint('!', RED, 'can\u2019t reach the app. Open Goel\u00b0 \u25b8 Settings \u25b8 Browser and click Install Helper.');
      return;
    }
    // `queued`: the capture is safely spooled but the app couldn't be woken; it drains on the next
    // launch. That's a delivered link, not a refused one.
    if (response && response.ok !== true && response.queued === true) {
      hint('\u2713', BLUE, 'queued \u2014 it will be added when Goel\u00b0 next opens.', SUCCESS_MS);
      return;
    }
    if (!response || response.ok !== true) {
      // Never echo `response.error` into the tooltip: it is host-controlled text.
      hint('!', RED, 'the app couldn\u2019t accept that link \u2014 it isn\u2019t a supported download URL.');
      return;
    }
    if (sentCookie && response.cookies === false) {
      hint('!', AMBER, 'the app dropped your login and downloaded this signed out.');
      return;
    }
    if (caveat) {
      hint('!', AMBER, caveat);
      return;
    }
    hint('\u2713', BLUE, 'sent to the app.', SUCCESS_MS);
  });
}

// Cancel the browser's copy first or the file lands twice; Safari lacks `downloads`, so keep the guard.
if (api.downloads && api.downloads.onCreated) {
  api.downloads.onCreated.addListener((item) => {
    // whenReady: this event is itself a common reason the worker woke, so state may not be loaded.
    whenReady(() => {
      if (!captureEnabled) return;
      const url = item.finalUrl || item.url;
      if (!/^https?:/i.test(url)) return;
      api.downloads.cancel(item.id, () => {
        if (api.runtime.lastError) return;
        api.downloads.erase({ id: item.id });
        // Re-check the grant every time: cookie permission can be revoked after it was stored.
        if (!cookiesEnabled) return sendToApp(url, item.referrer, '');
        api.permissions.contains(
          { permissions: ['cookies'], origins: [originPattern(url)] },
          (has) => {
            if (has && !api.runtime.lastError) sendWithCookies(url, item.referrer);
            else sendToApp(url, item.referrer, '',
                           'cookie access for this site was revoked, so it was sent signed out.');
          }
        );
      });
    });
  });
}
