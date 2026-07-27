// The sign-in form's behaviour, served as a static asset from /assets/ so the
// portal's Content-Security-Policy can forbid inline script everywhere.
//
// Deliberately plain ES5-shaped JavaScript with no build step and no React: it
// is thirty lines that run before anyone is signed in, and pulling the whole
// bundle in front of the login page would slow down the one screen every user
// sees first.
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

  // Reuses the server-rendered .err element when there is one, so a failed
  // retry replaces the message instead of stacking a second banner.
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
