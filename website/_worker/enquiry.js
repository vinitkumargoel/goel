const FALLBACK_MAILBOX = "licensing@vinitk.dev";

const REQUIRED_FIELDS = ["company", "email", "seats", "country", "useCase"];

/** Abuse ceiling: without it a bot can post an unbounded body through the form. */
const MAX_FIELD_LENGTH = 4000;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (url.pathname === "/api/enquiry") {
      if (request.method === "OPTIONS") return preflight();
      if (request.method !== "POST") {
        return json({ error: "Use POST." }, 405, { Allow: "POST, OPTIONS" });
      }
      return handleEnquiry(request, env, ctx);
    }

    return env.ASSETS.fetch(request);
  },
};

async function handleEnquiry(request, env, ctx) {
  const contentType = request.headers.get("content-type") || "";
  const wantsHTML = !contentType.includes("application/json");

  let fields;
  try {
    fields = wantsHTML
      ? Object.fromEntries(await request.formData())
      : await request.json();
  } catch {
    return reply(wantsHTML, "Could not read that form submission.", 400);
  }
  if (!fields || typeof fields !== "object") {
    return reply(wantsHTML, "Could not read that form submission.", 400);
  }

  // Honeypot must answer 200: an error tells the bot it was detected and it retries.
  if (typeof fields.website === "string" && fields.website.trim() !== "") {
    return reply(wantsHTML, "Thanks — we'll be in touch.", 200);
  }

  const enquiry = {};
  for (const [key, raw] of Object.entries(fields)) {
    if (key === "website") continue;
    enquiry[key] = String(raw ?? "").trim().slice(0, MAX_FIELD_LENGTH);
  }

  const missing = REQUIRED_FIELDS.filter((field) => !enquiry[field]);
  if (missing.length > 0) {
    return reply(wantsHTML, `Missing required field(s): ${missing.join(", ")}.`, 400);
  }
  if (!/^[^@\s]+@[^@\s.]+\.[^@\s]+$/.test(enquiry.email)) {
    return reply(wantsHTML, "That email address doesn't look right.", 400);
  }

  const payload = {
    kind: "goel-commercial-enquiry",
    receivedAt: new Date().toISOString(),
    edgeCountry: request.cf?.country ?? null,
    enquiry,
  };

  // Must stay out of band: awaiting the webhook turns a slow third party into a failed submission.
  ctx.waitUntil(deliver(payload, env));

  return reply(
    wantsHTML,
    `Received. You'll get a reply within one business day. If you don't, email ${FALLBACK_MAILBOX} directly.`,
    200
  );
}

async function deliver(payload, env) {
  const webhook = env.ENQUIRY_WEBHOOK_URL;

  if (!webhook) {
    console.log("[enquiry] no ENQUIRY_WEBHOOK_URL set; not delivered:", JSON.stringify(payload));
    return;
  }

  try {
    const response = await fetch(webhook, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(payload),
    });
    if (!response.ok) {
      console.error(`[enquiry] webhook returned ${response.status}`, JSON.stringify(payload));
    }
  } catch (error) {
    console.error("[enquiry] webhook threw:", error, JSON.stringify(payload));
  }
}

function reply(wantsHTML, message, status) {
  return wantsHTML ? html(message, status) : json({ ok: status < 400, message }, status);
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

/** The wildcard grants nothing: this endpoint is unauthenticated and reads no cookie or credential. */
function preflight() {
  return new Response(null, {
    status: 204,
    headers: {
      "access-control-allow-origin": "*",
      "access-control-allow-methods": "POST, OPTIONS",
      "access-control-allow-headers": "content-type",
      "access-control-max-age": "86400",
    },
  });
}
