// Goel° Capture — background worker.
//
// Two paths into the app, both via the native-messaging host that the
// GoelDownloader settings pane installs:
//  - the toolbar toggle intercepts every new browser download while ON,
//  - the context menu sends a single link/media URL regardless of the toggle.
//
// Both paths can additionally forward the browser's `Cookie` header for the URL,
// which is what makes downloads behind a login work — paywalled files, private
// forums, university portals. That is OFF by default and gated behind an
// *optional* permission the user grants explicitly (see `requestCookieAccess`):
// "read your cookies" is the scariest string in the install dialog, and nobody
// should have to accept it to download a public file.
//
// The `chrome` namespace also exists in Firefox (with callback support), so
// one callback-style codebase covers Chrome/Edge/Brave/Firefox.

const HOST = 'com.goeldownloader.host';
const api = typeof chrome !== 'undefined' ? chrome : browser;

const BLUE = '#2f6fed';
const AMBER = '#b9770e';
const RED = '#c0392b';

// Safari implements neither the `downloads` API (so there is nothing to
// intercept) nor a native channel that can carry a credential — its handler
// refuses cookies by design, because its only route to the app is a URL that
// LaunchServices records. Both of this extension's Chromium/Firefox-only
// affordances are therefore missing in exactly the same browser, and
// `downloads` is the feature-detectable one, so it stands in for both. Detect
// rather than assume: a toolbar badge reading ON while nothing is captured, or
// a "stay signed in" menu item that can never stay signed in, is worse than
// not offering either.
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

// Service workers restart often, so state lives in storage — but it arrives
// ASYNCHRONOUSLY while listeners must be registered synchronously. An event that
// woke the worker can therefore run before the state does, seeing capture off when
// the user had it on and silently letting the download through. Queue until known.
let stateReady = false;
const pendingUntilReady = [];

function whenReady(run) {
  if (stateReady) return run();
  pendingUntilReady.push(run);
}

api.storage.local.get({ capture: false, cookies: false }, (state) => {
  captureEnabled = canInterceptDownloads && !!state.capture;
  cookiesEnabled = canForwardCookies && !!state.cookies;
  // The BROWSER owns the badge and tooltip, not this worker's heap: they outlive a
  // restart, so a stale hint has to be cleared here rather than assumed gone.
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
  // clearHint, not updateBadge: the latter leaves an old hint's tooltip in place, so
  // the badge would read ON while the hover text still said "can't reach the app".
  clearHint();
});

api.runtime.onInstalled.addListener(() => {
  api.contextMenus.create({
    id: 'goel-send',
    title: 'Download with Goel°',
    contexts: ['link', 'image', 'video', 'audio'],
  });
  // Both cookie affordances are omitted where the native side cannot carry a
  // credential: an item promising to keep you signed in, which then always
  // reports that it couldn't, is worse than no item at all.
  if (canForwardCookies) {
    api.contextMenus.create({
      id: 'goel-send-signed-in',
      title: 'Download with Goel° (stay signed in)',
      contexts: ['link', 'image', 'video', 'audio'],
    });
    // Lives on the toolbar icon's own menu: it is a preference, not an action on
    // the page under the cursor.
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
    // The menu may not exist yet on a fresh worker start; harmless.
    void api.runtime.lastError;
  });
}

api.contextMenus.onClicked.addListener((info) => {
  if (info.menuItemId === 'goel-cookies') {
    setCookiesEnabled(!!info.checked);
    return;
  }
  const url = info.linkUrl || info.srcUrl;
  // Only hand the app web-capture schemes. The native host enforces this too,
  // but filtering here avoids handing it (e.g.) an `sftp:` link a page could
  // use to provoke an authenticated outbound connection.
  if (!url || !/^(https?:|magnet:)/i.test(url)) return;
  const wantsCookies = info.menuItemId === 'goel-send-signed-in';
  if (wantsCookies) {
    // A context-menu click is a user gesture, so the permission prompt is
    // allowed here — this is the only place we ever ask for it.
    requestCookieAccess(url, (granted) => {
      if (granted) return sendWithCookies(url, info.pageUrl);
      // Declining the prompt still sends the link — losing the download would be
      // worse — but the user asked to stay signed in, so a plain ✓ here would be a
      // success message for something that did not happen.
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
  // Ask for the permission at the moment it is turned on, not at install.
  api.permissions.request(
    { permissions: ['cookies'], origins: ['<all_urls>'] },
    (granted) => {
      cookiesEnabled = !!granted && !api.runtime.lastError;
      api.storage.local.set({ cookies: cookiesEnabled });
      syncCookieMenu();
    }
  );
}

// MARK: Cookies

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

// The cookies the browser itself would attach to a request for `url`.
//
// `cookies.getAll({url})` is the right call rather than reading
// `document.cookie`: it honours the Secure/SameSite/path rules for this exact
// URL, and it returns HttpOnly cookies — which page script cannot see and which
// are precisely the session cookies a login depends on.
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

// MARK: Telling the user what happened
//
// A hand-off is invisible: the app may be closed, hidden, or on another Space,
// so a successful capture changes nothing on screen — and a *failed* one used to
// change nothing either, which is indistinguishable from a broken extension.
// The overwhelmingly common failure is the native-messaging helper not being
// installed yet (Goel° ▸ Settings ▸ Browser ▸ Install Helper), and the user has
// no way to guess that from silence.
//
// The toolbar button is the only surface an extension owns without asking for
// `notifications` — a permission nobody should have to grant to learn that a
// download did not start — so outcomes are pushed onto its badge and tooltip.

// How long an outcome stays on the badge. Problems linger; a success tick gets
// out of the way quickly so it doesn't mask the capture-mode ON badge.
//
// The timer is BEST-EFFORT: an MV3 worker can be terminated while idle and a
// pending setTimeout dies with it, so a hint can outlive its window. `chrome.alarms`
// is no use at these durations (Chrome clamps one-shot alarms to ~30s), so the
// guarantee comes from the other end instead — every worker start calls clearHint,
// which is why that call is in the storage handler above.
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

// MARK: Hand-off

// `caveat`, when given, replaces the success tick with an amber warning: the
// hand-off worked but not the way the user asked for it.
function sendToApp(url, referrer, cookie, caveat) {
  const message = { url, referrer: referrer || '' };
  if (cookie) message.cookie = cookie;
  // Whether *we* tried to send a credential, so the reply's `cookies: false`
  // can be told apart from "we never asked for cookies in the first place".
  const sentCookie = !!cookie;
  api.runtime.sendNativeMessage(HOST, message, (response) => {
    if (api.runtime.lastError) {
      // Host not installed, or its manifest points at an app that has since
      // moved. Log the reason only — `message` holds a session cookie, and the
      // service worker console is readable by anyone with the machine.
      console.warn('Goel° host unreachable:', api.runtime.lastError.message);
      hint('!', RED, 'can’t reach the app. Open Goel° ▸ Settings ▸ Browser and click Install Helper.');
      return;
    }
    if (!response || response.ok !== true) {
      // The host refuses anything outside its capture allowlist — non-web
      // schemes, and loopback or link-local targets a page must not be able to
      // point the app at. Never echo `response.error` into the tooltip: it is
      // host-controlled text, and the reasons are few enough to phrase here.
      hint('!', RED, 'the app couldn’t accept that link — it isn’t a supported download URL.');
      return;
    }
    if (sentCookie && response.cookies === false) {
      // The app took the link but dropped the credential — the cookie header failed
      // its sanitisation, or this is a build whose native side never carries one.
      // Say so: otherwise a signed-in download quietly returns a login page and the
      // user blames the download rather than the hand-off.
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

// Capture mode: take over new downloads. Cancel the browser's copy first so
// nothing lands twice, then hand the URL to the app.
//
// Safari doesn't implement the `downloads` API, so this whole path is absent
// there — the context menu still works. Guard it so the worker doesn't throw.
if (api.downloads && api.downloads.onCreated) {
  api.downloads.onCreated.addListener((item) => {
    // whenReady, because this event is itself a common reason the worker woke up.
    whenReady(() => {
      if (!captureEnabled) return;
      const url = item.finalUrl || item.url;
      if (!/^https?:/i.test(url)) return;
      api.downloads.cancel(item.id, () => {
        if (api.runtime.lastError) return; // finished/cancelled already — leave it
        api.downloads.erase({ id: item.id });
        // A captured download is almost always the one that needs cookies (the
        // browser was signed in when it started it), but only forward them if the
        // user turned the preference on and the grant is still in place — a
        // permission can be revoked from the browser's own settings at any time.
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
