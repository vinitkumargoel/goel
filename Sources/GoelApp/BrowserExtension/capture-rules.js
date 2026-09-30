// Click-capture rules for browsers with no downloads API (Safari). Shared by the content script
// and the background worker; kept pure so Tests/BrowserExtension can pin every decision.
// ASCII only: Safari decodes extension scripts as Latin-1, which turns any UTF-8 into mojibake.
(function (root) {
  const FILE_EXTENSIONS = [
    // No `ts`, `jar`, `bin` or `img`: those are as often source files or pages as downloads.
    'zip', 'rar', '7z', 'tar', 'gz', 'tgz', 'bz2', 'xz', 'zst', 'iso', 'dmg', 'pkg',
    'exe', 'msi', 'apk', 'ipa', 'deb', 'rpm', 'appimage', 'torrent',
    'mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm', 'm4v', 'mpg', 'mpeg', 'm3u8',
    'mp3', 'flac', 'wav', 'aac', 'm4a', 'ogg', 'opus',
  ];
  const FILE_EXT = new RegExp('\\.(' + FILE_EXTENSIONS.join('|') + ')$', 'i');

  // Same-site path words that front a redirect into a file ("/download/123", "?dl=1"). Kept narrow:
  // a probed click loses the page's own handler, so app routes like "/files/" must not match.
  const DOWNLOAD_WORDS = /(^|[\/_\-.?=&])(download|downloads|dl|attachment|attachments|export|mirror)([\/_\-.?=&]|$)/i;

  // Types a browser shows in the tab. Everything else it would save, so Goel should take it.
  const SHOWN_INLINE = /^(text\/|image\/|application\/(pdf|json|xml|xhtml\+xml|javascript|ecmascript|rss\+xml|atom\+xml)$)/i;

  function isFileLink(url) {
    return FILE_EXT.test(url.pathname);
  }

  // Naive registrable domain: good enough to tell "same site, leave it alone" from "somewhere else".
  function siteOf(host) {
    return host.split('.').slice(-2).join('.');
  }

  // Probing costs a round trip before the click lands, so only links that might hide a download pay it.
  function isWorthProbing(url, pageUrl) {
    const samePage = url.origin === pageUrl.origin &&
      url.pathname === pageUrl.pathname && url.search === pageUrl.search;
    if (samePage) return false;
    if (siteOf(url.hostname) !== siteOf(pageUrl.hostname)) return true;
    return DOWNLOAD_WORDS.test(url.pathname + url.search);
  }

  function isDownloadResponse(contentType, contentDisposition) {
    if (/^\s*attachment/i.test(contentDisposition || '')) return true;
    const type = (contentType || '').split(';')[0].trim();
    if (!type) return false;
    return !SHOWN_INLINE.test(type);
  }

  root.GoelCaptureRules = { isFileLink, isWorthProbing, isDownloadResponse };
})(typeof globalThis !== 'undefined' ? globalThis : self);
