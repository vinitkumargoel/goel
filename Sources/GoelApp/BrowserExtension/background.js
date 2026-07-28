// Goel° Capture background worker: a toolbar toggle that intercepts new downloads and a
// context menu that sends one URL, both via the native-messaging host. Cookies are opt-in.

const HOST = 'com.goeldownloader.host';
const api = typeof chrome !== 'undefined' ? chrome : browser;

const BLUE = '#2f6fed';
const AMBER = '#b9770e';
const RED = '#c0392b';

// Safari implements neither the `downloads` API nor a native channel that can carry a
// credential, so `downloads` is feature-detected and stands in for both affordances.
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

// Service workers restart often, so state lives in storage — but it arrives asynchronously
// while listeners register synchronously. Queue events until the state is known.
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
  // Both cookie affordances are omitted where the native side cannot carry a credential: an
  // item promising to keep you signed in that always fails is worse than no item.
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
  // Only hand the app web-capture schemes. The native host enforces this too, but filtering
  // here avoids handing it an `sftp:` link a page could use to provoke an outbound connection.
  if (!url || !/^(https?:|magnet:)/i.test(url)) return;
  const wantsCookies = info.menuItemId === 'goel-send-signed-in';
  if (wantsCookies) {
    // A context-menu click is a user gesture, so the permission prompt is
    // allowed here — this is the only place we ever ask for it.
    requestCookieAccess(url, (granted) => {
      if (granted) return sendWithCookies(url, info.pageUrl);
      // Declining the prompt still sends the link — losing the download would be worse — but a
      // plain ✓ would report success for the sign-in the user asked for and didn't get.
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

// The cookies the browser itself would attach to a request for `url`. `cookies.getAll({url})`
// honours Secure/SameSite/path and returns HttpOnly cookies, which page script cannot see.
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

// Telling the user what happened: a hand-off is invisible, and the common failure is the
// helper not being installed. The toolbar badge is the only surface we own without a permission.

// How long an outcome stays on the badge; problems linger, successes clear fast. Best-effort:
// an MV3 worker can die with its setTimeout, so every worker start calls clearHint.
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
      // Host not installed, or its manifest points at an app that moved. Log the reason only —
      // `message` holds a session cookie and the worker console is readable by anyone here.
      console.warn('Goel° host unreachable:', api.runtime.lastError.message);
      hint('!', RED, 'can’t reach the app. Open Goel° ▸ Settings ▸ Browser and click Install Helper.');
      return;
    }
    if (!response || response.ok !== true) {
      // The host refuses anything outside its capture allowlist. Never echo `response.error` into
      // the tooltip: it is host-controlled text, and the reasons are few enough to phrase here.
      hint('!', RED, 'the app couldn’t accept that link — it isn’t a supported download URL.');
      return;
    }
    if (sentCookie && response.cookies === false) {
      // The app took the link but dropped the credential. Say so — otherwise a signed-in download
      // quietly returns a login page and the user blames the download, not the hand-off.
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

// Capture mode: cancel the browser's copy first so nothing lands twice, then hand the URL to
// the app. Safari has no `downloads` API, so guard it or the worker throws.
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
        // A captured download almost always needs cookies, but forward them only if the preference
        // is on and the grant still holds — a permission can be revoked at any time.
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
