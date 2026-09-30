// Click capture for browsers with no downloads API (Safari): catches a download click before the
// browser starts it. Registered by background.js only while capture is on. ASCII only (see capture-rules.js).
(function () {
  if (window.__goelClickCapture) return;
  window.__goelClickCapture = true;

  const api = typeof chrome !== 'undefined' ? chrome : browser;
  const rules = globalThis.GoelCaptureRules;
  // Mirrors the toolbar toggle: a script injected earlier must go quiet the moment capture is off.
  let enabled = false;
  api.storage.local.get({ capture: false }, (state) => { enabled = !!(state && state.capture); });
  api.storage.onChanged.addListener((changes, area) => {
    if (area === 'local' && changes.capture) enabled = !!changes.capture.newValue;
  });

  function anchorOf(event) {
    const path = event.composedPath ? event.composedPath() : [];
    for (const node of path) {
      if (node && node.tagName === 'A' && node.href) return node;
    }
    return null;
  }

  function claim(event) {
    event.preventDefault();
    event.stopImmediatePropagation();
  }

  // `anchor.target` honours <base target>. A new tab needs the background: an async window.open
  // is popup-blocked. `_top`/`_parent` stay in this tab, in the frame the link names.
  function destination(anchor) {
    const target = (anchor.target || '').toLowerCase();
    if (target === '' || target === '_self') return { frame: window };
    if (target === '_top') return { frame: window.top };
    if (target === '_parent') return { frame: window.parent };
    return { newTab: true };
  }

  function follow(url, where) {
    try {
      where.frame.location.assign(url);
    } catch (e) {
      location.assign(url);
    }
  }

  // Throws "Extension context invalidated" once the extension reloads under an open page.
  function send(message, onReply) {
    try {
      api.runtime.sendMessage(message, onReply);
      return true;
    } catch (e) {
      return false;
    }
  }

  window.addEventListener('click', (event) => {
    // isTrusted: a page's own a.click() must not become a gesture-free channel to the app.
    if (!event.isTrusted || !enabled || !rules || event.defaultPrevented) return;
    // Modifier and middle clicks mean "open this in a tab", not "download it".
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    const anchor = anchorOf(event);
    if (!anchor) return;
    let url;
    try {
      url = new URL(anchor.href, location.href);
    } catch (e) {
      return;
    }
    const isFile = url.protocol === 'magnet:' ||
      ((url.protocol === 'http:' || url.protocol === 'https:') &&
       (anchor.hasAttribute('download') || rules.isFileLink(url)));
    if (isFile) {
      // Claimed only once the message is out; if it can't be sent the browser keeps the click.
      if (send({ type: 'goel-capture', url: url.href, referrer: location.href })) claim(event);
      return;
    }
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return;
    if (!rules.isWorthProbing(url, new URL(location.href))) return;
    const where = destination(anchor);
    const sent = send(
      { type: 'goel-probe', url: url.href, referrer: location.href, newTab: !!where.newTab },
      (reply) => {
        // The background already sent a download to Goel, or opened the new tab itself.
        if (reply && reply.handled) return;
        // No usable answer: never swallow the click, just follow the link.
        follow(url.href, where.newTab ? { frame: window } : where);
      }
    );
    if (sent) claim(event);
  }, true);
})();
