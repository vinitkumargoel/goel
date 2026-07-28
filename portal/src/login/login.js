// Served as a static asset so the portal's CSP can forbid inline script everywhere.
;(function () {
  const form = document.getElementById('f')
  if (!form) return

  // Inlined verbatim by the codegen, so this file never sees the portal's translations:
  // RemotePortalPage renders the localized text into these attributes. It always emits all
  // three, but this file is cached independently of the HTML that carries them, so a stale
  // copy would otherwise fail silently. English is the last resort, never nothing.
  const msg = (name, fallback) => form.dataset[name] || fallback

  form.addEventListener('submit', async (e) => {
    e.preventDefault()
    const button = form.querySelector('button')
    button.disabled = true
    try {
      const r = await fetch('/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          username: document.getElementById('u').value,
          password: document.getElementById('p').value,
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
  })

  function show(message) {
    let el = document.querySelector('.err')
    if (!el) {
      el = document.createElement('div')
      el.className = 'err'
      form.insertBefore(el, form.children[1])
    }
    el.textContent = message
  }
})()
