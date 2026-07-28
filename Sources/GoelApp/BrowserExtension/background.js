const HOST = 'com.goeldownloader.host';
const api = typeof chrome !== 'undefined' ? chrome : browser;

const BLUE = '#2f6fed';
const AMBER = '#b9770e';
const RED = '#c0392b';

// Safari has neither `downloads` nor a native channel that can carry a credential, so one probe covers both.
const canInterceptDownloads = !!(api.downloads && api.downloads.onCreated);
const canForwardCookies = canInterceptDownloads;

const DEFAULT_TITLE = canInterceptDownloads
  ? 'Goel° — click to toggle download capture'
  : 'Goel° — right-click a link and choose “Download with Goel°”';

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
  captureEnabled = canInterceptDownloads && !!state.capture;
  cookiesEnabled = canForwardCookies && !!state.cookies;
  // Badge and tooltip live in the browser and outlive this worker, so a stale hint must be cleared here.
  clearHint();
  syncCookieMenu();
  stateReady = true;
  while (pendingUntilReady.length) pendingUntilReady.shift()();
});

api.action.onClicked.addListener(() => {
  if (!canInterceptDownloads) {
    hint('!', AMBER, 'this browser can’t hand over its downloads. Right-click a link → “Download with Goel°”.');
    return;
  }
  captureEnabled = !captureEnabled;
  api.storage.local.set({ capture: captureEnabled });
  // clearHint, not updateBadge: updateBadge leaves the old hint's tooltip contradicting the badge.
  clearHint();
});

api.runtime.onInstalled.addListener(() => {
  api.contextMenus.create({
    id: 'goel-send',
    title: 'Download with Goel°',
    contexts: ['link', 'image', 'video', 'audio'],
  });
  if (canForwardCookies) {
    api.contextMenus.create({
      id: 'goel-send-signed-in',
      title: 'Download with Goel° (stay signed in)',
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
  const url = info.linkUrl || info.srcUrl;
  // Scheme allowlist: a page must not use this to make the app open e.g. an `sftp:` connection.
  if (!url || !/^(https?:|magnet:)/i.test(url)) return;
  const wantsCookies = info.menuItemId === 'goel-send-signed-in';
  if (wantsCookies) {
    // Only a user gesture like this click may raise a permission prompt; asking elsewhere is denied.
    requestCookieAccess(url, (granted) => {
      if (granted) return sendWithCookies(url, info.pageUrl);
      sendToApp(url, info.pageUrl, '', 'cookie access wasn’t granted, so this was sent without your login.');
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
  api.action.setTitle({ title: 'Goel° — ' + title });
  hintTimer = setTimeout(clearHint, ms || PROBLEM_MS);
}

function clearHint() {
  if (hintTimer) clearTimeout(hintTimer);
  hintTimer = null;
  api.action.setTitle({ title: DEFAULT_TITLE });
  updateBadge();
}

function sendToApp(url, referrer, cookie, caveat) {
  const message = { url, referrer: referrer || '' };
  if (cookie) message.cookie = cookie;
  // Needed to tell the reply's `cookies: false` apart from "we never sent one".
  const sentCookie = !!cookie;
  api.runtime.sendNativeMessage(HOST, message, (response) => {
    if (api.runtime.lastError) {
      // Log the reason only: `message` holds a session cookie and this console is readable.
      console.warn('Goel° host unreachable:', api.runtime.lastError.message);
      hint('!', RED, 'can’t reach the app. Open Goel° ▸ Settings ▸ Browser and click Install Helper.');
      return;
    }
    if (!response || response.ok !== true) {
      // Never echo `response.error` into the tooltip: it is host-controlled text.
      hint('!', RED, 'the app couldn’t accept that link — it isn’t a supported download URL.');
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
    hint('✓', BLUE, 'sent to the app.', SUCCESS_MS);
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
