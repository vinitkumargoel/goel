// Served as a static asset so the portal's CSP can forbid inline script everywhere.
;(function () {
  const form = document.getElementById('f')
  if (!form) return

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
      const j = await r.json().catch(() => ({ error: 'Sign-in failed' }))
      show(j.error || 'Wrong username or password')
    } catch (_) {
      show('Could not reach the server')
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
