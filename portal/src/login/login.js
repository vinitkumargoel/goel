// Served as a static asset so the portal's CSP can forbid inline script everywhere.
;(function () {
  const form = document.getElementById('f')
  if (!form) return

  // Inlined verbatim by the codegen, so this file never sees the portal's translations.
  // RemotePortalPage renders the localized text into these attributes and always emits all three.
  const msg = form.dataset

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
      const j = await r.json().catch(() => ({ error: msg.msgFailed }))
      show(j.error || msg.msgCredentials)
    } catch (_) {
      show(msg.msgOffline)
    }
    button.disabled = false
  })

  function show(message) {
    if (!message) return
    let el = document.querySelector('.err')
    if (!el) {
      el = document.createElement('div')
      el.className = 'err'
      form.insertBefore(el, form.children[1])
    }
    el.textContent = message
  }
})()
