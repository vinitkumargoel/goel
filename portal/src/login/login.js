// Served as a static asset so the portal's CSP can forbid inline script everywhere.
;(function () {
  const form = document.getElementById('f')
  if (!form) return

  // Inlined verbatim by the codegen, so this file never sees the portal's translations:
  // RemotePortalPage renders the localized text into these attributes. This file is cached
  // independently of the HTML that carries them, so a stale copy — or an attribute the page
  // doesn't emit yet — would otherwise fail silently. English is the last resort, never nothing.
  const msg = (name, fallback) => form.dataset[name] || fallback

  const password = document.getElementById('p')

  // A server-rendered error (e.g. after a failed form POST) gets the same treatment as a fetched one.
  const initial = form.querySelector('.err')
  if (initial && password) {
    initial.id = 'err'
    initial.setAttribute('role', 'alert')
    password.setAttribute('aria-describedby', 'err')
    password.select()
  }

  form.addEventListener('submit', async (e) => {
    e.preventDefault()
    const button = form.querySelector('button')
    const idle = button.textContent
    button.disabled = true
    button.textContent = msg('msgBusy', 'Signing in…')
    try {
      const r = await fetch('/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          username: document.getElementById('u').value,
          password: password.value,
        }),
      })
      if (r.ok) {
        location.href = '/'
        return
      }
      const j = await r.json().catch(() => ({ error: msg('msgFailed', 'Sign-in failed') }))
      show(j.error || msg('msgCredentials', 'Wrong username or password'))
    } catch (_) {
      show(msg('msgOffline', 'Could not reach the server'))
    }
    button.disabled = false
    button.textContent = idle
  })

  function show(message) {
    let el = form.querySelector('.err')
    if (!el) {
      el = document.createElement('div')
      el.className = 'err'
      el.setAttribute('role', 'alert')
      form.insertBefore(el, form.children[1])
    }
    el.id = 'err'
    // A live region only speaks on change: the same error twice in a row (a second wrong
    // password) would be silent. Empty it, then refill on the next frame so it is re-announced.
    el.textContent = ''
    const target = el
    requestAnimationFrame(() => {
      target.textContent = message
    })
    // Most failures are a mistyped password: put the user straight back in that field.
    password.setAttribute('aria-describedby', 'err')
    password.select()
  }
})()
