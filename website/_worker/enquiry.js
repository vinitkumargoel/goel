const FALLBACK_MAILBOX = "licensing@vinitk.dev";

/** The only origin that may post the form; override with SITE_ORIGIN for `wrangler dev`. */
const DEFAULT_SITE_ORIGIN = "https://goel.vinitk.dev";

const REQUIRED_FIELDS = ["company", "email", "seats", "country", "useCase"];

/** Allowlist, never a passthrough: attacker-chosen keys used to reach Slack/Discord verbatim. */
const ALLOWED_FIELDS = [...REQUIRED_FIELDS, "message", "page"];

/** Abuse ceiling: without it a bot can post an unbounded body through the form. */
const MAX_FIELD_LENGTH = 4000;

/** Checked before parsing, so an oversized body is never buffered into formData/json. */
const MAX_BODY_BYTES = 16 * 1024;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (url.pathname === "/api/enquiry") {
      const origin = siteOrigin(env);
      if (request.method === "OPTIONS") return preflight(origin);
      if (request.method !== "POST") {
        return json({ error: "Use POST." }, 405, { Allow: "POST, OPTIONS" });
      }
      return handleEnquiry(request, env, ctx, origin);
    }

    return env.ASSETS.fetch(request);
  },
};

function siteOrigin(env) {
  return (env && typeof env.SITE_ORIGIN === "string" && env.SITE_ORIGIN) || DEFAULT_SITE_ORIGIN;
}

async function handleEnquiry(request, env, ctx, origin) {
  const requestId = crypto.randomUUID();
  const contentType = request.headers.get("content-type") || "";
  const wantsHTML = !contentType.includes("application/json");

  // A browser always sends Origin on a cross-site POST; a foreign one is someone else's page.
  const sentOrigin = request.headers.get("origin");
  if (sentOrigin && sentOrigin !== origin) {
    return reply(wantsHTML, "Submit the form from the site.", 403, origin);
  }

  // Optional Workers rate-limit binding: absent in dev, so its absence must not break the form.
  if (env && env.ENQUIRY_LIMITER && typeof env.ENQUIRY_LIMITER.limit === "function") {
    const key = request.headers.get("cf-connecting-ip") || "unknown";
    try {
      const { success } = await env.ENQUIRY_LIMITER.limit({ key });
      if (!success) {
        return reply(wantsHTML,
          `Too many submissions — try again later, or email ${FALLBACK_MAILBOX}.`, 429, origin);
      }
    } catch {
      console.error(`[enquiry] ${requestId} rate limiter unavailable`);
    }
  }

  const declared = Number(request.headers.get("content-length") || "0");
  if (declared > MAX_BODY_BYTES) {
    return reply(wantsHTML, "That submission is too large.", 413, origin);
  }

  let fields;
  try {
    // Content-Length can be absent (chunked), so the read itself is capped too.
    const text = await readCapped(request, MAX_BODY_BYTES);
    if (text === null) return reply(wantsHTML, "That submission is too large.", 413, origin);
    fields = wantsHTML ? Object.fromEntries(new URLSearchParams(text)) : JSON.parse(text);
  } catch {
    return reply(wantsHTML, "Could not read that form submission.", 400, origin);
  }
  if (!fields || typeof fields !== "object" || Array.isArray(fields)) {
    return reply(wantsHTML, "Could not read that form submission.", 400, origin);
  }

  // Honeypot must answer 200: an error tells the bot it was detected and it retries.
  if (typeof fields.website === "string" && fields.website.trim() !== "") {
    return reply(wantsHTML, "Thanks — we'll be in touch.", 200, origin);
  }

  const enquiry = pickFields(fields);

  const missing = REQUIRED_FIELDS.filter((field) => !enquiry[field]);
  if (missing.length > 0) {
    return reply(wantsHTML, `Missing required field(s): ${missing.join(", ")}.`, 400, origin);
  }
  if (!/^[^@\s]+@[^@\s.]+\.[^@\s]+$/.test(enquiry.email)) {
    return reply(wantsHTML, "That email address doesn't look right.", 400, origin);
  }

  const payload = {
    kind: "goel-commercial-enquiry",
    requestId,
    receivedAt: new Date().toISOString(),
    edgeCountry: request.cf?.country ?? null,
    enquiry,
  };

  // Must stay out of band: awaiting the webhook turns a slow third party into a failed submission.
  ctx.waitUntil(deliver(payload, env));

  return reply(
    wantsHTML,
    `Received. You'll get a reply within one business day. If you don't, email ${FALLBACK_MAILBOX} directly.`,
    200,
    origin
  );
}

/** Only known keys survive, each sanitised. */
export function pickFields(fields) {
  const enquiry = {};
  for (const key of ALLOWED_FIELDS) {
    if (!Object.prototype.hasOwnProperty.call(fields, key)) continue;
    enquiry[key] = sanitizeField(fields[key]);
  }
  return enquiry;
}

/** null when the body exceeds `limit` bytes — stops reading instead of buffering the rest. */
async function readCapped(request, limit) {
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > limit) {
      try { await reader.cancel(); } catch { /* already closed */ }
      return null;
    }
    chunks.push(value);
  }
  const joined = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) { joined.set(chunk, offset); offset += chunk.byteLength; }
  return new TextDecoder().decode(joined);
}

/**
 * Webhook targets render markup: `<!channel>`, `<@U123>`, `<url|text>` (Slack) and
 * `@everyone` (Discord) would ping or phish whoever reads the channel. A Markdown
 * `[Invoice](https://evil)` or `![x](url)` shows only its label, so it is unfolded
 * to `Invoice (https://evil)` — the reader sees where a link really goes.
 */
export function sanitizeField(raw) {
  return String(raw ?? "")
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F‪-‮⁦-⁩]/g, "")
    .replace(/!?\[([^\]]*)\]\(\s*([^)\s]*)[^)]*\)/g, (_, label, url) =>
      url ? `${label} (${url})` : label)
    .replace(/[<>]/g, "")
    .replace(/@(everyone|here|channel)/gi, "@​$1")
    .trim()
    .slice(0, MAX_FIELD_LENGTH);
}

/** Log lines carry the request id only: the payload is PII and observability is on. */
async function deliver(payload, env) {
  const webhook = env.ENQUIRY_WEBHOOK_URL;
  const id = payload.requestId;

  if (!webhook) {
    console.log(`[enquiry] ${id} not delivered: no ENQUIRY_WEBHOOK_URL set`);
    return;
  }

  try {
    const response = await fetch(webhook, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(payload),
    });
    if (!response.ok) {
      console.error(`[enquiry] ${id} webhook returned ${response.status}`);
    }
  } catch (error) {
    console.error(`[enquiry] ${id} webhook threw: ${error && error.name ? error.name : "error"}`);
  }
}

function reply(wantsHTML, message, status, origin) {
  return wantsHTML
    ? html(message, status)
    : json({ ok: status < 400, message }, status, corsHeaders(origin));
}

function corsHeaders(origin) {
  return { "access-control-allow-origin": origin, vary: "Origin" };
}

function json(body, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
      ...extraHeaders,
    },
  });
}

function html(message, status) {
  const safe = message.replace(/[&<>"]/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]
  );
  const body =
    `<!DOCTYPE html><html lang="en" class="theme-terminal"><head><meta charset="utf-8">` +
    `<meta name="viewport" content="width=device-width, initial-scale=1">` +
    `<title>Enquiry — Goel°</title><link rel="stylesheet" href="/tokens.css">` +
    `<style>body{background:var(--color-paper);color:var(--color-ink);` +
    `font-family:var(--font-body);display:grid;place-items:center;min-height:100vh;` +
    `margin:0;padding:24px;text-align:center;line-height:1.7}` +
    `p{max-width:52ch;color:var(--color-ink-soft)}` +
    `a{color:var(--color-accent)}</style></head><body><div>` +
    `<p>${safe}</p><p><a href="/commercial">← Back to commercial licensing</a></p>` +
    `</div></body></html>`;
  return new Response(body, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
    },
  });
}

/** Scoped to the site: the form is same-origin, so no other page needs its preflight to pass. */
function preflight(origin) {
  return new Response(null, {
    status: 204,
    headers: {
      ...corsHeaders(origin),
      "access-control-allow-methods": "POST, OPTIONS",
      "access-control-allow-headers": "content-type",
      "access-control-max-age": "86400",
    },
  });
}
