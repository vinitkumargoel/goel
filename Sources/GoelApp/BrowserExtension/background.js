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
// *optional* permission the user grants explicitly (see `ensureCookieAccess`):
// "read your cookies" is the scariest string in the install dialog, and nobody
// should have to accept it to download a public file.
//
// The `chrome` namespace also exists in Firefox (with callback support), so
// one callback-style codebase covers Chrome/Edge/Brave/Firefox.

const HOST = 'com.goeldownloader.host';
const api = typeof chrome !== 'undefined' ? chrome : browser;

let captureEnabled = false;
let cookiesEnabled = false;

function updateBadge() {
  api.action.setBadgeText({ text: captureEnabled ? 'ON' : '' });
  if (captureEnabled) {
    api.action.setBadgeBackgroundColor({ color: '#2f6fed' });
  }
}

// Service workers restart often; state lives in storage.
api.storage.local.get({ capture: false, cookies: false }, (state) => {
  captureEnabled = !!state.capture;
  cookiesEnabled = !!state.cookies;
  updateBadge();
  syncCookieMenu();
});

api.action.onClicked.addListener(() => {
  captureEnabled = !captureEnabled;
  api.storage.local.set({ capture: captureEnabled });
  updateBadge();
});

api.runtime.onInstalled.addListener(() => {
  api.contextMenus.create({
    id: 'goel-send',
    title: 'Download with Goel°',
    contexts: ['link', 'image', 'video', 'audio'],
  });
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
  updateBadge();
  syncCookieMenu();
});

function syncCookieMenu() {
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
      if (granted) sendWithCookies(url, info.pageUrl);
      else sendToApp(url, info.pageUrl, '');
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

// MARK: Hand-off

function sendToApp(url, referrer, cookie) {
  const message = { url, referrer: referrer || '' };
  if (cookie) message.cookie = cookie;
  api.runtime.sendNativeMessage(HOST, message, () => {
    if (api.runtime.lastError) {
      // Host not installed (Settings → Browser Integration → Install Helper).
      // Log the reason only — `message` holds a session cookie, and the service
      // worker console is readable by anyone with the machine.
      console.warn('Goel° host unreachable:', api.runtime.lastError.message);
    }
  });
}

// Capture mode: take over new downloads. Cancel the browser's copy first so
// nothing lands twice, then hand the URL to the app.
//
// Safari doesn't implement the `downloads` API, so this whole path is absent
// there — the context menu still works. Guard it so the worker doesn't throw.
if (api.downloads && api.downloads.onCreated) {
  api.downloads.onCreated.addListener((item) => {
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
          else sendToApp(url, item.referrer, '');
        }
      );
    });
  });
}
