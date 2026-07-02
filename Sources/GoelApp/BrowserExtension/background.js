// GoelDownloader Capture — background worker.
//
// Two paths into the app, both via the native-messaging host that the
// GoelDownloader settings pane installs:
//  - the toolbar toggle intercepts every new browser download while ON,
//  - the context menu sends a single link/media URL regardless of the toggle.
//
// The `chrome` namespace also exists in Firefox (with callback support), so
// one callback-style codebase covers Chrome/Edge/Brave/Firefox.

const HOST = 'com.goeldownloader.host';
const api = typeof chrome !== 'undefined' ? chrome : browser;

let captureEnabled = false;

function updateBadge() {
  api.action.setBadgeText({ text: captureEnabled ? 'ON' : '' });
  if (captureEnabled) {
    api.action.setBadgeBackgroundColor({ color: '#2f6fed' });
  }
}

// Service workers restart often; state lives in storage.
api.storage.local.get({ capture: false }, (state) => {
  captureEnabled = !!state.capture;
  updateBadge();
});

api.action.onClicked.addListener(() => {
  captureEnabled = !captureEnabled;
  api.storage.local.set({ capture: captureEnabled });
  updateBadge();
});

api.runtime.onInstalled.addListener(() => {
  api.contextMenus.create({
    id: 'goel-send',
    title: 'Download with GoelDownloader',
    contexts: ['link', 'image', 'video', 'audio'],
  });
  updateBadge();
});

api.contextMenus.onClicked.addListener((info) => {
  const url = info.linkUrl || info.srcUrl;
  if (url) sendToApp(url, info.pageUrl);
});

function sendToApp(url, referrer) {
  api.runtime.sendNativeMessage(HOST, { url, referrer: referrer || '' }, () => {
    if (api.runtime.lastError) {
      // Host not installed (Settings → Browser Integration → Install Helper).
      console.warn('GoelDownloader host unreachable:', api.runtime.lastError.message);
    }
  });
}

// Capture mode: take over new downloads. Cancel the browser's copy first so
// nothing lands twice, then hand the URL to the app.
api.downloads.onCreated.addListener((item) => {
  if (!captureEnabled) return;
  const url = item.finalUrl || item.url;
  if (!/^https?:/i.test(url)) return;
  api.downloads.cancel(item.id, () => {
    if (api.runtime.lastError) return; // finished/cancelled already — leave it
    api.downloads.erase({ id: item.id });
    sendToApp(url, item.referrer);
  });
});
